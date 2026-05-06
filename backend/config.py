"""
config.py — All simulation parameters, VLAN definitions, clinical areas, device types.
Ported from get_config.m with additions for DMZ, VLANs, honeypots, and guest network.
"""


class Config:
    """Central configuration for the Hospital Fog Network IDS simulation."""

    # ── Network Size ──────────────────────────────────────────────────────
    N_SENSORS = 1360
    N_FOG = 100
    N_GATEWAYS = 15
    N_CLOUD = 5
    N_DATACENTER = 1
    N_TOTAL = N_SENSORS + N_FOG + N_GATEWAYS + N_CLOUD + N_DATACENTER

    # ── Clinical Areas (Ward Layout) ─────────────────────────────────────
    # Each ward maps to a VLAN and a set of sensor indices
    CLINICAL_AREAS = {
        'ICU':          {'vlan': 101, 'sensor_count': 240, 'color': '#ff4757'},
        'General Ward': {'vlan': 102, 'sensor_count': 480, 'color': '#2ed573'},
        'Pharmacy':     {'vlan': 103, 'sensor_count': 120, 'color': '#ffa502'},
        'Radiology':    {'vlan': 104, 'sensor_count': 120, 'color': '#3742fa'},
        'Facility':     {'vlan': 105, 'sensor_count': 240, 'color': '#a55eea'},
        'Guest':        {'vlan': 106, 'sensor_count': 160, 'color': '#747d8c'},
    }

    # ── Medical Device Types ─────────────────────────────────────────────
    # Maps device types to their ward placement and data characteristics
    DEVICE_TYPES = {
        'Patient Monitor': {
            'wards': ['ICU', 'General Ward'],
            'data_rate': 8,       # packets/step (high-freq telemetry)
            'icon': 'monitor',
            'vitals': True,
        },
        'Ventilator': {
            'wards': ['ICU'],
            'data_rate': 10,      # high-frequency respiratory data
            'icon': 'ventilator',
            'vitals': True,
        },
        'Infusion Pump': {
            'wards': ['ICU', 'General Ward'],
            'data_rate': 4,       # periodic flow rate updates
            'icon': 'pump',
            'vitals': False,
        },
        'Nurse Call': {
            'wards': ['ICU', 'General Ward', 'Pharmacy'],
            'data_rate': 1,       # sporadic event-driven
            'icon': 'nurse_call',
            'vitals': False,
        },
        'Pharmacy Dispenser': {
            'wards': ['Pharmacy'],
            'data_rate': 2,       # batch inventory updates
            'icon': 'dispenser',
            'vitals': False,
        },
        'PACS Terminal': {
            'wards': ['Radiology'],
            'data_rate': 6,       # large imaging payloads
            'icon': 'pacs',
            'vitals': False,
        },
        'HVAC Controller': {
            'wards': ['Facility'],
            'data_rate': 2,       # low-rate telemetry
            'icon': 'hvac',
            'vitals': False,
        },
        'Access Control': {
            'wards': ['Facility'],
            'data_rate': 1,       # door badge events
            'icon': 'access',
            'vitals': False,
        },
        'Guest Device': {
            'wards': ['Guest'],
            'data_rate': 3,       # web browsing traffic
            'icon': 'guest',
            'vitals': False,
        },
    }

    # ── VLAN Definitions ─────────────────────────────────────────────────
    VLANS = {
        10:  {'name': 'DMZ',         'zone': 'dmz',        'color': '#e17055'},
        101: {'name': 'ICU',         'zone': 'lan_sensor', 'color': '#ff4757'},
        102: {'name': 'General Ward','zone': 'lan_sensor', 'color': '#2ed573'},
        103: {'name': 'Pharmacy',    'zone': 'lan_sensor', 'color': '#ffa502'},
        104: {'name': 'Radiology',   'zone': 'lan_sensor', 'color': '#3742fa'},
        105: {'name': 'Facility',    'zone': 'lan_sensor', 'color': '#a55eea'},
        106: {'name': 'Guest',       'zone': 'lan_sensor', 'color': '#747d8c'},
        200: {'name': 'Fog',         'zone': 'lan_infra',  'color': '#00d2d3'},
        300: {'name': 'Gateway',     'zone': 'lan_infra',  'color': '#feca57'},
        400: {'name': 'Cloud',       'zone': 'lan_infra',  'color': '#ff6b6b'},
        500: {'name': 'Management',  'zone': 'mgmt',       'color': '#54a0ff'},
        999: {'name': 'Quarantine',  'zone': 'quarantine', 'color': '#636e72'},
    }

    # ── Floor-Plan Bounds (metres) ───────────────────────────────────────
    FLOOR_W = 500
    FLOOR_H = 400

    # ── Energy Model ─────────────────────────────────────────────────────
    E_INIT = 2.0           # J — initial sensor battery
    E_TX = 50e-9           # J/bit — transmit electronics
    E_RX = 50e-9           # J/bit — receive electronics
    E_AMP = 100e-12        # J/bit/m² — amplifier
    PKT_BITS = 512         # bits per packet

    # ── Communication ────────────────────────────────────────────────────
    BASE_PKT_RATE = 5      # packets/step per sensor (Poisson λ, overridden by device type)
    BASE_LATENCY_MS = 10   # ms — baseline one-way latency
    BASE_PKT_LOSS = 0.01   # 1% baseline packet loss
    FOG_PROC_MS = 2        # ms — fog processing delay
    GW_PROC_MS = 5         # ms — gateway aggregation delay
    CLOUD_PROC_MS = 15     # ms — cloud processing delay

    # ── Congestion / Queuing ─────────────────────────────────────────────
    FOG_QUEUE_CAP = 200    # max packets a fog node can handle/step
    GW_QUEUE_CAP = 800     # max packets a gateway can handle/step
    CONGESTION_FACTOR = 0.3

    # ── Attack Configuration ─────────────────────────────────────────────
    ATTACK_PROB = 0.04     # probability of NEW attack event per step
    ATTACK_TYPES = ['DDoS', 'MITM', 'Replay', 'Nmap', 'APT', 'Injection']
    ATTACK_DUR_MIN = 200   # Exactly 20 seconds
    ATTACK_DUR_MAX = 200
    APT_RATE_MULT = 1.8    # APT: subtle rate multiplier
    APT_LATENCY_ADD = 8    # APT: latency increase (ms)

    # ── IDS Thresholds ───────────────────────────────────────────────────
    IDS_VOTE_THRESH = 3    # modules that must agree to fire alarm
    IDS_PKT_THRESH = 2.5   # Z-score threshold — packet rate
    IDS_LATENCY_THRESH = 2.0
    IDS_CUSUM_THRESH = 3.5
    IDS_ENTROPY_THRESH = 0.90
    IDS_EWMA_ALPHA = 0.10  # EWMA smoothing factor

    # CUSUM reset
    IDS_CUSUM_RESET = True

    # Temporal correlation (sliding window)
    IDS_WINDOW_LEN = 10
    IDS_WINDOW_THRESH = 0.3

    # Vital signs bounds
    VITAL_HR_RANGE = (30, 200)
    VITAL_SPO2_MIN = 70
    VITAL_BP_SYS_RANGE = (60, 250)
    VITAL_BP_DIA_RANGE = (30, 150)
    VITAL_TEMP_RANGE = (34, 42)
    VITAL_RR_RANGE = (5, 50)
    VITAL_GLUCOSE_RANGE = (30, 500)

    # Fog-level IDS
    FOG_CLUSTER_ALARM_THRESH = 0.15   # base threshold (overridden by dynamic formula)
    FOG_ANOMALY_AGG_THRESH = 0.35

    # ── Dynamic Clustering ───────────────────────────────────────────────
    RECLUSTER_EVERY = 50
    CLUSTER_METHOD = 'leach'
    LEACH_P = 0.1

    # ── Simulation Control ───────────────────────────────────────────────
    MAX_ITER = 500
    SIM_TICK_MS = 100      # ms between simulation ticks (for real-time pacing)
    SAVE_RESULTS = True

    # ── Honeypot Configuration ───────────────────────────────────────────
    HONEYPOTS_DMZ = [
        {'type': 'ssh',    'port': 22,   'name': 'SSH Decoy'},
        {'type': 'http',   'port': 80,   'name': 'Web Decoy'},
        {'type': 'telnet', 'port': 23,   'name': 'Telnet Decoy'},
        {'type': 'dns',    'port': 53,   'name': 'DNS Decoy'},
        {'type': 'smtp',   'port': 25,   'name': 'SMTP Decoy'},
    ]
    HONEYPOTS_LAN = [
        {'type': 'ventilator', 'ward': 'ICU',          'name': 'Fake Ventilator'},
        {'type': 'monitor',    'ward': 'General Ward',  'name': 'Fake Monitor'},
        {'type': 'pump',       'ward': 'ICU',           'name': 'Fake Pump'},
        {'type': 'dispenser',  'ward': 'Pharmacy',      'name': 'Fake Dispenser'},
        {'type': 'pacs',       'ward': 'Radiology',     'name': 'Fake PACS'},
    ]

    # ── Inter-VLAN ACL Rules ─────────────────────────────────────────────
    # Format: (src_vlan_pattern, dst_vlan, action, constraint)
    ACL_RULES = [
        # Sensors can only talk to Fog (assigned cluster head)
        ('10x', 200, 'ALLOW', 'assigned_fog_only'),
        # No sensor-to-sensor lateral movement
        ('10x', '10x', 'DENY', 'no_lateral'),
        # No tier-skipping (sensor→gateway or sensor→cloud)
        ('10x', 300, 'DENY', 'no_tier_skip'),
        ('10x', 400, 'DENY', 'no_tier_skip'),
        # Guest → Internet only
        (106, 'internet', 'ALLOW', 'guest_internet'),
        # Guest → Any internal VLAN = DENY
        (106, '*_internal', 'DENY', 'guest_isolation'),
        # Fog → assigned Gateway only
        (200, 300, 'ALLOW', 'assigned_gw_only'),
        # Gateway → Cloud
        (300, 400, 'ALLOW', 'gw_to_cloud'),
        # Management → All internal
        (500, '*', 'ALLOW', 'mgmt_full_access'),
        # Quarantine → DENY ALL
        (999, '*', 'DENY', 'quarantine_block'),
    ]
