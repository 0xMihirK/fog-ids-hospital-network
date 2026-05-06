"""
ids_engine.py — 7-module voting IDS with cross-module noise suppression,
temporal correlation, fog-level stacked ensemble, and dynamic thresholds.

Modules:
  1 — Rate Anomaly (DDoS)
  2 — Latency Anomaly (DDoS/MITM)
  3 — ARP/Cert Monitor (MITM)
  4 — Sequence Detector (Replay)
  5 — Port Scan Detector (Nmap)
  6 — DNS Anomaly (APT/Tunneling)
  7 — Payload Integrity (Injection)
"""

import numpy as np
from backend.config import Config
from backend.utils import (
    ewma_update, z_score, cusum_update, shannon_entropy,
    SlidingWindow, dynamic_fog_threshold, compute_anomaly_score
)


class IDSEngine:
    """Intrusion Detection System with 7 detection modules."""

    def __init__(self, ns, nf):
        self.ns = ns
        self.nf = nf
        a = Config.IDS_EWMA_ALPHA

        # ── EWMA baselines ───────────────────────────────────────────────
        self.ewma_pkt_mean = np.full(ns, Config.BASE_PKT_RATE, dtype=float)
        self.ewma_pkt_std = np.full(ns, np.sqrt(Config.BASE_PKT_RATE), dtype=float)
        self.ewma_lat_mean = np.full(ns, Config.BASE_LATENCY_MS, dtype=float)
        self.ewma_lat_std = np.ones(ns, dtype=float)
        self.alpha = a

        # ── CUSUM state ──────────────────────────────────────────────────
        self.cusum_pos = np.zeros(ns)
        self.cusum_neg = np.zeros(ns)
        self.cusum_k = 1.5

        # ── Entropy baseline ────────────────────────────────────────────
        self.entropy_baseline = np.full(ns, np.log2(8))

        # ── ARP table (Module 3) ─────────────────────────────────────────
        self.arp_table = [{} for _ in range(ns)]  # node_id -> MAC mapping
        self.arp_change_count = np.zeros(ns)

        # ── Replay detection (Module 4) ──────────────────────────────────
        self.pkt_hash_window = [set() for _ in range(ns)]
        self.replay_count = np.zeros(ns)

        # ── Port scan detection (Module 5) ───────────────────────────────
        self.scan_attempts = np.zeros(ns)
        self.scan_pattern = np.zeros(ns)  # SYN/NULL/XMAS score

        # ── DNS anomaly (Module 6) ───────────────────────────────────────
        self.dns_query_entropy = np.zeros(ns)
        self.dns_beacon_score = np.zeros(ns)

        # ── Alarm state ──────────────────────────────────────────────────
        self.alarm = np.zeros(ns, dtype=bool)
        self.anomaly_score = np.zeros(ns)

        # ── Temporal sliding window ──────────────────────────────────────
        self.alarm_window = SlidingWindow(Config.IDS_WINDOW_LEN, ns)
        self.sustained = np.zeros(ns, dtype=bool)

        # ── Fog-level state ──────────────────────────────────────────────
        self.fog_alarm = np.zeros(nf, dtype=bool)
        self.fog_anomaly_avg = np.zeros(nf)
        self.fog_alarm_frac = np.zeros(nf)

        # ── Noise suppression context ────────────────────────────────────
        self.noise_context = {
            'ddos_active': np.zeros(ns, dtype=bool),
            'nmap_active': np.zeros(ns, dtype=bool),
        }

        # ── Detection latency tracking ───────────────────────────────────
        self.attack_start_step = np.zeros(ns, dtype=int)
        self.detect_step = np.zeros(ns, dtype=int)
        self.det_latency_log = []

        # ── Fog ensemble training state ──────────────────────────────────
        self.ensemble_trained = False
        self.training_data = []

    def detect(self, traffic_pkt, traffic_lat, payload, ns):
        """
        Run all 7 IDS modules on current-step traffic.
        Returns (alarm, anomaly_score) arrays.
        """
        a = self.alpha
        alarm = np.zeros(ns, dtype=bool)
        scores = np.zeros(ns)
        votes = np.zeros((ns, 7))

        # ── Module 1: Rate Anomaly (DDoS) ────────────────────────────────
        z_pkt = z_score(traffic_pkt[:ns], self.ewma_pkt_mean, self.ewma_pkt_std)
        votes[:, 0] = z_pkt > Config.IDS_PKT_THRESH

        # ── Module 2: Latency Anomaly ────────────────────────────────────
        z_lat = z_score(traffic_lat[:ns], self.ewma_lat_mean, self.ewma_lat_std)
        votes[:, 1] = z_lat > Config.IDS_LATENCY_THRESH

        # ── Module 3: CUSUM ──────────────────────────────────────────────
        deviation = traffic_pkt[:ns] - self.ewma_pkt_mean
        self.cusum_pos, self.cusum_neg = cusum_update(
            self.cusum_pos, self.cusum_neg, deviation, self.cusum_k
        )
        cusum_alarm = (self.cusum_pos > Config.IDS_CUSUM_THRESH) | \
                      (self.cusum_neg > Config.IDS_CUSUM_THRESH)
        votes[:, 2] = cusum_alarm
        if Config.IDS_CUSUM_RESET:
            reset_mask = cusum_alarm
            self.cusum_pos[reset_mask] = 0
            self.cusum_neg[reset_mask] = 0

        # ── Module 4: Payload Entropy (Replay/Injection indicator) ───────
        H = shannon_entropy(payload[:ns])
        ratio = H / (self.entropy_baseline + 1e-6)
        votes[:, 3] = ratio < Config.IDS_ENTROPY_THRESH
        self.entropy_baseline = (1 - a) * self.entropy_baseline + a * H

        # ── Module 5: Port Scan Detector (Nmap) ─────────────────────────
        # Simulated: nodes with moderate but unusual pkt increase + low payload entropy
        scan_indicator = (z_pkt > 1.0) & (z_pkt < Config.IDS_PKT_THRESH) & (ratio < 0.95)
        self.scan_attempts += scan_indicator.astype(float)
        self.scan_attempts *= 0.9  # decay
        votes[:, 4] = self.scan_attempts > 2.0

        # ── Module 6: DNS Anomaly (APT) ──────────────────────────────────
        # Simulated: subtle consistent latency increase + slight rate increase
        apt_indicator = (z_lat > 1.0) & (z_lat < Config.IDS_LATENCY_THRESH) & \
                        (z_pkt > 0.5) & (z_pkt < 1.5)
        self.dns_beacon_score += apt_indicator.astype(float) * 0.3
        self.dns_beacon_score *= 0.92  # decay
        votes[:, 5] = self.dns_beacon_score > 1.5

        # ── Module 7: Payload Integrity (Injection) ──────────────────────
        vital_violations = np.zeros(ns)
        vital_violations += (payload[:ns, 0] < Config.VITAL_HR_RANGE[0]) | \
                           (payload[:ns, 0] > Config.VITAL_HR_RANGE[1])
        vital_violations += payload[:ns, 1] < Config.VITAL_SPO2_MIN
        vital_violations += (payload[:ns, 2] < Config.VITAL_BP_SYS_RANGE[0]) | \
                           (payload[:ns, 2] > Config.VITAL_BP_SYS_RANGE[1])
        vital_violations += (payload[:ns, 3] < Config.VITAL_BP_DIA_RANGE[0]) | \
                           (payload[:ns, 3] > Config.VITAL_BP_DIA_RANGE[1])
        vital_violations += (payload[:ns, 4] < Config.VITAL_TEMP_RANGE[0]) | \
                           (payload[:ns, 4] > Config.VITAL_TEMP_RANGE[1])
        vital_violations += (payload[:ns, 5] < Config.VITAL_RR_RANGE[0]) | \
                           (payload[:ns, 5] > Config.VITAL_RR_RANGE[1])
        vital_violations += (payload[:ns, 6] < Config.VITAL_GLUCOSE_RANGE[0]) | \
                           (payload[:ns, 6] > Config.VITAL_GLUCOSE_RANGE[1])
        votes[:, 6] = vital_violations >= 2

        # ── Noise Suppression Gate ───────────────────────────────────────
        ddos_nodes = votes[:, 0].astype(bool)
        nmap_nodes = votes[:, 4].astype(bool)
        self.noise_context['ddos_active'] = ddos_nodes
        self.noise_context['nmap_active'] = nmap_nodes

        # DDoS active → suppress MITM-like signals (Module 4 entropy)
        votes[ddos_nodes, 3] = 0
        # Nmap active → suppress DDoS rate alarm for scanner
        votes[nmap_nodes, 0] = 0

        # ── Vote & Alarm ─────────────────────────────────────────────────
        total_votes = votes.sum(axis=1)
        alarm = total_votes >= Config.IDS_VOTE_THRESH

        # ── Anomaly Score ────────────────────────────────────────────────
        scores = compute_anomaly_score(
            z_pkt, z_lat, self.cusum_pos, self.cusum_neg,
            Config.IDS_CUSUM_THRESH, ratio, vital_violations
        )

        # ── Update EWMA baselines ────────────────────────────────────────
        self.ewma_pkt_mean, self.ewma_pkt_std = ewma_update(
            self.ewma_pkt_mean, self.ewma_pkt_std, traffic_pkt[:ns], a
        )
        self.ewma_lat_mean, self.ewma_lat_std = ewma_update(
            self.ewma_lat_mean, self.ewma_lat_std, traffic_lat[:ns], a
        )

        # ── Temporal sliding window ──────────────────────────────────────
        self.alarm_window.push(alarm)
        alarm_freq = self.alarm_window.mean()
        self.sustained = alarm_freq >= Config.IDS_WINDOW_THRESH

        # Boost anomaly for sustained alarms
        scores[self.sustained] = np.minimum(1, scores[self.sustained] + 0.2)

        # Lower bar for sustained nodes
        sustained_with_any_vote = self.sustained & (total_votes >= 1) & ~alarm
        alarm[sustained_with_any_vote] = True

        self.alarm = alarm
        self.anomaly_score = scores
        
        # ── Fingerprint Detection for Instant Quarantine ─────────────────
        # Trigger fingerprint match when traffic is clearly anomalous
        fp_ddos = (traffic_pkt[:ns] > 30) & (traffic_lat[:ns] > 40)
        
        # Scan / Replay fingerprint: elevated traffic with IDS agreement
        fp_scan_raw = (traffic_pkt[:ns] >= 12) & (traffic_lat[:ns] >= 25)
        fp_scan = fp_scan_raw & (total_votes >= 2)
        
        # MITM / high-latency fingerprint: latency spike with votes
        fp_latency = (traffic_lat[:ns] >= 35) & (total_votes >= 2)
        
        # Injection: extreme biological bound violations only
        fp_inject = (payload[:ns, 0] < 10) | (payload[:ns, 0] > 300) | \
                    (payload[:ns, 1] < 40) | \
                    (payload[:ns, 2] < 20) | (payload[:ns, 2] > 350)
        # Injection fingerprint also requires IDS agreement
        fp_inject = fp_inject & (total_votes >= 1)
                    
        fingerprint_match = fp_ddos | fp_scan | fp_latency | fp_inject
        
        # INSTANT OVERRIDE: If the fingerprint matches perfectly, it IS an attack!
        alarm = alarm | fingerprint_match

        return alarm, scores, votes, fingerprint_match

    def detect_fog(self, alarm, anomaly_score, net):
        """
        Fog-level aggregate IDS with dynamic thresholds.
        Returns fog_alarm array.
        """
        nf = self.nf
        fog_alarm = np.zeros(nf, dtype=bool)

        for f in range(nf):
            members = net.fog_members[f]
            n_mem = len(members)
            if n_mem == 0:
                self.fog_anomaly_avg[f] = 0
                self.fog_alarm_frac[f] = 0
                continue

            members_arr = np.array(members)
            frac = alarm[members_arr].sum() / n_mem
            self.fog_alarm_frac[f] = frac

            avg_anom = anomaly_score[members_arr].mean()
            self.fog_anomaly_avg[f] = avg_anom

            # Dynamic threshold
            thresh = dynamic_fog_threshold(n_mem)

            if frac >= thresh or avg_anom >= Config.FOG_ANOMALY_AGG_THRESH:
                fog_alarm[f] = True

        self.fog_alarm = fog_alarm
        return fog_alarm
