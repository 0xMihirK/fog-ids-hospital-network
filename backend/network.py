"""
network.py — 800-node hospital network topology with VLAN segmentation,
clinical area assignment, medical device types, inter-VLAN ACLs, routing,
and LEACH-style clustering.

Ported from initialize_network.m, form_clusters.m with major enhancements.
"""

import numpy as np
from backend.config import Config
from backend.utils import nearest_assignment


class HospitalNetwork:
    """
    Represents the full hospital network topology with VLAN segmentation.

    Layers:
        1 — Sensors  (680 nodes, VLANs 101-106 by clinical area)
        2 — Fog      (100 nodes, VLAN 200)
        3 — Gateway  (15 nodes, VLAN 300)
        4 — Cloud    (5 nodes, VLAN 400)

    Additional zones: DMZ (VLAN 10), Management (500), Quarantine (999)
    """

    def __init__(self):
        np.random.seed(42)

        self.cfg = Config
        N = Config.N_TOTAL
        ns = Config.N_SENSORS
        nf = Config.N_FOG
        ng = Config.N_GATEWAYS
        nc = Config.N_CLOUD
        W = Config.FLOOR_W
        H = Config.FLOOR_H

        # ── Core arrays ──────────────────────────────────────────────────
        self.x = np.zeros(N)
        self.y = np.zeros(N)
        self.layer = np.zeros(N, dtype=int)        # 1=sensor, 2=fog, 3=gw, 4=cloud
        self.vlan = np.zeros(N, dtype=int)
        self.ward = np.full(N, '', dtype='U20')
        self.device_type = np.full(N, '', dtype='U20')
        self.energy = np.zeros(N)
        self.status = np.full(N, 'active', dtype='U12')
        self.ip = np.full(N, '', dtype='U15')

        # Vital signs: [HR, SpO2, BP_sys, BP_dia, Temp, RR, Glucose, padding]
        self.vitals = np.zeros((N, 8))

        # ── Place sensors and fog nodes (Radial Clusters) ────────────────────
        self._place_sensors_and_fog(W, H, ns, nf)

        # ── Place gateways along top edge ────────────────────────────────
        self._place_gateways(W, H, ns, nf, ng)

        # ── Place cloud nodes above the map ──────────────────────────────
        self._place_cloud(W, H, ns, nf, ng, nc)

        # ── Place local datacenter ───────────────────────────────────────
        if hasattr(Config, 'N_DATACENTER'):
            self._place_datacenter(W, H, ns, nf, ng, nc, Config.N_DATACENTER)

        # ── Build routing tables ─────────────────────────────────────────
        self.fog_gateway = np.zeros(nf, dtype=int)
        self.gw_cloud = np.zeros(ng, dtype=int)
        self._build_routing(ns, nf, ng)

        # ── Clustering state ─────────────────────────────────────────────
        self.cluster_id = np.zeros(ns, dtype=int)
        self.dist_to_fog = np.zeros(ns)
        self.fog_members = [[] for _ in range(nf)]
        self.cluster_sizes = np.zeros(nf, dtype=int)
        self.is_ch = np.ones(nf, dtype=bool)
        self.form_clusters()

        # ── Fog queue state ──────────────────────────────────────────────
        self.fog_queue = np.zeros(nf)
        self.fog_load = np.zeros(nf)

        # ── Death counter ────────────────────────────────────────────────
        self.n_dead = 0

        # ── DMZ nodes (virtual — for topology display) ───────────────────
        self.dmz_nodes = self._create_dmz_nodes(W, H)

        # ── Firewall positions (for topology display) ────────────────────
        self.firewalls = {
            'external': {'x': W / 2, 'y': H * 1.25, 'label': 'External Firewall'},
            'internal': {'x': W / 2, 'y': H * 1.05, 'label': 'Internal Firewall'},
        }

    def _place_sensors_and_fog(self, W, H, ns, nf):
        """Place fog nodes per ward and orbit sensors radially around them."""
        areas = list(Config.CLINICAL_AREAS.items())
        n_cols, n_rows = 3, 2
        ward_w = W / n_cols
        ward_h = H / n_rows

        s_idx = 0
        f_idx = ns
        device_pool = list(Config.DEVICE_TYPES.items())
        total_sensors = sum(cfg['sensor_count'] for _, cfg in areas)

        MIN_FOG_SPACING = 30
        CLUSTER_RADIUS = 18

        for area_idx, (area_name, area_cfg) in enumerate(areas):
            col = area_idx % n_cols
            row = area_idx // n_cols
            wx0 = col * ward_w
            wy0 = row * ward_h
            count = area_cfg['sensor_count']

            # Allocate fog nodes proportionally
            fogs_this_ward = max(1, round(nf * (count / total_sensors)))
            # Adjust last ward to consume remainder
            if area_idx == len(areas) - 1:
                fogs_this_ward = nf - (f_idx - ns)

            eligible_devices = [
                (dname, dcfg) for dname, dcfg in device_pool
                if area_name in dcfg['wards']
            ]
            if not eligible_devices:
                eligible_devices = [('Generic', {'vitals': False})]

            # 1. Place Fog Nodes in this ward with spacing
            fx_list = []
            fy_list = []
            for _ in range(fogs_this_ward):
                placed = False
                attempts = 0
                cx, cy = 0, 0
                while not placed and attempts < 100:
                    cx = wx0 + 20 + np.random.rand() * (ward_w - 40)
                    cy = wy0 + 20 + np.random.rand() * (ward_h - 40)
                    if not fx_list:
                        placed = True
                    else:
                        dists = np.sqrt((np.array(fx_list) - cx)**2 + (np.array(fy_list) - cy)**2)
                        if np.all(dists >= MIN_FOG_SPACING):
                            placed = True
                    attempts += 1
                
                fx_list.append(cx)
                fy_list.append(cy)

                self.x[f_idx] = cx
                self.y[f_idx] = cy
                self.layer[f_idx] = 2
                self.vlan[f_idx] = 200
                self.energy[f_idx] = np.inf
                self.device_type[f_idx] = 'Fog Node'
                self.ip[f_idx] = f'10.200.1.{f_idx - ns + 1}'
                f_idx += 1

            # 2. Place Sensors strictly clustered radially around the Fog Nodes
            sensors_per_fog = count // fogs_this_ward

            for i in range(fogs_this_ward):
                n_assign = sensors_per_fog
                if i == fogs_this_ward - 1:
                    n_assign = count - (i * sensors_per_fog)

                if n_assign == 0:
                    continue

                base_angles = np.linspace(0, 2*np.pi, n_assign, endpoint=False)

                for k in range(n_assign):
                    if s_idx >= ns:
                        break

                    angle = base_angles[k] + (np.random.rand() - 0.5) * 0.25
                    r = CLUSTER_RADIUS * (1 - 0.35/2 + np.random.rand() * 0.35)

                    sx = fx_list[i] + r * np.cos(angle)
                    sy = fy_list[i] + r * np.sin(angle)

                    self.x[s_idx] = np.clip(sx, wx0 + 5, wx0 + ward_w - 5)
                    self.y[s_idx] = np.clip(sy, wy0 + 5, wy0 + ward_h - 5)
                    self.layer[s_idx] = 1
                    self.vlan[s_idx] = area_cfg['vlan']
                    self.ward[s_idx] = area_name
                    self.energy[s_idx] = Config.E_INIT

                    # Assign device type and IP
                    dev_name, dev_cfg = eligible_devices[k % len(eligible_devices)]
                    self.device_type[s_idx] = dev_name
                    self.ip[s_idx] = f'10.{area_cfg["vlan"]}.{s_idx // 254}.{(s_idx % 254) + 1}'

                    if dev_cfg.get('vitals', False):
                        self.vitals[s_idx] = [
                            70 + np.random.randn() * 5,
                            98 + np.random.randn() * 0.5,
                            120 + np.random.randn() * 5,
                            80 + np.random.randn() * 3,
                            37 + np.random.randn() * 0.2,
                            16 + np.random.randn() * 1,
                            90 + np.random.randn() * 5,
                            0
                        ]
                    s_idx += 1

        # Designate 10 random sensors as Honeypots
        honeypot_indices = np.random.choice(ns, min(10, ns), replace=False)
        for idx in honeypot_indices:
            self.device_type[idx] = 'Honeypot'
            
    def _place_gateways(self, W, H, ns, nf, ng):
        """Place 15 gateways along the top edge."""
        for i in range(ng):
            idx = ns + nf + i
            self.x[idx] = i * (W / max(ng - 1, 1))
            self.y[idx] = H * 0.95 + np.random.randn() * 3
            self.x[idx] = np.clip(self.x[idx], 0, W)
            self.y[idx] = np.clip(self.y[idx], 0, H)
            self.layer[idx] = 3
            self.vlan[idx] = 300
            self.energy[idx] = np.inf
            self.device_type[idx] = 'Gateway'
            self.ip[idx] = f'10.300.1.{idx - ns - nf + 1}'

    def _place_cloud(self, W, H, ns, nf, ng, nc):
        """Place 5 cloud nodes above the map (visual only)."""
        for i in range(nc):
            idx = ns + nf + ng + i
            self.x[idx] = (i + 0.5) * (W / nc)
            self.y[idx] = H * 1.08
            self.layer[idx] = 4
            self.vlan[idx] = 400
            self.energy[idx] = np.inf
            self.device_type[idx] = 'Cloud Server'
            self.ip[idx] = f'10.400.1.{idx - ns - nf - ng + 1}'

    def _place_datacenter(self, W, H, ns, nf, ng, nc, nd):
        """Place local datacenter above quarantine on the right."""
        for i in range(nd):
            idx = ns + nf + ng + nc + i
            self.x[idx] = W + 80
            self.y[idx] = H * 0.65
            self.layer[idx] = 5
            self.vlan[idx] = 500
            self.energy[idx] = np.inf
            self.device_type[idx] = 'Datacenter'
            self.ip[idx] = f'10.500.1.{i + 1}'

    def _build_routing(self, ns, nf, ng):
        """Build fog→gateway and gateway→cloud routing (nearest assignment)."""
        fog_xy = np.column_stack([
            self.x[ns:ns + nf], self.y[ns:ns + nf]
        ])
        gw_xy = np.column_stack([
            self.x[ns + nf:ns + nf + ng], self.y[ns + nf:ns + nf + ng]
        ])
        cloud_xy = np.column_stack([
            self.x[ns + nf + ng:], self.y[ns + nf + ng:]
        ])

        self.fog_gateway, _ = nearest_assignment(fog_xy, gw_xy)
        self.gw_cloud, _ = nearest_assignment(gw_xy, cloud_xy)

    def _create_dmz_nodes(self, W, H):
        """Create virtual DMZ service nodes for topology display."""
        dmz = []
        services = ['Web Server', 'DNS Server', 'Mail Server']
        for i, svc in enumerate(services):
            dmz.append({
                'x': W * 0.2 + i * (W * 0.3),
                'y': H * 1.15,
                'type': svc,
                'vlan': 10,
                'status': 'active',
            })
        return dmz

    # ── Clustering ───────────────────────────────────────────────────────

    def form_clusters(self):
        """
        LEACH-style clustering: assign each active sensor to nearest
        active cluster head (fog node).
        """
        ns = self.cfg.N_SENSORS
        nf = self.cfg.N_FOG

        # Determine active sensors
        active = self.status[:ns] == 'active'

        # LEACH: each fog node has leach_p chance of being CH
        if self.cfg.CLUSTER_METHOD == 'leach':
            self.is_ch = np.random.rand(nf) < self.cfg.LEACH_P
            # Guarantee at least 10% are CH
            min_ch = max(10, int(nf * 0.1))
            if self.is_ch.sum() < min_ch:
                off = np.where(~self.is_ch)[0]
                need = min_ch - self.is_ch.sum()
                sel = np.random.choice(off, size=min(need, len(off)), replace=False)
                self.is_ch[sel] = True
        else:
            self.is_ch[:] = True

        ch_indices = np.where(self.is_ch)[0]
        if len(ch_indices) == 0:
            return

        sensor_xy = np.column_stack([self.x[:ns], self.y[:ns]])
        ch_xy = np.column_stack([
            self.x[ns + ch_indices], self.y[ns + ch_indices]
        ])

        # Assign active sensors to nearest CH
        for i in range(ns):
            if not active[i]:
                continue
            dists = np.sqrt(
                (ch_xy[:, 0] - sensor_xy[i, 0]) ** 2 +
                (ch_xy[:, 1] - sensor_xy[i, 1]) ** 2
            )
            nearest = np.argmin(dists)
            self.cluster_id[i] = ch_indices[nearest]
            self.dist_to_fog[i] = dists[nearest]

        # Build reverse mapping
        self.fog_members = [[] for _ in range(nf)]
        for i in range(ns):
            if active[i]:
                f = self.cluster_id[i]
                self.fog_members[f].append(i)
        self.cluster_sizes = np.array([len(m) for m in self.fog_members])

    # ── ACL Enforcement ──────────────────────────────────────────────────

    def check_acl(self, src_id, dst_id):
        """
        Check if traffic from src_id to dst_id is allowed by ACL rules.
        Returns ('allow'|'deny', rule_name).
        """
        src_vlan = self.vlan[src_id]
        dst_vlan = self.vlan[dst_id]

        # Quarantined nodes cannot communicate
        if src_vlan == 999 or self.status[src_id] == 'quarantined':
            return 'deny', 'quarantine_block'

        # Guest can only go to internet (represented by DMZ/external)
        if src_vlan == 106:
            if dst_vlan != 10:
                return 'deny', 'guest_isolation'
            return 'allow', 'guest_internet'

        # Sensor VLAN (101-106) rules
        if 101 <= src_vlan <= 105:
            # Can only talk to Fog (VLAN 200) — and only assigned fog
            if dst_vlan == 200:
                ns = self.cfg.N_SENSORS
                if src_id < ns:
                    assigned_fog = self.cluster_id[src_id]
                    dst_fog_idx = dst_id - ns
                    if dst_fog_idx == assigned_fog:
                        return 'allow', 'assigned_fog'
                    return 'deny', 'wrong_fog'
                return 'allow', 'sensor_to_fog'

            # Deny sensor→sensor (lateral movement)
            if 101 <= dst_vlan <= 106:
                return 'deny', 'no_lateral'

            # Deny sensor→gateway or sensor→cloud (tier-skipping)
            if dst_vlan in (300, 400):
                return 'deny', 'no_tier_skip'

        # Fog → Gateway (assigned only)
        if src_vlan == 200 and dst_vlan == 300:
            return 'allow', 'fog_to_gw'

        # Gateway → Cloud
        if src_vlan == 300 and dst_vlan == 400:
            return 'allow', 'gw_to_cloud'

        # Management VLAN has full access
        if src_vlan == 500:
            return 'allow', 'mgmt_access'

        return 'deny', 'default_deny'

    # ── State Serialization (for WebSocket) ──────────────────────────────

    def to_topology_state(self):
        """Serialize network state for frontend topology rendering."""
        ns = self.cfg.N_SENSORS
        nf = self.cfg.N_FOG
        ng = self.cfg.N_GATEWAYS

        nodes = []
        for i in range(self.cfg.N_TOTAL):
            node = {
                'id': i,
                'x': float(self.x[i]),
                'y': float(self.y[i]),
                'layer': int(self.layer[i]),
                'vlan': int(self.vlan[i]),
                'ward': str(self.ward[i]),
                'device_type': str(self.device_type[i]),
                'ip': str(self.ip[i]),
                'status': str(self.status[i]),
                'energy': float(self.energy[i]) if not np.isinf(self.energy[i]) else -1,
            }
            if i < ns:
                node['cluster_id'] = int(self.cluster_id[i])
            nodes.append(node)

        # Routing links: fog → gateway
        fog_links = []
        for f in range(nf):
            gw = int(self.fog_gateway[f])
            fog_links.append({
                'from': ns + f,
                'to': ns + nf + gw,
            })

        # Routing links: gateway → cloud
        gw_links = []
        for g in range(ng):
            cl = int(self.gw_cloud[g])
            gw_links.append({
                'from': ns + nf + g,
                'to': ns + nf + ng + cl,
            })

        return {
            'nodes': nodes,
            'fog_links': fog_links,
            'gw_links': gw_links,
            'dmz_nodes': self.dmz_nodes,
            'firewalls': self.firewalls,
            'floor': {'w': self.cfg.FLOOR_W, 'h': self.cfg.FLOOR_H},
            'vlans': self.cfg.VLANS,
            'clinical_areas': self.cfg.CLINICAL_AREAS,
            'cluster_sizes': self.cluster_sizes.tolist(),
        }

    def to_health_state(self):
        """Serialize health metrics for dashboard."""
        ns = self.cfg.N_SENSORS
        active = int((self.status[:ns] == 'active').sum())
        dead = int((self.status[:ns] == 'dead').sum())
        quarantined = int((self.status[:ns] == 'quarantined').sum())

        return {
            'active_sensors': active,
            'dead_sensors': dead,
            'quarantined_sensors': quarantined,
            'total_sensors': ns,
            'survival_rate': active / ns * 100 if ns > 0 else 0,
            'avg_energy': float(np.mean(
                self.energy[:ns][self.energy[:ns] < np.inf]
            )) if active > 0 else 0,
            'avg_fog_load': float(np.mean(self.fog_load)),
            'n_dead': self.n_dead,
        }
