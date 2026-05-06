function run_simulation_v2()
% RUN_SIMULATION_V2 - Main simulation entry point.
% Runs the hospital fog network IDS simulation and outputs JSON
% state files for the web dashboard to consume.
%
% Architecture: MATLAB simulation -> JSON files -> Python Flask -> Browser
%
% Usage: run_simulation_v2()

    fprintf('==============================================================\n');
    fprintf('   Hospital Fog IDS - MATLAB Simulation Engine\n');
    fprintf('   Outputting to sim_output/ for web dashboard\n');
    fprintf('==============================================================\n\n');

    % ---- Load Configuration ----
    config = get_config_v2();

    % ---- Initialize Network ----
    net = initialize_network_v2(config);
    ns  = config.N_SENSORS;
    nf  = config.N_FOG;

    % ---- Initialize IDS State ----
    ids = initialize_ids_v2(config);

    % ---- Initialize Stats ----
    stats = init_stats_v2(config);

    % ---- Initialize Attack State ----
    attack_state = struct('active', {{}}, 'history', {{}}, 'last_trigger_tick', -1);
    
    % ---- Alarm streak counter (for auto-quarantine) ----
    alarm_streak = zeros(ns, 1); % ticks each node has been continuously alarming

    % ---- Clean output directory ----
    if exist(config.OUTPUT_DIR, 'dir')
        delete(fullfile(config.OUTPUT_DIR, '*.json'));
    end

    % ---- Write initial topology (one-time) ----
    write_topology_json(net, config);

    fprintf('[SIM] Starting simulation: %d iterations\n', config.MAX_ITER);
    fprintf('[SIM] Output dir: %s\n\n', config.OUTPUT_DIR);

    % ════════════════════════════════════════════════════════════════════
    % MAIN SIMULATION LOOP
    % ════════════════════════════════════════════════════════════════════
    for t = 1:config.MAX_ITER

        % 1. Generate normal traffic (Poisson-distributed)
        traffic_pkt  = poissrnd(config.BASE_PKT_RATE, ns, 1);
        traffic_lat  = config.BASE_LATENCY_MS + randn(ns, 1) * 2;
        traffic_loss = ones(ns, 1) * config.BASE_PKT_LOSS;
        payload      = net.vitals(1:ns, :) + randn(ns, 8) * 0.5;

        % 2. Generate / manage attacks
        attack_state.status = net.status(1:ns); % Pass status to filter dead/quarantined targets
        [attack_state, attack] = generate_attack_v2(attack_state, config, ns, t);

        % 3. Apply attack effects to traffic (only for active nodes)
        [traffic_pkt, traffic_lat, traffic_loss, payload] = ...
            apply_attack_effects(traffic_pkt, traffic_lat, traffic_loss, payload, attack, config, net.status(1:ns));

        % Ground truth
        ground_truth = false(ns, 1);
        if ~isempty(attack)
            ground_truth(attack.targets) = true;
        end

        % 4. Multi-hop communication simulation
        [comm] = simulate_communication_v2(traffic_pkt, traffic_lat, net, config);

        % 5. IDS detection (pass tick for warm-up gate)
        [alarm, anomaly_score, votes, ids, fingerprint_match] = detect_intrusion_v2( ...
            traffic_pkt, traffic_lat, payload, ids, config, t);

        % 6. Fog-level IDS
        fog_alarm = detect_fog_v2(alarm, anomaly_score, net, config);

        % 7. Update node states (energy drain)
        energy_cost = config.E_TX * config.PKT_BITS * traffic_pkt + ...
                      config.E_RX * config.PKT_BITS * traffic_pkt * 0.5;
        net.energy(1:ns) = net.energy(1:ns) - energy_cost;
        new_dead = strcmp(net.status(1:ns), 'active') & (net.energy(1:ns) <= 0);
        net.status(new_dead) = {'dead'};
        net.n_dead = net.n_dead + sum(new_dead);

        % 8. Update fog queues
        for f = 1:nf
            members = net.fog_members{f};
            if ~isempty(members)
                load = sum(traffic_pkt(members));
                net.fog_queue(f) = min(load, config.FOG_QUEUE_CAP);
                net.fog_load(f) = load / config.FOG_QUEUE_CAP;
            end
        end

        % 9. Re-cluster periodically
        if mod(t, config.RECLUSTER_EVERY) == 0
            net = form_clusters_v2(net, config);
        end
        
        % 9b. Auto-quarantine — instant trigger on fingerprint match
        %   OR streak-based: 5+ consecutive alarm ticks
        %   - Node must be active
        %   - Simulation must be past warm-up
        if t >= config.IDS_WARMUP_TICKS + config.MIN_NODE_AGE_QUARANTINE
            alarm_streak(alarm) = alarm_streak(alarm) + 1;
            alarm_streak(~alarm) = max(0, alarm_streak(~alarm) - 1);
            status_active = strcmp(net.status(1:ns), 'active');
            
            % Instant rule-based quarantine on fingerprint match
            auto_quar_fp = fingerprint_match & status_active(:);
            
            % Streak-based quarantine: persistent alarms for 5+ ticks
            auto_quar_streak = (alarm_streak >= 5) & status_active(:);
            
            auto_quar = auto_quar_fp | auto_quar_streak;
            
            if any(auto_quar)
                qnodes = find(auto_quar);
                for qi = 1:length(qnodes)
                    qn = qnodes(qi);
                    net.status{qn} = 'quarantined';
                    net.vlan(qn) = 999;
                    net.x(qn) = config.FLOOR_W + 20 + rand()*80;
                    net.y(qn) = 20 + rand() * config.FLOOR_H * 0.35;
                    alarm_streak(qn) = 0;
                    fprintf('[IDS] Auto-quarantined node %d (score=%.2f) at tick %d\n', ...
                        qn-1, anomaly_score(qn), t);
                end
            end
        end

        % 10. Update stats
        stats = update_stats_v2(stats, alarm, ground_truth, anomaly_score, ...
            traffic_pkt, traffic_lat, net, attack, fog_alarm, t, config);

        % 11. Build and write tick JSON for web dashboard
        tick_data = build_tick_json(t, net, alarm, anomaly_score, ...
            traffic_pkt, traffic_lat, comm, attack, fog_alarm, stats, config);
        write_tick_json(tick_data, t, config);

        % 12. Check for manual attack and isolation triggers from web dashboard
        attack_state = check_manual_triggers(attack_state, config, ns, t);
        net = check_isolate_triggers(net, config);

        % 13. Update MATLAB network visualization every tick for smooth animation
        visualize_network(net, config, attack, alarm, anomaly_score, traffic_pkt, fog_alarm, t);
        visualize_confusion_matrix(stats, t);
        
        % 14. Pace simulation to 10 FPS so Python dashboard can sync smoothly
        pause(0.1);
        % Console progress
        if mod(t, 50) == 0
            active = sum(strcmp(net.status(1:ns), 'active'));
            fprintf('[SIM] Tick %d/%d | Active: %d | Alarms: %d | Attacks: %d\n', ...
                t, config.MAX_ITER, active, sum(alarm), sum(ground_truth));
        end
    end

    % ---- Final Report ----
    fprintf('\n[SIM] Simulation complete.\n');
    write_final_report(stats, config);
