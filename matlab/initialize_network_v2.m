function net = initialize_network_v2(config)
% INITIALIZE_NETWORK_V2 - Build 800-node hospital network with VLAN
% segmentation, clinical area placement, and medical device types.
%
% Output: net struct with fields:
%   x, y         - node positions (N_TOTAL x 1)
%   layer        - 1=sensor, 2=fog, 3=gw, 4=cloud
%   vlan         - VLAN assignment
%   ward         - clinical area name (cell array)
%   device_type  - device type name (cell array)
%   energy       - battery level
%   status       - 'active', 'dead', 'quarantined' (cell array)
%   vitals       - vital signs matrix (N_TOTAL x 8)
%   cluster_id   - fog cluster assignment for sensors
%   fog_gateway  - gateway assignment for fog nodes
%   gw_cloud     - cloud assignment for gateways

    rng(42);  % reproducible placement

    N  = config.N_TOTAL;
    ns = config.N_SENSORS;
    nf = config.N_FOG;
    ng = config.N_GATEWAYS;
    nc = config.N_CLOUD;
    W  = config.FLOOR_W;
    H  = config.FLOOR_H;

    net.x           = zeros(N, 1);
    net.y           = zeros(N, 1);
    net.layer       = zeros(N, 1);
    net.vlan        = zeros(N, 1);
    net.ward        = cell(N, 1);
    net.device_type = cell(N, 1);
    net.ip          = cell(N, 1);
    net.energy      = zeros(N, 1);
    net.status      = repmat({'active'}, N, 1);
    % Default vitals to physiologically normal values for ALL nodes.
    % This prevents Module 7 (vital signs integrity) from flagging non-vital
    % devices that would otherwise report zeros, violating every vital range.
    % HR=72, SpO2=98, BP_sys=120, BP_dia=80, Temp=36.6, RR=16, Glucose=90, pad=0
    net.vitals = repmat([72, 98, 120, 80, 36.6, 16, 90, 0], N, 1);

    % ---- Place Sensors and Fog Nodes by Clinical Area ----
    ward_names  = fieldnames(config.WARDS);
    n_cols = 3; n_rows = 2;
    ward_w = W / n_cols;
    ward_h = H / n_rows;
    idx = 1;
    f_idx = 1;

    for a = 1:length(ward_names)
        wname = ward_names{a};
        winfo = config.WARDS.(wname);
        col = mod(a-1, n_cols);
        row = floor((a-1) / n_cols);
        wx0 = col * ward_w;
        wy0 = row * ward_h;

        % Get eligible device types for this ward
        eligible = {};
        for d = 1:size(config.DEVICE_TYPES, 1)
            dinfo = config.DEVICE_TYPES{d, 2};
            if any(strcmp(wname, dinfo.wards))
                eligible{end+1} = config.DEVICE_TYPES{d, 1}; %#ok<AGROW>
            end
        end
        if isempty(eligible)
            eligible = {'GenericSensor'};
        end

        % 1. Place Fog Nodes strictly avoiding overlaps
        fogs_this_ward = floor(nf / length(ward_names));
        if a == length(ward_names), fogs_this_ward = nf - (f_idx - 1); end % remainder
        
        fx_list = zeros(fogs_this_ward, 1);
        fy_list = zeros(fogs_this_ward, 1);
        
        CLUSTER_RADIUS = 28;
        MIN_FOG_SPACING = 2 * CLUSTER_RADIUS + 10; % 66 units
        
        for i = 1:fogs_this_ward
            if f_idx > nf, break; end
            fi = ns + f_idx;
            
            placed = false;
            attempts = 0;
            while ~placed && attempts < 1000
                cx = wx0 + CLUSTER_RADIUS + rand() * (ward_w - 2*CLUSTER_RADIUS);
                cy = wy0 + CLUSTER_RADIUS + rand() * (ward_h - 2*CLUSTER_RADIUS);
                
                if i == 1
                    placed = true;
                else
                    dists = sqrt((fx_list(1:i-1) - cx).^2 + (fy_list(1:i-1) - cy).^2);
                    if all(dists >= MIN_FOG_SPACING)
                        placed = true;
                    end
                end
                attempts = attempts + 1;
            end
            
            fx_list(i) = cx;
            fy_list(i) = cy;
            
            net.x(fi) = cx;
            net.y(fi) = cy;
            net.layer(fi) = 2;
            net.vlan(fi)  = 200;
            net.energy(fi) = Inf;
            net.device_type{fi} = 'FogNode';
            net.ip{fi} = sprintf('10.200.1.%d', f_idx);
            f_idx = f_idx + 1;
        end

        % 2. Place Sensors strictly clustered radially around the Fog Nodes
        sensors_per_fog = floor(winfo.count / fogs_this_ward);
        
        for i = 1:fogs_this_ward
            n_assign = sensors_per_fog;
            if i == fogs_this_ward
                n_assign = winfo.count - (i-1)*sensors_per_fog; % remainder
            end
            
            if n_assign == 0, continue; end
            
            base_angles = linspace(0, 2*pi, n_assign+1);
            base_angles = base_angles(1:end-1);
            
            for k = 1:n_assign
                if idx > ns, break; end
                
                % Add jitter so it looks organic but maintains the ring structure
                angle = base_angles(k) + (rand()-0.5) * 0.25;
                r     = CLUSTER_RADIUS * (1 - 0.35/2 + rand()*0.35);
                
                sx = fx_list(i) + r * cos(angle);
                sy = fy_list(i) + r * sin(angle);
                
                % Keep within ward bounds (should be safe due to MIN_FOG_SPACING, but fallback)
                net.x(idx) = max(wx0 + 5, min(wx0 + ward_w - 5, sx));
                net.y(idx) = max(wy0 + 5, min(wy0 + ward_h - 5, sy));
            
                net.layer(idx) = 1;
                net.vlan(idx)  = winfo.vlan;
                net.ward{idx}  = wname;
                net.energy(idx) = config.E_INIT;

                % Assign device type
                dev_name = eligible{mod(k-1, length(eligible)) + 1};
                net.device_type{idx} = dev_name;
                net.ip{idx} = sprintf('10.%d.%d.%d', winfo.vlan, floor(idx/254), mod(idx, 254)+1);

                % Generate baseline vitals for vital-sign devices
                dev_info = [];
                for d = 1:size(config.DEVICE_TYPES, 1)
                    if strcmp(config.DEVICE_TYPES{d,1}, dev_name)
                        dev_info = config.DEVICE_TYPES{d, 2};
                        break;
                    end
                end
                if ~isempty(dev_info) && dev_info.has_vitals
                    net.vitals(idx, :) = [ ...
                        70 + randn()*5, 98 + randn()*0.5, 120 + randn()*5, ...
                        80 + randn()*3, 37 + randn()*0.2, 16 + randn()*1, ...
                        90 + randn()*5, 0 ...
                    ];
                end
                idx = idx + 1;
            end
        end
    end
    
    % Designate 10 random sensors as Honeypots
    honeypot_indices = randperm(ns, min(10, ns));
    for i = 1:length(honeypot_indices)
        net.device_type{honeypot_indices(i)} = 'Honeypot';
    end

    % ---- Place Gateways (DMZ) ----
    for i = 1:ng
        gi = ns + nf + i;
        net.x(gi) = (i - 0.5) * (W / ng);
        net.y(gi) = H * 1.08; % Inside DMZ
        net.layer(gi) = 3;
        net.vlan(gi)  = 300;
        net.energy(gi) = Inf;
        net.device_type{gi} = 'Gateway';
        net.ip{gi} = sprintf('10.300.1.%d', i);
    end

    % ---- Place Cloud (Internet zone) ----
    for i = 1:nc
        ci = ns + nf + ng + i;
        net.x(ci) = (i - 0.5) * (W / nc);
        net.y(ci) = H * 1.25;
        net.layer(ci) = 4;
        net.vlan(ci)  = 400;
        net.energy(ci) = Inf;
        net.device_type{ci} = 'CloudServer';
        net.ip{ci} = sprintf('10.400.1.%d', i);
    end

    % ---- Place Local Datacenter (Separate network behind firewall) ----
    nd = config.N_DATACENTER;
    for i = 1:nd
        di = ns + nf + ng + nc + i;
        net.x(di) = W + 80;         % Centered above Quarantine zone (W+20 to W+140)
        net.y(di) = H * 0.65;       % Above Quarantine (H*0.4 to H*0.9)
        net.layer(di) = 5;
        net.vlan(di)  = 500;
        net.energy(di) = Inf;
        net.device_type{di} = 'Datacenter';
        net.ip{di} = sprintf('10.500.1.%d', i);
    end

    % ---- Build Routing: Fog -> Gateway (nearest) ----
    fog_xy = [net.x(ns+1:ns+nf), net.y(ns+1:ns+nf)];
    gw_xy  = [net.x(ns+nf+1:ns+nf+ng), net.y(ns+nf+1:ns+nf+ng)];
    % Only slice the 5 cloud nodes — exclude the datacenter appended after them
    cloud_xy = [net.x(ns+nf+ng+1:ns+nf+ng+nc), net.y(ns+nf+ng+1:ns+nf+ng+nc)];

    net.fog_gateway = zeros(nf, 1);
    for f = 1:nf
        dists = sqrt(sum((gw_xy - fog_xy(f,:)).^2, 2));
        [~, net.fog_gateway(f)] = min(dists);
    end

    net.gw_cloud = zeros(ng, 1);
    for g = 1:ng
        dists = sqrt(sum((cloud_xy - gw_xy(g,:)).^2, 2));
        [~, net.gw_cloud(g)] = min(dists);
    end

    % Datacenter routing: connect to nearest gateway
    net.dc_gateway = zeros(nd, 1);
    for d = 1:nd
        di = ns + nf + ng + nc + d;
        dists = sqrt(sum((gw_xy - [net.x(di), net.y(di)]).^2, 2));
        [~, net.dc_gateway(d)] = min(dists);
    end

    % ---- Initial Clustering ----
    net = form_clusters_v2(net, config);

    % ---- Fog Queue State ----
    net.fog_queue = zeros(nf, 1);
    net.fog_load  = zeros(nf, 1);
    net.n_dead    = 0;

    fprintf('[INIT] Network ready: %d sensors, %d fog, %d gateways, %d cloud, %d datacenter\n', ...
        ns, nf, ng, nc, nd);
    fprintf('[INIT] VLANs: %d configured\n', length(keys(config.VLANS)));
end
