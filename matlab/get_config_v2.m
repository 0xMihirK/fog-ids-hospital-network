function config = get_config_v2()
% GET_CONFIG_V2 - Enhanced configuration for Hospital Fog IDS.
% Includes VLAN segmentation, clinical areas, medical device types,
% honeypot placement, and inter-VLAN ACL definitions.

    % ---- Network Size ----
    config.N_SENSORS   = 1360;
    config.N_FOG       = 100;
    config.N_GATEWAYS  = 15;
    config.N_CLOUD     = 5;
    config.N_DATACENTER= 1;
    config.N_TOTAL     = config.N_SENSORS + config.N_FOG + config.N_GATEWAYS + config.N_CLOUD + config.N_DATACENTER;
    config.FLOOR_W     = 500;  % metres
    config.FLOOR_H     = 400;

    % ---- Clinical Areas (Ward Layout) ----
    config.WARDS = struct( ...
        'ICU',          struct('vlan', 101, 'count', 240, 'color', [1 0.27 0.34]), ...
        'GeneralWard',  struct('vlan', 102, 'count', 480, 'color', [0.18 0.84 0.45]), ...
        'Pharmacy',     struct('vlan', 103, 'count', 120, 'color', [1 0.65 0.01]), ...
        'Radiology',    struct('vlan', 104, 'count', 120, 'color', [0.22 0.26 0.98]), ...
        'Facility',     struct('vlan', 105, 'count', 240, 'color', [0.65 0.37 0.91]), ...
        'Guest',        struct('vlan', 106, 'count', 160, 'color', [0.45 0.49 0.56]) ...
    );

    % ---- VLAN Definitions ----
    config.VLANS = containers.Map( ...
        {10, 101, 102, 103, 104, 105, 106, 200, 300, 400, 500, 999}, ...
        {'DMZ', 'ICU', 'GeneralWard', 'Pharmacy', 'Radiology', ...
         'Facility', 'Guest', 'Fog', 'Gateway', 'Cloud', 'Management', 'Quarantine'} ...
    );

    % ---- Medical Device Types ----
    config.DEVICE_TYPES = { ...
        'PatientMonitor', struct('wards', {{'ICU','GeneralWard'}}, 'data_rate', 8,  'has_vitals', true);  ...
        'Ventilator',     struct('wards', {{'ICU'}},              'data_rate', 10, 'has_vitals', true);  ...
        'InfusionPump',   struct('wards', {{'ICU','GeneralWard'}}, 'data_rate', 4,  'has_vitals', false); ...
        'NurseCall',      struct('wards', {{'ICU','GeneralWard','Pharmacy'}}, 'data_rate', 1, 'has_vitals', false); ...
        'PharmDispenser', struct('wards', {{'Pharmacy'}},         'data_rate', 2,  'has_vitals', false); ...
        'PACS',           struct('wards', {{'Radiology'}},        'data_rate', 6,  'has_vitals', false); ...
        'HVAC',           struct('wards', {{'Facility'}},         'data_rate', 2,  'has_vitals', false); ...
        'AccessControl',  struct('wards', {{'Facility'}},         'data_rate', 1,  'has_vitals', false); ...
        'GuestDevice',    struct('wards', {{'Guest'}},            'data_rate', 3,  'has_vitals', false)  ...
    };

    % ---- Energy Model ----
    config.E_INIT    = 100.0;       % J (Increased for continuous running)
    config.E_TX      = 50e-9;     % J/bit
    config.E_RX      = 50e-9;     % J/bit
    config.E_AMP     = 100e-12;   % J/bit/m^2
    config.PKT_BITS  = 512;

    % ---- Communication ----
    config.BASE_PKT_RATE     = 5;      % packets/step
    config.BASE_LATENCY_MS   = 10;
    config.BASE_PKT_LOSS     = 0.01;
    config.FOG_PROC_MS       = 2;
    config.GW_PROC_MS        = 5;
    config.CLOUD_PROC_MS     = 15;
    config.FOG_QUEUE_CAP     = 200;
    config.GW_QUEUE_CAP      = 800;
    config.CONGESTION_FACTOR = 0.3;

    % ---- Attack Configuration ----
    config.ATTACK_PROB     = 0.0; % Only trigger attacks manually via dashboard
    config.ATTACK_TYPES    = {'DDoS', 'MITM', 'Replay', 'Nmap', 'APT', 'Injection'};
    config.ATTACK_DUR_MIN  = 200;   % Exactly 20 seconds (200 ticks at 10 FPS)
    config.ATTACK_DUR_MAX  = 200;
    config.APT_RATE_MULT   = 1.8;
    config.APT_LATENCY_ADD = 8;

    % ---- IDS Thresholds ----
    config.IDS_VOTE_THRESH        = 3;     % Min votes out of 7 to fire alarm
    config.IDS_PKT_THRESH         = 2.5;   % Z-score threshold for packet rate
    config.IDS_LATENCY_THRESH     = 2.0;   % Z-score threshold for latency
    config.IDS_CUSUM_THRESH       = 3.5;   % CUSUM alarm threshold
    config.IDS_ENTROPY_THRESH     = 0.90;  % Entropy ratio threshold
    config.IDS_EWMA_ALPHA         = 0.10;  % EWMA smoothing
    config.IDS_CUSUM_RESET        = true;
    config.IDS_WINDOW_LEN         = 15;    % Sliding window length
    config.IDS_WINDOW_THRESH      = 0.35;  % Min fraction of window alarming
    
    % ---- IDS Warm-up & Quarantine Guards ----
    config.IDS_WARMUP_TICKS           = 30;   % Faster warmup
    config.IDS_CUSUM_DECAY            = 0.95; 
    config.FOG_ALARM_FRACTION         = 0.20; 
    config.FOG_ANOMALY_AGG_THRESH     = 0.40; 
    config.MIN_NODE_AGE_QUARANTINE    = 30;   
    config.IDS_CONFIDENCE_THRESHOLD   = 0.40; % Lowered so sustained attacks trigger quarantine
    config.IDS_SUSTAINED_WINDOW_FRAC  = 0.40;
    
    % ---- Normal Traffic Baselines (for IDS EWMA initialization) ----
    config.NORMAL_PKT_RATE    = config.BASE_PKT_RATE;      % pkts/tick (Poisson mean)
    config.NORMAL_PKT_STD     = sqrt(config.BASE_PKT_RATE); % Poisson std dev
    config.NORMAL_LATENCY     = config.BASE_LATENCY_MS;    % ms
    config.NORMAL_LAT_STD     = 2.0;                       % ms (from randn*2 in generation)

    % ---- Vital Signs Bounds ----
    config.VITAL_HR_RANGE      = [30 200];
    config.VITAL_SPO2_MIN      = 70;
    config.VITAL_BP_SYS_RANGE  = [60 250];
    config.VITAL_BP_DIA_RANGE  = [30 150];
    config.VITAL_TEMP_RANGE    = [34 42];
    config.VITAL_RR_RANGE      = [5 50];
    config.VITAL_GLUCOSE_RANGE = [30 500];

    % ---- Fog-level IDS ----
    config.FOG_CLUSTER_ALARM_THRESH = 0.15;
    config.FOG_ANOMALY_AGG_THRESH   = 0.35;

    % ---- Dynamic Clustering ----
    config.RECLUSTER_EVERY = 50;
    config.LEACH_P         = 0.1;

    % ---- Simulation Control ----
    config.MAX_ITER    = 1000000; % Run indefinitely for real-time monitoring
    config.SIM_TICK_MS = 100;

    % ---- Honeypot Configuration ----
    config.HONEYPOTS_DMZ = { ...
        struct('type', 'ssh',    'port', 22, 'name', 'SSH Decoy'); ...
        struct('type', 'http',   'port', 80, 'name', 'Web Decoy'); ...
        struct('type', 'telnet', 'port', 23, 'name', 'Telnet Decoy'); ...
        struct('type', 'dns',    'port', 53, 'name', 'DNS Decoy'); ...
        struct('type', 'smtp',   'port', 25, 'name', 'SMTP Decoy') ...
    };
    config.HONEYPOTS_LAN = { ...
        struct('type', 'ventilator', 'ward', 'ICU',          'name', 'Fake Ventilator'); ...
        struct('type', 'monitor',    'ward', 'GeneralWard',  'name', 'Fake Monitor'); ...
        struct('type', 'pump',       'ward', 'ICU',          'name', 'Fake Pump'); ...
        struct('type', 'dispenser',  'ward', 'Pharmacy',     'name', 'Fake Dispenser'); ...
        struct('type', 'pacs',       'ward', 'Radiology',    'name', 'Fake PACS') ...
    };

    % ---- Dashboard Output ----
    % Point to the root Fog-Project/sim_output so Python and MATLAB share the same directory
    config.OUTPUT_DIR = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'sim_output');
    if ~exist(config.OUTPUT_DIR, 'dir')
        mkdir(config.OUTPUT_DIR);
    end
end