end


% ════════════════════════════════════════════════════════════════════════
% HELPER FUNCTIONS
% ════════════════════════════════════════════════════════════════════════

function [attack_state, attack] = generate_attack_v2(attack_state, config, ns, t)
% Generate and manage persistent multi-step attacks.
    % Age and expire
    active = attack_state.active;
    keep = [];
    for i = 1:length(active)
        active{i}.age = active{i}.age + 1;
        
        % Filter out targets that are no longer active (quarantined/dead)
        valid_targets = [];
        for j = 1:length(active{i}.targets)
            tg = active{i}.targets(j);
            if strcmp(attack_state.status{tg}, 'active')
                valid_targets(end+1) = tg; %#ok<AGROW>
            end
        end
        active{i}.targets = valid_targets;
        
        if active{i}.age < active{i}.duration && ~isempty(active{i}.targets)
            keep(end+1) = i; %#ok<AGROW>
        end
    end
    active = active(keep);

    % Possibly spawn new attack
    trigger_file = fullfile('sim_output', 'attack_trigger.json');
    trigger_spawned = false;
    if exist(trigger_file, 'file')
        try
            fid = fopen(trigger_file, 'r');
            raw = fread(fid, '*char')';
            fclose(fid);
            trig_data = jsondecode(raw);
            delete(trigger_file); % Consume trigger
            
            atype = trig_data.type;
            n_targets = randi([1, max(2, ceil(ns*0.10))]);
            targets = randperm(ns, min(n_targets, ns));
            duration = randi([config.ATTACK_DUR_MIN, config.ATTACK_DUR_MAX]);
            atk = struct('type', atype, 'targets', targets, 'duration', duration, ...
                'age', 0, 'start_step', t);
            active{end+1} = atk;
            attack_state.history{end+1} = struct('type', atype, 'start', t, ...
                'n_targets', length(targets));
            trigger_spawned = true;
        catch
            % Ignore decode errors
        end
    end

    if ~trigger_spawned && rand() < config.ATTACK_PROB
        atype = config.ATTACK_TYPES{randi(length(config.ATTACK_TYPES))};
        n_targets = randi([1, max(2, ceil(ns*0.10))]);
        targets = randperm(ns, min(n_targets, ns));
        duration = randi([config.ATTACK_DUR_MIN, config.ATTACK_DUR_MAX]);
        atk = struct('type', atype, 'targets', targets, 'duration', duration, ...
            'age', 0, 'start_step', t);
        active{end+1} = atk;
        attack_state.history{end+1} = struct('type', atype, 'start', t, ...
            'n_targets', length(targets));
    end

    attack_state.active = active;

    % Merge active attacks
    if isempty(active)
        attack = [];
        return;
    end

    all_targets = [];
    for i = 1:length(active)
        all_targets = union(all_targets, active{i}.targets);
    end
    attack = struct('type', active{end}.type, 'targets', all_targets, ...
        'n_active', length(active));
