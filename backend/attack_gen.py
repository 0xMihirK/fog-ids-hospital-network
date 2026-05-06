"""
attack_gen.py — Attack generation for 6 attack types.
Manages persistent multi-step attacks with per-type traffic effects.
Ported from generate_attack.m with additions for Nmap and APT/DNS-tunneling.
"""

import numpy as np
from backend.config import Config


class AttackManager:
    """Manages persistent multi-step attacks across the simulation."""

    def __init__(self):
        self.active_attacks = []
        self.attack_history = []

    def tick(self, net, iteration):
        """
        Age existing attacks, possibly spawn new ones, return merged attack info.
        Returns attack dict or None if no active attacks.
        """
        ns = Config.N_SENSORS

        # 1. Age and expire
        kept_attacks = []
        for a in self.active_attacks:
            if a['age'] < a['duration']:
                # Filter out targets that are no longer active
                valid_targets = [t for t in a['targets'] if net.status[t] == 'active']
                a['targets'] = valid_targets
                if valid_targets:
                    kept_attacks.append(a)
            a['age'] += 1
        self.active_attacks = kept_attacks

        # 2. Possibly spawn new attack
        if np.random.rand() < Config.ATTACK_PROB:
            self._spawn_attack(ns, iteration)

        # 3. Merge active attacks
        if not self.active_attacks:
            return None

        return self._merge_attacks(ns)

    def trigger_manual(self, attack_type, net, iteration):
        """Manually trigger a specific attack type."""
        ns = Config.N_SENSORS
        n_targets = 1 # Single target as requested
        targets = np.random.choice(ns, size=min(n_targets, ns), replace=False)
        duration = np.random.randint(Config.ATTACK_DUR_MIN, Config.ATTACK_DUR_MAX + 1)

        atk = {
            'type': attack_type,
            'targets': targets.tolist(),
            'duration': duration,
            'age': 0,
            'start_step': iteration,
            'manual': True,
        }
        self.active_attacks.append(atk)
        self.attack_history.append({
            'type': attack_type,
            'start': iteration,
            'n_targets': len(targets),
            'manual': True,
        })

    def _spawn_attack(self, ns, iteration):
        """Spawn a random new attack."""
        atype = np.random.choice(Config.ATTACK_TYPES)
        n_targets = np.random.randint(1, max(2, int(ns * 0.10)))
        targets = np.random.choice(ns, size=min(n_targets, ns), replace=False)
        duration = np.random.randint(Config.ATTACK_DUR_MIN, Config.ATTACK_DUR_MAX + 1)

        atk = {
            'type': atype,
            'targets': targets.tolist(),
            'duration': duration,
            'age': 0,
            'start_step': iteration,
            'manual': False,
        }
        self.active_attacks.append(atk)
        self.attack_history.append({
            'type': atype,
            'start': iteration,
            'n_targets': len(targets),
            'manual': False,
        })

    def _merge_attacks(self, ns):
        """Merge all active attacks into a single attack descriptor."""
        all_targets = set()
        all_types = []
        per_target_type = {}

        for atk in self.active_attacks:
            all_types.append(atk['type'])
            for t in atk['targets']:
                all_targets.add(t)
                per_target_type[t] = atk['type']

        targets = sorted(all_targets)

        return {
            'type': self.active_attacks[-1]['type'],  # most recent
            'targets': targets,
            'all_types': all_types,
            'per_target_type': per_target_type,
            'n_active': len(self.active_attacks),
            'start_step': self.active_attacks[0]['start_step'],
        }

    @staticmethod
    def apply_attack_effects(traffic_pkt, traffic_lat, traffic_loss,
                             payload, attack, ns):
        """
        Apply attack effects on traffic arrays (in-place modification).
        Returns modified (pkt, lat, loss, payload).
        """
        if attack is None:
            return traffic_pkt, traffic_lat, traffic_loss, payload

        for t in attack['targets']:
            if t >= ns:
                continue
            atype = attack['per_target_type'].get(t, attack['type'])

            if atype == 'DDoS':
                mult = 15 + np.random.rand() * 10
                traffic_pkt[t] = int(traffic_pkt[t] * mult)
                traffic_lat[t] *= (5 + np.random.rand() * 10)

            elif atype == 'Replay':
                traffic_pkt[t] *= 2
                traffic_lat[t] += 5 + np.random.rand() * 10

            elif atype == 'MITM':
                payload[t, 0] += (np.random.rand() - 0.5) * 80  # HR
                payload[t, 1] -= np.random.rand() * 15           # SpO2
                payload[t, 2] += (np.random.rand() - 0.5) * 120  # BP
                traffic_lat[t] += 15 + np.random.rand() * 15

            elif atype == 'Injection':
                n_inject = int(5 + np.random.rand() * 30)
                traffic_pkt[t] += n_inject
                payload[t, :] = np.random.rand(8) * 100

            elif atype == 'APT':
                traffic_pkt[t] = int(traffic_pkt[t] * Config.APT_RATE_MULT)
                traffic_lat[t] += Config.APT_LATENCY_ADD
                payload[t, 0] += (np.random.rand() - 0.3) * 5
                payload[t, 4] += np.random.rand() * 0.5

            elif atype == 'Nmap':
                # Port scanning: moderate rate increase, varied latency
                traffic_pkt[t] += int(3 + np.random.rand() * 8)
                traffic_lat[t] += 2 + np.random.rand() * 5

        return traffic_pkt, traffic_lat, traffic_loss, payload
