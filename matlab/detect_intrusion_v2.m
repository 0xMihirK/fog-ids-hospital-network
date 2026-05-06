function [alarm, anomaly_score, votes, ids, fingerprint_match] = detect_intrusion_v2(traffic_pkt, traffic_lat, payload, ids, config, t)
% DETECT_INTRUSION_V2 - 7-module voting IDS with noise suppression.
%
% Modules:
%   1 - Rate Anomaly (DDoS)
%   2 - Latency Anomaly (DDoS/MITM)
%   3 - CUSUM (change-point detection)
%   4 - Payload Entropy (Replay/Injection)
%   5 - Port Scan (Nmap)
%   6 - DNS Anomaly (APT)
%   7 - Vital Signs Integrity (Injection)
%
% Returns: alarm (logical), anomaly_score (float), votes (Nx7 matrix)

    if nargin < 6, t = Inf; end  % default: no warm-up gate if tick not provided

    ns = config.N_SENSORS;
    a  = config.IDS_EWMA_ALPHA;
    votes = zeros(ns, 7);

    % ---- WARM-UP GATE: no alarms during baseline learning ----
    if t < config.IDS_WARMUP_TICKS
        % Still update EWMA so baselines converge, but emit zero alarms
        ids.ewma_pkt_mean = (1-a)*ids.ewma_pkt_mean + a*traffic_pkt;
        ids.ewma_pkt_std  = (1-a)*ids.ewma_pkt_std  + a*abs(traffic_pkt - ids.ewma_pkt_mean);
        ids.ewma_lat_mean = (1-a)*ids.ewma_lat_mean + a*traffic_lat;
        ids.ewma_lat_std  = (1-a)*ids.ewma_lat_std  + a*abs(traffic_lat - ids.ewma_lat_mean);
        alarm         = false(ns, 1);
        anomaly_score = zeros(ns, 1);
        fingerprint_match = false(ns, 1);
        return;
    end

    % ---- Module 1: Rate Anomaly (DDoS) ----
    z_pkt = abs(traffic_pkt - ids.ewma_pkt_mean) ./ (ids.ewma_pkt_std + 1e-6);
    votes(:,1) = z_pkt > config.IDS_PKT_THRESH;

    % ---- Module 2: Latency Anomaly ----
    z_lat = abs(traffic_lat - ids.ewma_lat_mean) ./ (ids.ewma_lat_std + 1e-6);
    votes(:,2) = z_lat > config.IDS_LATENCY_THRESH;

    % ---- Module 3: CUSUM with decay ----
    % Decay accumulators first to prevent false accumulation over time
    ids.cusum_pos = ids.cusum_pos * config.IDS_CUSUM_DECAY;
    ids.cusum_neg = ids.cusum_neg * config.IDS_CUSUM_DECAY;
    deviation = traffic_pkt - ids.ewma_pkt_mean;
    ids.cusum_pos = max(0, ids.cusum_pos + deviation - 1.5);
    ids.cusum_neg = max(0, ids.cusum_neg - deviation - 1.5);
    cusum_alarm = (ids.cusum_pos > config.IDS_CUSUM_THRESH) | ...
                  (ids.cusum_neg > config.IDS_CUSUM_THRESH);
    votes(:,3) = cusum_alarm;
    if config.IDS_CUSUM_RESET
        ids.cusum_pos(cusum_alarm) = 0;
        ids.cusum_neg(cusum_alarm) = 0;
    end

    % ---- Module 4: Payload Entropy ----
    H = zeros(ns, 1);
    for i = 1:ns
        v = abs(payload(i,:)) + 1e-6;
        v = v / sum(v);
        H(i) = -sum(v .* log2(v));
    end
    ratio = H ./ (ids.entropy_baseline + 1e-6);
    votes(:,4) = ratio < config.IDS_ENTROPY_THRESH;
    ids.entropy_baseline = (1-a) * ids.entropy_baseline + a * H;

    % ---- Module 5: Port Scan (Nmap) ----
    scan_indicator = (z_pkt > 1.0) & (z_pkt < config.IDS_PKT_THRESH) & (ratio < 0.95);
    ids.scan_attempts = ids.scan_attempts + double(scan_indicator);
    ids.scan_attempts = ids.scan_attempts * 0.9;  % decay
    votes(:,5) = ids.scan_attempts > 3.0;  % raised threshold from 2.0

    % ---- Module 6: DNS Anomaly (APT) ----
    apt_indicator = (z_lat > 1.0) & (z_lat < config.IDS_LATENCY_THRESH) & ...
                    (z_pkt > 0.5) & (z_pkt < 1.5);
    ids.dns_beacon_score = ids.dns_beacon_score + double(apt_indicator) * 0.3;
    ids.dns_beacon_score = ids.dns_beacon_score * 0.92;
    votes(:,6) = ids.dns_beacon_score > 2.0;  % raised threshold from 1.5

    % ---- Module 7: Vital Signs Integrity (Injection) ----
    viol = zeros(ns, 1);
    viol = viol + (payload(:,1) < config.VITAL_HR_RANGE(1) | payload(:,1) > config.VITAL_HR_RANGE(2));
    viol = viol + (payload(:,2) < config.VITAL_SPO2_MIN);
    viol = viol + (payload(:,3) < config.VITAL_BP_SYS_RANGE(1) | payload(:,3) > config.VITAL_BP_SYS_RANGE(2));
    viol = viol + (payload(:,4) < config.VITAL_BP_DIA_RANGE(1) | payload(:,4) > config.VITAL_BP_DIA_RANGE(2));
    viol = viol + (payload(:,5) < config.VITAL_TEMP_RANGE(1) | payload(:,5) > config.VITAL_TEMP_RANGE(2));
    viol = viol + (payload(:,6) < config.VITAL_RR_RANGE(1) | payload(:,6) > config.VITAL_RR_RANGE(2));
    viol = viol + (payload(:,7) < config.VITAL_GLUCOSE_RANGE(1) | payload(:,7) > config.VITAL_GLUCOSE_RANGE(2));
    votes(:,7) = viol >= 3;  % require 3+ vital violations (was 2)

    % ---- Noise Suppression Gate ----
    ddos_nodes = logical(votes(:,1));
    nmap_nodes = logical(votes(:,5));
    votes(ddos_nodes, 4) = 0;  % DDoS -> suppress entropy (false MITM)
    votes(nmap_nodes, 1) = 0;  % Nmap -> suppress rate (false DDoS)

    % ---- Vote & Alarm ----
    total_votes = sum(votes, 2);
    alarm = total_votes >= config.IDS_VOTE_THRESH;  % now requires 3 votes

    % ---- Anomaly Score [0,1] ----
    anomaly_score = (z_pkt/8 + z_lat/5 + ...
        (ids.cusum_pos + ids.cusum_neg) / (2*config.IDS_CUSUM_THRESH) + ...
        max(0, 1 - ratio) + viol/4) / 7;
    anomaly_score = min(1, max(0, anomaly_score));

    % ---- Update EWMA baselines ----
    ids.ewma_pkt_mean = (1-a)*ids.ewma_pkt_mean + a*traffic_pkt;
    ids.ewma_pkt_std  = (1-a)*ids.ewma_pkt_std  + a*abs(traffic_pkt - ids.ewma_pkt_mean);
    ids.ewma_lat_mean = (1-a)*ids.ewma_lat_mean + a*traffic_lat;
    ids.ewma_lat_std  = (1-a)*ids.ewma_lat_std  + a*abs(traffic_lat - ids.ewma_lat_mean);

    % ---- Temporal Sliding Window ----
    ids.alarm_window(:, ids.window_ptr) = alarm;
    ids.window_ptr = mod(ids.window_ptr, config.IDS_WINDOW_LEN) + 1;
    alarm_freq = mean(ids.alarm_window, 2);
    sustained = alarm_freq >= config.IDS_WINDOW_THRESH;
    anomaly_score(sustained) = min(1, anomaly_score(sustained) + 0.2);

    % Sustained alarm boost — only if already voting at 2+ (not from 0)
    boost = sustained & (total_votes >= 2) & ~alarm;
    alarm(boost) = true;

    % ---- Fingerprint Detection for Instant Quarantine ----
    % Trigger fingerprint match when traffic is clearly anomalous
    fingerprint_match = false(ns, 1);
    
    % DDoS Fingerprint (massive rate & latency — unambiguous)
    fp_ddos = traffic_pkt > 30 & traffic_lat > 40;
    
    % Scan / Replay fingerprint: elevated traffic with IDS agreement
    fp_scan_raw = traffic_pkt >= 12 & traffic_lat >= 25;
    fp_scan = fp_scan_raw & (total_votes >= 2);
    
    % MITM / high-latency fingerprint: latency spike with votes
    fp_latency = traffic_lat >= 35 & (total_votes >= 2);
    
    % Injection: extreme biological violations + requires 1+ vote
    fp_inject = payload(:,1) < 10 | payload(:,1) > 300 | ...
                payload(:,2) < 40 | ...
                payload(:,3) < 20 | payload(:,3) > 350;
    fp_inject = fp_inject & (total_votes >= 1);
                
    fingerprint_match = fp_ddos | fp_scan | fp_latency | fp_inject;
    
    % INSTANT OVERRIDE: If the fingerprint matches perfectly, it IS an attack!
    alarm = alarm | fingerprint_match;
end