end


function [pkt, lat, loss, pay] = apply_attack_effects(pkt, lat, loss, pay, attack, config, status)
% Apply attack effects to traffic arrays.
    if isempty(attack)
        return;
    end
    for i = 1:length(attack.targets)
        t = attack.targets(i);
        if ~strcmp(status{t}, 'active')
            continue;
        end
        switch attack.type
            case 'DDoS'
                mult = 15 + rand()*10;
                pkt(t) = round(pkt(t) * mult);
                lat(t) = lat(t) * (5 + rand()*10);
            case 'Replay'
                pkt(t) = pkt(t) * 2;
                lat(t) = lat(t) + 5 + rand()*10;
            case 'MITM'
                pay(t,1) = pay(t,1) + (rand()-0.5)*80;
                pay(t,2) = pay(t,2) - rand()*15;
                pay(t,3) = pay(t,3) + (rand()-0.5)*120;
                lat(t) = lat(t) + 15 + rand()*15;
            case 'Injection'
                pkt(t) = pkt(t) + round(5 + rand()*30);
                pay(t,:) = rand(1,8) * 100;
            case 'APT'
                pkt(t) = round(pkt(t) * config.APT_RATE_MULT);
                lat(t) = lat(t) + config.APT_LATENCY_ADD;
                pay(t,1) = pay(t,1) + (rand()-0.3)*5;
            case 'Nmap'
                pkt(t) = pkt(t) + round(3 + rand()*8);
                lat(t) = lat(t) + 2 + rand()*5;
        end
    end
end


function comm = simulate_communication_v2(traffic_pkt, traffic_lat, net, config)
% Simulate multi-hop communication with congestion.
    ns = config.N_SENSORS;
    nf = config.N_FOG;

    % Hop 1: Sensor -> Fog
    hop1_lat = traffic_lat + config.FOG_PROC_MS;

    % Congestion at fog level
    fog_total = zeros(nf, 1);
    for f = 1:nf
        m = net.fog_members{f};
        if ~isempty(m)
            fog_total(f) = sum(traffic_pkt(m));
        end
    end
    fog_congestion = fog_total / config.FOG_QUEUE_CAP;

    % Hop 2: Fog -> Gateway
    hop2_lat = config.GW_PROC_MS * ones(ns, 1);
    for i = 1:ns
        if net.cluster_id(i) > 0
            fc = fog_congestion(net.cluster_id(i));
            hop2_lat(i) = hop2_lat(i) * (1 + fc * config.CONGESTION_FACTOR);
        end
    end

    % Total
    total_lat = hop1_lat + hop2_lat + config.CLOUD_PROC_MS;

    comm = struct();
    comm.hop1_lat   = hop1_lat;
    comm.hop2_lat   = hop2_lat;
    comm.total_lat  = total_lat;
    comm.fog_load   = fog_congestion;
    comm.total_pkts = sum(traffic_pkt);
