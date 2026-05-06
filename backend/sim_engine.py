"""
sim_engine.py — Simulation orchestrator.
Reads MATLAB simulation output (JSON) and broadcasts to web dashboard.
Falls back to Python simulation if MATLAB is not running.
"""

import os
import json
import time
import threading
import numpy as np

from backend.config import Config
from backend.network import HospitalNetwork
from backend.ids_engine import IDSEngine
from backend.attack_gen import AttackManager
from backend.utils import poisson_sample


class SimulationEngine:
    """
    Main simulation orchestrator.

    Primary mode: reads tick-by-tick JSON from MATLAB simulation
    Fallback mode: runs pure-Python simulation when MATLAB not available
    """

    def __init__(self, socketio, network):
        self.socketio = socketio
        self.net = network
        self.cfg = Config

        self.running = False
        self.paused = False
        self.tick = 0
        self.speed = 5
        self.mode = 'python'  # 'matlab' or 'python'
        self.thread = None

        # Python-mode simulation state
        self.ids = IDSEngine(Config.N_SENSORS, Config.N_FOG)
        self.attack_mgr = AttackManager()

        # MATLAB output directory
        self.matlab_dir = os.path.join(
            os.path.dirname(__file__), '..', 'sim_output'
        )
        os.makedirs(self.matlab_dir, exist_ok=True)

        # Stats tracking
        self.stats = {
            'pkt_total': [],
            'avg_latency': [],
            'avg_fog_load': [],
            'avg_energy': [],
            'n_alarms': [],
            'n_attacks': [],
            'survival': [],
            'tp': 0, 'fp': 0, 'fn': 0, 'tn': 0,
            'attack_counts': {t: 0 for t in Config.ATTACK_TYPES},
        }

    # ── Control Methods ──────────────────────────────────────────────────

    def start(self, speed=5):
        if self.running:
            return
        self.running = True
        self.paused = False
        self.speed = speed

        # Check if MATLAB is producing output
        self.mode = 'matlab' if self._check_matlab() else 'python'
        print(f"[SIM] Starting in {self.mode.upper()} mode (speed={speed}x)")

        self.thread = threading.Thread(target=self._run_loop, daemon=True)
        self.thread.start()

    def pause(self):
        self.paused = True

    def resume(self):
        self.paused = False

    def stop(self):
        self.running = False
        if self.thread:
            self.thread.join(timeout=2)

    def reset(self):
        self.stop()
        self.tick = 0
        self.net = HospitalNetwork()
        self.ids = IDSEngine(Config.N_SENSORS, Config.N_FOG)
        self.attack_mgr = AttackManager()
        self.stats = {
            'pkt_total': [], 'avg_latency': [], 'avg_fog_load': [],
            'avg_energy': [], 'n_alarms': [], 'n_attacks': [],
            'survival': [],
            'tp': 0, 'fp': 0, 'fn': 0, 'tn': 0,
            'attack_counts': {t: 0 for t in Config.ATTACK_TYPES},
        }
        self.socketio.emit('sim_status', {
            'running': False, 'tick': 0, 'max_iter': Config.MAX_ITER,
        })

    def set_speed(self, speed):
        self.speed = max(1, min(20, speed))

    def trigger_attack(self, attack_type):
        if self.mode == 'matlab':
            # Write trigger file for MATLAB to pick up
            trigger = {'type': attack_type, 'tick': self.tick}
            path = os.path.join(self.matlab_dir, 'attack_trigger.json')
            with open(path, 'w') as f:
                json.dump(trigger, f)
        else:
            self.attack_mgr.trigger_manual(attack_type, self.net, self.tick)

    # ── Main Loop ────────────────────────────────────────────────────────

    def _run_loop(self):
        while self.running and self.tick < Config.MAX_ITER:
            if self.paused:
                time.sleep(0.1)
                continue

            t0 = time.time()

            if self.mode == 'matlab':
                data = self._read_matlab_tick()
                if data:
                    self._broadcast_matlab_tick(data)
                    self.tick += 1
                else:
                    # File not ready yet. Check if MATLAB wiped the directory (restart detection)
                    if self.tick > 0:
                        prev_path = os.path.join(self.matlab_dir, f'tick_{self.tick:04d}.json')
                        if not os.path.exists(prev_path):
                            print(f"[MATLAB] Restart detected (tick_{self.tick:04d}.json wiped). Resetting bridge...")
                            self.tick = 0
                            self.socketio.emit('sim_reset')
                            continue

                    time.sleep(0.1)
                    continue
            else:
                self._python_tick()
                self.tick += 1

            # Pace to speed setting
            elapsed = time.time() - t0
            target = Config.SIM_TICK_MS / 1000.0 / self.speed
            if elapsed < target:
                time.sleep(target - elapsed)

        self.running = False
        self.socketio.emit('sim_status', {
            'running': False, 'tick': self.tick, 'max_iter': Config.MAX_ITER,
        })
        self.socketio.emit('sim_complete', self._build_report())

    # ── Python Simulation Tick ───────────────────────────────────────────

    def _python_tick(self):
        ns = Config.N_SENSORS
        nf = Config.N_FOG
        net = self.net

        # 1. Generate traffic
        traffic_pkt = poisson_sample(Config.BASE_PKT_RATE, ns).astype(float)
        traffic_lat = np.full(ns, Config.BASE_LATENCY_MS) + np.random.randn(ns) * 2
        traffic_loss = np.full(ns, Config.BASE_PKT_LOSS)
        payload = net.vitals[:ns].copy()

        # Add natural noise to vitals
        payload[:, :7] += np.random.randn(ns, 7) * 0.5

        # 2. Generate/manage attacks
        attack = self.attack_mgr.tick(net, self.tick)

        # 3. Apply attack effects
        traffic_pkt, traffic_lat, traffic_loss, payload = \
            AttackManager.apply_attack_effects(
                traffic_pkt, traffic_lat, traffic_loss, payload, attack, ns
            )

        # Ground truth: which nodes are actually under attack
        ground_truth = np.zeros(ns, dtype=bool)
        if attack:
            for t in attack['targets']:
                if t < ns:
                    ground_truth[t] = True

        # 4. IDS detection
        alarm, anomaly_score, votes, fingerprint_match = self.ids.detect(
            traffic_pkt, traffic_lat, payload, ns
        )
        fog_alarm = self.ids.detect_fog(alarm, anomaly_score, net)
        
        # 4b. Instant Auto-quarantine on fingerprint match
        #     OR streak-based: 5+ consecutive alarm ticks
        if not hasattr(self, 'alarm_streak'):
            self.alarm_streak = np.zeros(ns, dtype=int)
        self.alarm_streak[alarm] += 1
        self.alarm_streak[~alarm] = np.maximum(0, self.alarm_streak[~alarm] - 1)
        
        alive = net.status[:ns] == 'active'
        auto_quar_fp = fingerprint_match & alive
        auto_quar_streak = (self.alarm_streak >= 5) & alive
        auto_quar = auto_quar_fp | auto_quar_streak
        if auto_quar.any():
            for qn in np.where(auto_quar)[0]:
                net.status[qn] = 'quarantined'
                net.vlan[qn] = 999
                # Move to bottom right corner visually
                net.x[qn] = Config.FLOOR_W + 20 + np.random.rand() * 80
                net.y[qn] = 20 + np.random.rand() * Config.FLOOR_H * 0.35
                self.alarm_streak[qn] = 0
                print(f"[IDS] Python Fallback auto-quarantined node {qn}")

        # 5. Update node states (energy drain)
        alive = net.status[:ns] == 'active'
        energy_cost = (Config.E_TX * Config.PKT_BITS * traffic_pkt +
                       Config.E_RX * Config.PKT_BITS * traffic_pkt * 0.5)
        net.energy[:ns] -= energy_cost
        new_dead = alive & (net.energy[:ns] <= 0)
        net.status[:ns] = np.where(new_dead, 'dead', net.status[:ns])
        net.n_dead += int(new_dead.sum())

        # 6. Update fog queues
        for f in range(nf):
            members = net.fog_members[f]
            if members:
                load = traffic_pkt[members].sum()
                net.fog_queue[f] = min(load, Config.FOG_QUEUE_CAP)
                net.fog_load[f] = load / Config.FOG_QUEUE_CAP

        # 7. Re-cluster periodically
        if self.tick % Config.RECLUSTER_EVERY == 0 and self.tick > 0:
            net.form_clusters()

        # 8. Update stats
        if attack:
            tp = int((alarm & ground_truth).sum())
            fp = int((alarm & ~ground_truth).sum())
            fn = int((~alarm & ground_truth).sum())
            tn = int((~alarm & ~ground_truth).sum())
            self.stats['tp'] += tp
            self.stats['fp'] += fp
            self.stats['fn'] += fn
            self.stats['tn'] += tn

            for atype in set(attack['per_target_type'].values()):
                self.stats['attack_counts'][atype] = \
                    self.stats['attack_counts'].get(atype, 0) + 1

        active_count = int((net.status[:ns] == 'active').sum())
        self.stats['pkt_total'].append(float(traffic_pkt.sum()))
        self.stats['avg_latency'].append(float(traffic_lat.mean()))
        self.stats['avg_fog_load'].append(float(net.fog_load.mean()))
        self.stats['avg_energy'].append(float(np.mean(
            net.energy[:ns][net.energy[:ns] > 0]
        )) if active_count > 0 else 0)
        self.stats['n_alarms'].append(int(alarm.sum()))
        self.stats['n_attacks'].append(int(ground_truth.sum()))
        self.stats['survival'].append(active_count / ns * 100)

        # 9. Build alerts for this tick
        alerts = []
        if attack and alarm.any():
            alerts.append({
                'type': 'alarm',
                'time': self.tick,
                'msg': f"{attack['type']} detected on {int(alarm.sum())} nodes "
                       f"(confidence {float(anomaly_score[alarm].mean()):.0%})"
            })
        if fog_alarm.any():
            alerts.append({
                'type': 'alarm',
                'time': self.tick,
                'msg': f"Fog alarm: {int(fog_alarm.sum())} clusters flagged"
            })

        # 10. Build suspicious nodes list
        suspicious = []
        high_score = anomaly_score > 0.5
        for i in np.where(high_score)[0]:
            suspicious.append({
                'id': int(i),
                'device_type': str(net.device_type[i]),
                'ward': str(net.ward[i]),
                'score': round(float(anomaly_score[i]), 2),
                'status': 'Sustained' if self.ids.sustained[i] else 'Warning',
            })
        suspicious.sort(key=lambda x: x['score'], reverse=True)

        # 11. Broadcast tick data
        self.socketio.emit('sim_tick', {
            'tick': self.tick,
            'health': net.to_health_state(),
            'alerts': alerts,
            'stats': {
                'pkt_total': self.stats['pkt_total'][-1],
                'avg_latency': self.stats['avg_latency'][-1],
                'avg_fog_load': self.stats['avg_fog_load'][-1],
                'avg_energy': self.stats['avg_energy'][-1],
                'n_alarms': self.stats['n_alarms'][-1],
                'n_attacks': self.stats['n_attacks'][-1],
                'survival': self.stats['survival'][-1],
                'tp': self.stats['tp'], 'fp': self.stats['fp'],
                'fn': self.stats['fn'], 'tn': self.stats['tn'],
                'attack_counts': self.stats['attack_counts'],
            },
            'suspicious': suspicious[:20],
        })

        self.socketio.emit('sim_status', {
            'running': True, 'tick': self.tick, 'max_iter': Config.MAX_ITER,
        })

    # ── MATLAB Bridge ────────────────────────────────────────────────────

    def _check_matlab(self):
        """Check if MATLAB is producing output files and jump to the latest tick."""
        import glob
        tick_files = glob.glob(os.path.join(self.matlab_dir, 'tick_*.json'))
        if not tick_files:
            return False
            
        max_tick = 0
        for f in tick_files:
            try:
                # Extract tick number from filename like 'tick_0146.json'
                basename = os.path.basename(f)
                num = int(basename.replace('tick_', '').replace('.json', ''))
                if num > max_tick:
                    max_tick = num
            except Exception:
                pass
                
        if max_tick > 0:
            self.tick = max_tick
            print(f"[MATLAB] Found active session, fast-forwarding to tick {max_tick}")
            return True
        return False

    def _read_matlab_tick(self):
        """Read tick data from MATLAB JSON output."""
        fname = f'tick_{self.tick + 1:04d}.json'
        path = os.path.join(self.matlab_dir, fname)
        if not os.path.exists(path):
            time.sleep(0.05)
            if not os.path.exists(path):
                return None
        try:
            with open(path, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return None

    def _broadcast_matlab_tick(self, data):
        """Forward MATLAB tick data to WebSocket clients."""
        self.socketio.emit('sim_tick', data)
        self.socketio.emit('sim_status', {
            'running': True, 'tick': self.tick + 1, 'max_iter': Config.MAX_ITER, 'mode': 'matlab'
        })
        # Forward alerts
        if data.get('alerts'):
            for alert in data['alerts']:
                self.socketio.emit('event', alert)

    # ── Report ───────────────────────────────────────────────────────────

    def _build_report(self):
        s = self.stats
        tp, fp, fn, tn = s['tp'], s['fp'], s['fn'], s['tn']
        total = tp + fp + fn + tn
        return {
            'ticks': self.tick,
            'accuracy': (tp + tn) / max(total, 1),
            'precision': tp / max(tp + fp, 1),
            'recall': tp / max(tp + fn, 1),
            'f1': 2 * tp / max(2 * tp + fp + fn, 1),
            'fpr': fp / max(fp + tn, 1),
            'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
            'attack_counts': s['attack_counts'],
        }