end


function fog_alarm = detect_fog_v2(alarm, anomaly_score, net, config)
% Fog-level aggregate IDS — uses configurable thresholds.
    nf = config.N_FOG;
    fog_alarm = false(nf, 1);

    for f = 1:nf
        members = net.fog_members{f};
        n_mem = length(members);
        if n_mem == 0, continue; end

        frac     = sum(alarm(members)) / n_mem;
        avg_anom = mean(anomaly_score(members));

        % Use config thresholds (not hardcoded 0.15/0.35)
        if frac >= config.FOG_ALARM_FRACTION || avg_anom >= config.FOG_ANOMALY_AGG_THRESH
            fog_alarm(f) = true;
        end
    end
end


function ids = initialize_ids_v2(config)
% Initialize IDS state structures with calibrated baselines.
% Starting from realistic normal-traffic values prevents false positives
% at tick 1 caused by zero-initialized EWMA means.
    ns = config.N_SENSORS;
    % Initialize to known normal traffic baselines (not zero)
    ids.ewma_pkt_mean    = ones(ns, 1) * config.NORMAL_PKT_RATE;
    ids.ewma_pkt_std     = ones(ns, 1) * config.NORMAL_PKT_STD;
    ids.ewma_lat_mean    = ones(ns, 1) * config.NORMAL_LATENCY;
    ids.ewma_lat_std     = ones(ns, 1) * config.NORMAL_LAT_STD;
    ids.cusum_pos        = zeros(ns, 1);
    ids.cusum_neg        = zeros(ns, 1);
    ids.entropy_baseline = ones(ns, 1) * log2(8);  % uniform 8-feature entropy
    ids.scan_attempts    = zeros(ns, 1);
    ids.dns_beacon_score = zeros(ns, 1);
    ids.alarm_window     = false(ns, config.IDS_WINDOW_LEN);
    ids.window_ptr       = 1;
end


function stats = init_stats_v2(config)
% Pre-allocate statistics arrays.
    M = config.MAX_ITER;
    stats.pkt_total    = zeros(M, 1);
    stats.avg_latency  = zeros(M, 1);
    stats.avg_fog_load = zeros(M, 1);
    stats.avg_energy   = zeros(M, 1);
    stats.n_alarms     = zeros(M, 1);
    stats.n_attacks    = zeros(M, 1);
    stats.survival     = zeros(M, 1);
    stats.tp = 0; stats.fp = 0; stats.fn = 0; stats.tn = 0;
    stats.attack_counts = containers.Map(config.ATTACK_TYPES, zeros(1, length(config.ATTACK_TYPES)));
end


function stats = update_stats_v2(stats, alarm, ground_truth, anomaly_score, ...
    traffic_pkt, traffic_lat, net, attack, fog_alarm, t, config)
% Update per-iteration statistics.
    ns = config.N_SENSORS;
    if ~isempty(attack)
        stats.tp = stats.tp + sum(alarm & ground_truth);
        stats.fp = stats.fp + sum(alarm & ~ground_truth);
        stats.fn = stats.fn + sum(~alarm & ground_truth);
        stats.tn = stats.tn + sum(~alarm & ~ground_truth);
    end

    if ~isempty(attack)
        if isKey(stats.attack_counts, attack.type)
            stats.attack_counts(attack.type) = stats.attack_counts(attack.type) + 1;
        end
    end

    active_count = sum(strcmp(net.status(1:ns), 'active'));
    stats.pkt_total(t)    = sum(traffic_pkt);
    stats.avg_latency(t)  = mean(traffic_lat);
    stats.avg_fog_load(t) = mean(net.fog_load);

    alive_energy = net.energy(1:ns);
    alive_energy = alive_energy(alive_energy > 0 & ~isinf(alive_energy));
    stats.avg_energy(t) = mean(alive_energy);

    stats.n_alarms(t)  = sum(alarm);
    stats.n_attacks(t) = sum(ground_truth);
    stats.survival(t)  = active_count / ns * 100;
end


function write_topology_json(net, config)
% Write full topology JSON (once at start).
    ns = config.N_SENSORS;
    nf = config.N_FOG;
    ng = config.N_GATEWAYS;

    nodes = cell(config.N_TOTAL, 1);
    for i = 1:config.N_TOTAL
        n = struct();
        n.id = i - 1;  % 0-indexed for JS
        n.x = net.x(i);
        n.y = net.y(i);
        n.layer = net.layer(i);
        n.vlan = net.vlan(i);
        n.ward = net.ward{i};
        n.device_type = net.device_type{i};
        n.ip = net.ip{i};
        n.status = net.status{i};
        if isinf(net.energy(i))
            n.energy = -1;
        else
            n.energy = net.energy(i);
        end
        if i <= ns
            n.cluster_id = net.cluster_id(i) - 1;  % 0-indexed
        end
        nodes{i} = n;
    end

    fog_links = cell(nf, 1);
    for f = 1:nf
        fog_links{f} = struct('from', ns + f - 1, 'to', ns + nf + net.fog_gateway(f) - 1);
    end

    gw_links = cell(ng, 1);
    for g = 1:ng
        gw_links{g} = struct('from', ns + nf + g - 1, 'to', ns + nf + ng + net.gw_cloud(g) - 1);
    end

    % Datacenter links (DC -> nearest gateway, through firewall)
    nd = config.N_DATACENTER;
    dc_links = cell(nd, 1);
    for d = 1:nd
        dc_links{d} = struct('from', ns + nf + ng + config.N_CLOUD + d - 1, ...
                             'to', ns + nf + net.dc_gateway(d) - 1);
    end

    % Firewall positions for topology rendering
    W = config.FLOOR_W; H = config.FLOOR_H;
    fw = struct();
    fw.internal = struct('x', W/2, 'y', H*1.05, 'label', 'Internal Firewall');
    fw.external = struct('x', W/2, 'y', H*1.25, 'label', 'External Firewall');

    topo = struct();
    topo.nodes = nodes;
    topo.fog_links = fog_links;
    topo.gw_links = gw_links;
    topo.dc_links = dc_links;
    topo.firewalls = fw;
    topo.floor = struct('w', config.FLOOR_W, 'h', config.FLOOR_H);

    json_str = jsonencode(topo);
    fid = fopen(fullfile(config.OUTPUT_DIR, 'topology.json'), 'w');
    fprintf(fid, '%s', json_str);
    fclose(fid);
end


function tick_data = build_tick_json(t, net, alarm, anomaly_score, ...
    traffic_pkt, traffic_lat, comm, attack, fog_alarm, stats, config)
% Build tick data struct for JSON output.
    ns = config.N_SENSORS;

    tick_data = struct();
    tick_data.tick = t;

    % Health
    active = sum(strcmp(net.status(1:ns), 'active'));
    dead = sum(strcmp(net.status(1:ns), 'dead'));
    quarantined = sum(strcmp(net.status(1:ns), 'quarantined'));
    tick_data.health = struct('active_sensors', active, 'dead_sensors', dead, ...
        'quarantined_sensors', quarantined, 'total_sensors', ns, ...
        'survival_rate', active/ns*100, 'avg_fog_load', mean(net.fog_load));

    % Stats
    tick_data.stats = struct('pkt_total', stats.pkt_total(t), ...
        'avg_latency', stats.avg_latency(t), 'avg_fog_load', stats.avg_fog_load(t), ...
        'avg_energy', stats.avg_energy(t), 'n_alarms', stats.n_alarms(t), ...
        'n_attacks', stats.n_attacks(t), 'survival', stats.survival(t), ...
        'tp', stats.tp, 'fp', stats.fp, 'fn', stats.fn, 'tn', stats.tn);

    % Traffic Logs
    tick_data.traffic_logs = generate_traffic_logs(t, net, traffic_pkt, attack, alarm, config);

    % Alerts
    alerts = {};
    if ~isempty(attack) && any(alarm)
        alerts{end+1} = struct('type', 'alarm', 'time', t, ...
            'msg', sprintf('%s detected on %d nodes', attack.type, sum(alarm)));
    end
    if any(fog_alarm)
        alerts{end+1} = struct('type', 'alarm', 'time', t, ...
            'msg', sprintf('Fog alarm: %d clusters flagged', sum(fog_alarm)));
    end
    for i = 1:length(tick_data.traffic_logs)
        log_entry = tick_data.traffic_logs{i};
        if strcmp(log_entry.type, 'honeypot')
            alerts{end+1} = struct('type', 'honeypot', 'time', t, ...
                'msg', sprintf('HONEYPOT HIT: %s targeted by %s', log_entry.dest, log_entry.src));
        end
        if strcmp(log_entry.type, 'quarantine')
            alerts{end+1} = struct('type', 'quarantine', 'time', t, ...
                'msg', sprintf('QUARANTINE BLOCKED: %s attempted egress', log_entry.src));
        end
    end
    tick_data.alerts = alerts;

    % Suspicious nodes
    suspicious = {};
    high_idx = find(anomaly_score > 0.5);
    for i = 1:min(20, length(high_idx))
        idx = high_idx(i);
        suspicious{end+1} = struct('id', idx-1, 'device_type', net.device_type{idx}, ...
            'ward', net.ward{idx}, 'score', round(anomaly_score(idx), 2), ...
            'status', 'Warning'); %#ok<AGROW>
    end
    tick_data.suspicious = suspicious;

    % Traffic flow data for visualization
    % Sample up to 50 active traffic flows for the topology animation
    active_idx = find(strcmp(net.status(1:ns), 'active'));
    n_sample = min(50, length(active_idx));
    sampled = active_idx(randperm(length(active_idx), n_sample));
    flows = cell(n_sample, 1);
    for i = 1:n_sample
        s = sampled(i);
        is_attack = false;
        attack_type = '';
        if ~isempty(attack) && ismember(s, attack.targets)
            is_attack = true;
            attack_type = attack.type;
        end
        flows{i} = struct('src', s-1, 'fog', ns + net.cluster_id(s) - 1, ...
            'pkt', traffic_pkt(s), 'lat', traffic_lat(s), ...
            'is_attack', is_attack, 'attack_type', attack_type);
    end
    tick_data.traffic_flows = flows;
end


function write_tick_json(tick_data, t, config)
% Write tick data atomically to prevent partial reads by Python backend.
    fname = sprintf('tick_%04d.json', t);
    tmp_fname = sprintf('tick_%04d.tmp', t);
    
    out_path = fullfile(config.OUTPUT_DIR, fname);
    tmp_path = fullfile(config.OUTPUT_DIR, tmp_fname);
    
    json_str = jsonencode(tick_data);
    fid = fopen(tmp_path, 'w');
    fprintf(fid, '%s', json_str);
    fclose(fid);
    
    % Atomic rename to avoid race conditions with Python reader
    movefile(tmp_path, out_path, 'f');
end


function attack_state = check_manual_triggers(attack_state, config, ns, t)
% Check for manual attack triggers from web dashboard.
    trigger_file = fullfile(config.OUTPUT_DIR, 'attack_trigger.json');
    if exist(trigger_file, 'file')
        try
            json_str = fileread(trigger_file);
            trigger = jsondecode(json_str);
            
            if isfield(trigger, 'tick') && trigger.tick == attack_state.last_trigger_tick
                % Already processed this trigger but file deletion was delayed
                return;
            end
            if isfield(trigger, 'tick')
                attack_state.last_trigger_tick = trigger.tick;
            end
            
            atype = trigger.type;
            n_targets = 1; % Hit exactly ONE node as requested
            targets = randperm(ns, min(n_targets, ns));
            duration = randi([config.ATTACK_DUR_MIN, config.ATTACK_DUR_MAX]);
            atk = struct('type', atype, 'targets', targets, 'duration', duration, ...
                'age', 0, 'start_step', t);
            attack_state.active{end+1} = atk;
            fprintf('[SIM] Manual %s attack triggered from dashboard\n', atype);
            
            try
                delete(trigger_file);
            catch
                % Ignore if python holds lock, we've marked it processed
            end
        catch
            % Ignore parse errors
        end
    end
end


function net = check_isolate_triggers(net, config)
% Check for manual isolation triggers from web dashboard.
    trigger_file = fullfile(config.OUTPUT_DIR, 'isolate_trigger.json');
    if exist(trigger_file, 'file')
        try
            json_str = fileread(trigger_file);
            trigger = jsondecode(json_str);
            node_id = trigger.node_id + 1; % JS 0-index to MATLAB 1-index
            if node_id <= config.N_SENSORS
                net.status{node_id} = 'quarantined';
                net.vlan(node_id) = 999;
                % Physically move the node to the Quarantine Zone (VLAN 999)
                % Placed to the right of the floorplan
                net.x(node_id) = config.FLOOR_W + 50 + rand() * 80;
                net.y(node_id) = config.FLOOR_H * 0.2 + rand() * 100;
                
                fprintf('[SIM] Node %d quarantined via dashboard\n', node_id-1);
            end
            delete(trigger_file);
        catch
        end
    end
end


function logs = generate_traffic_logs(t, net, traffic_pkt, attack, alarm, config)
% Generate traffic logs (alarms, honeypot hits, egress blocks, normal traffic)
    ns = config.N_SENSORS;
    logs = {};

    % 1. Alarms / Attacks / Honeypots
    if ~isempty(attack)
        for i = 1:min(5, length(attack.targets))
            ti = attack.targets(i);
            is_honeypot_attack = strcmpi(attack.type, 'Honeypot');
            if is_honeypot_attack || rand() < 0.15
                % Honeypot hit
                hp_idx = randi(length(config.HONEYPOTS_LAN));
                hp = config.HONEYPOTS_LAN{hp_idx};
                
                details_msg = sprintf('%s attack intercepted by decoy', attack.type);
                if is_honeypot_attack
                    details_msg = 'Direct Honeypot Probe logged';
                end
                
                logs{end+1} = struct('tick', t, 'src', 'Ext-Attacker', 'dest', sprintf('%s (Honeypot)', hp.name), ...
                    'vlan', 'DMZ/LAN', 'type', 'honeypot', 'result', 'LOGGED', ...
                    'details', details_msg);
            else
                % Normal attack log
                logs{end+1} = struct('tick', t, 'src', 'Ext-Attacker', 'dest', sprintf('N-%d', ti-1), ...
                    'vlan', num2str(net.vlan(ti)), 'type', 'alarm', 'result', 'ALERT', ...
                    'details', sprintf('%s flood detected', attack.type));
            end
        end
    end

    % 2. Quarantined Nodes (Egress Blocks)
    quar_idx = find(strcmp(net.status(1:ns), 'quarantined'));
    if ~isempty(quar_idx)
        for i = 1:min(3, length(quar_idx))
            qi = quar_idx(i);
            if rand() < 0.2 % only log occasionally to avoid spam
                logs{end+1} = struct('tick', t, 'src', sprintf('N-%d', qi-1), 'dest', 'External', ...
                    'vlan', '999', 'type', 'quarantine', 'result', 'BLOCKED', ...
                    'details', 'Egress blocked by ACL (Quarantine VLAN)');
            end
        end
    end

    % 3. Normal Traffic
    active_idx = find(strcmp(net.status(1:ns), 'active'));
    if ~isempty(active_idx)
        for i = 1:min(3, length(active_idx))
            si = active_idx(randi(length(active_idx)));
            if traffic_pkt(si) > 0
                logs{end+1} = struct('tick', t, 'src', sprintf('N-%d', si-1), ...
                    'dest', sprintf('Fog-%d', net.cluster_id(si)-1), ...
                    'vlan', num2str(net.vlan(si)), 'type', 'normal', 'result', 'ALLOW', ...
                    'details', sprintf('%d pkts transmitted', traffic_pkt(si)));
            end
        end
    end
end


function write_final_report(stats, config)
% Write final simulation report.
    tp = stats.tp; fp = stats.fp; fn = stats.fn; tn = stats.tn;
    total = tp + fp + fn + tn;
    fprintf('\n============== FINAL REPORT ==============\n');
    fprintf('Total ticks: %d\n', config.MAX_ITER);
    fprintf('Accuracy:    %.2f%%\n', (tp+tn)/max(total,1)*100);
    fprintf('Precision:   %.2f%%\n', tp/max(tp+fp,1)*100);
    fprintf('Recall:      %.2f%%\n', tp/max(tp+fn,1)*100);
    fprintf('F1-Score:    %.4f\n', 2*tp/max(2*tp+fp+fn,1));
    fprintf('FPR:         %.4f\n', fp/max(fp+tn,1));
    fprintf('TP=%d FP=%d FN=%d TN=%d\n', tp, fp, fn, tn);
    fprintf('==========================================\n');
end

function visualize_confusion_matrix(stats, t)
% VISUALIZE_CONFUSION_MATRIX - Draws a live 2x2 confusion matrix in a separate window
    persistent fig_cm txt_tp txt_fp txt_fn txt_tn txt_title txt_acc;
    
    if isempty(fig_cm) || ~ishandle(fig_cm)
        fig_cm = figure('Name', 'IDS Confusion Matrix', 'NumberTitle', 'off', ...
            'Position', [100 100 450 400], 'MenuBar', 'none', 'ToolBar', 'none', ...
            'Color', [0.1 0.1 0.15]);
        movegui(fig_cm, 'center');
        
        axes('Position', [0.15 0.1 0.7 0.75], 'Color', 'none', ...
            'XColor', 'none', 'YColor', 'none');
        xlim([0 2]); ylim([-0.2 2.5]);
        hold on;
        
        % Background patches (Standard Layout)
        patch([0 1 1 0], [1 1 2 2], [0.1 0.3 0.1], 'EdgeColor', 'w', 'FaceAlpha', 0.5, 'LineWidth', 2); % TP
        patch([1 2 2 1], [1 1 2 2], [0.3 0.1 0.1], 'EdgeColor', 'w', 'FaceAlpha', 0.5, 'LineWidth', 2); % FN
        patch([0 1 1 0], [0 0 1 1], [0.3 0.1 0.1], 'EdgeColor', 'w', 'FaceAlpha', 0.5, 'LineWidth', 2); % FP
        patch([1 2 2 1], [0 0 1 1], [0.1 0.3 0.1], 'EdgeColor', 'w', 'FaceAlpha', 0.5, 'LineWidth', 2); % TN
        
        % Labels
        text(0.5, 2.1, 'Predicted Positive', 'Color', 'w', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        text(1.5, 2.1, 'Predicted Negative', 'Color', 'w', 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        text(-0.1, 1.5, 'Actual Positive', 'Color', 'w', 'HorizontalAlignment', 'center', 'Rotation', 90, 'FontWeight', 'bold');
        text(-0.1, 0.5, 'Actual Negative', 'Color', 'w', 'HorizontalAlignment', 'center', 'Rotation', 90, 'FontWeight', 'bold');
        
        txt_tp = text(0.5, 1.5, 'TP: 0', 'Color', 'w', 'FontSize', 16, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        txt_fn = text(1.5, 1.5, 'FN: 0', 'Color', 'w', 'FontSize', 16, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        txt_fp = text(0.5, 0.5, 'FP: 0', 'Color', 'w', 'FontSize', 16, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        txt_tn = text(1.5, 0.5, 'TN: 0', 'Color', 'w', 'FontSize', 16, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        
        txt_title = text(1, 2.4, 'Cumulative Confusion Matrix', 'Color', 'w', 'FontSize', 14, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        txt_acc = text(1, -0.15, 'Accuracy: --', 'Color', 'w', 'FontSize', 12, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
    end
    
    total = stats.tp + stats.fp + stats.fn + stats.tn;
    acc = 0;
    if total > 0
        acc = (stats.tp + stats.tn) / total * 100;
    end
    
    % Helper to format large numbers with commas
    fmt = @(x) regexprep(num2str(x), '(?<=\d)(?=(\d{3})+(?!\d))', ',');
    
    set(txt_tp, 'String', sprintf('TP\n%s', fmt(stats.tp)));
    set(txt_fp, 'String', sprintf('FP\n%s', fmt(stats.fp)));
    set(txt_fn, 'String', sprintf('FN\n%s', fmt(stats.fn)));
    set(txt_tn, 'String', sprintf('TN\n%s', fmt(stats.tn)));
    set(txt_title, 'String', sprintf('Confusion Matrix (Tick %d)', t));
    set(txt_acc, 'String', sprintf('Overall Accuracy: %.2f%%', acc));
    
    drawnow limitrate;
end
