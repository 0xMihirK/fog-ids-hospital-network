function visualize_network(net, config, attack, alarm, anomaly_score, traffic_pkt, fog_alarm, t)
% VISUALIZE_NETWORK - Real-time MATLAB network topology visualization.
% Implements highly optimized persistent graphics rendering with custom
% tooltips, live legends, heatmaps, and dynamic flow animation.

    if nargin < 3, attack = []; end
    if nargin < 4, alarm = []; end
    if nargin < 5, anomaly_score = zeros(config.N_SENSORS, 1); end
    if nargin < 6, traffic_pkt = zeros(config.N_SENSORS, 1); end
    if nargin < 7, fog_alarm = false(config.N_FOG, 1); end
    if nargin < 8, t = 0; end

    ns = config.N_SENSORS;
    nf = config.N_FOG;
    ng = config.N_GATEWAYS;
    nc = config.N_CLOUD;
    W  = config.FLOOR_W;
    H  = config.FLOOR_H;
    
    persistent fig h pkt_prog atk_prog;
    
    % Initialize figure and static elements ONCE (or if network scale changes)
    if isempty(fig) || ~ishandle(fig) || length(pkt_prog) ~= ns
        if ishandle(fig), close(fig); end
        fig = figure('Name', 'Hospital Fog Network - Topology', ...
            'NumberTitle', 'off', 'Color', [0.04 0.06 0.09], ...
            'Position', [50 50 1400 900], 'MenuBar', 'none', ...
            'ToolBar', 'figure');
        set(gca, 'Color', [0.06 0.08 0.12], 'XColor', 'none', 'YColor', 'none', ...
            'Position', [0.01 0.01 0.98 0.98]);
        hold on;
        
        h = struct();
        
        % 1. Heatmap Overlay (Grid 20x10)
        h.nx = 20; h.ny = 10;
        [Xg, Yg] = meshgrid(linspace(0, W, h.nx+1), linspace(0, H, h.ny+1));
        h.heatmap = pcolor(Xg, Yg, zeros(h.ny+1, h.nx+1));
        shading flat;
        colormap(gca, custom_heat_cmap());
        set(h.heatmap, 'FaceAlpha', 0.0, 'EdgeColor', 'none'); 
        
        % 2. Static Architectural Bands & Zones
        % Wards — use non-conflicting soft pastels so they never clash with node status colors
        % Node status palette: green=clean, yellow=suspicious, orange=alarming, red=quarantined, grey=dead
        % Zone palette must avoid those hues → use: pale blue, pale lavender, pale teal,
        %                                            pale steel, pale rose-beige, pale indigo
        ward_names = fieldnames(config.WARDS);
        n_cols = 3; n_rows = 2;
        ward_w = W / n_cols;
        ward_h = H / n_rows;
        % Pastel, low-saturation colors far from green/yellow/orange/red
        zone_bg   = {[0.40 0.65 0.95],  ... % ICU         — soft sky-blue
                     [0.55 0.80 0.90],  ... % GeneralWard — pale teal
                     [0.70 0.60 0.95],  ... % Pharmacy    — soft lavender
                     [0.40 0.55 0.80],  ... % Radiology   — pale steel-blue
                     [0.80 0.70 0.95],  ... % Facility    — pale violet
                     [0.75 0.75 0.85]}; ... % Guest       — pale indigo-grey
        zone_alpha = 0.10; % Barely visible — background context only
        
        h.health_bars = gobjects(6, 1);
        for a = 1:length(ward_names)
            col = mod(a-1, n_cols);
            row = floor((a-1) / n_cols);
            x0 = col * ward_w;
            y0 = row * ward_h;
            c = zone_bg{a};
            
            % Filled rectangle — translucent pastel, no border stroke
            rectangle('Position', [x0 y0 ward_w ward_h], ...
                'EdgeColor', [1 1 1 0.08], ...           % near-invisible border
                'FaceColor', [c zone_alpha], ...
                'LineWidth', 0.5, 'Curvature', 0.04);
            
            % Watermark-style zone label: large, near-transparent, top-left anchored
            text(x0 + 12, y0 + ward_h - 16, ward_names{a}, ...
                'Color', [1 1 1 0.18], ...
                'FontSize', 18, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', ...
                'Interpreter', 'none', 'Clipping', 'off');
                
            % Health Bar background
            rectangle('Position', [x0+4 y0+10 4 ward_h-20], 'FaceColor', [1 1 1 0.08], 'EdgeColor', 'none');
            h.health_bars(a) = rectangle('Position', [x0+4 y0+10 4 ward_h-20], 'FaceColor', c, 'EdgeColor', 'none');
        end
        
        % Quarantine Zone (VLAN 999) — pastel style matching other zones
        qx = W + 20; qw = 120;
        rectangle('Position', [qx 0 qw H*0.4], ...
            'EdgeColor', [1 1 1 0.08], ...
            'FaceColor', [0.85 0.55 0.55 0.10], ...  % muted rose, low alpha
            'LineWidth', 0.5, 'Curvature', 0.04);
        text(qx + qw/2, H*0.4*0.5, 'QUARANTINE', ...
            'Color', [1 1 1 0.20], ...                % watermark style
            'FontSize', 14, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
            'Rotation', 90);
            
        % Datacenter Zone (above Quarantine)
        dc_y0 = H*0.45; dc_h = H*0.45;
        rectangle('Position', [qx dc_y0 qw dc_h], ...
            'EdgeColor', [0.06 0.67 0.52 0.3], ...
            'FaceColor', [0.06 0.67 0.52 0.08], ...
            'LineWidth', 1.5, 'LineStyle', '--', 'Curvature', 0.04);
        text(qx + qw/2, dc_y0 + dc_h*0.5, 'LOCAL DATACENTER', ...
            'Color', [0.06 0.67 0.52 0.3], ...
            'FontSize', 14, 'FontWeight', 'bold', ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
            'Rotation', 90);
        
        % DMZ and Cloud Bands
        y_cloud = H * 1.25;
        y_dmz   = H * 1.08;
        fill([0 qx+qw qx+qw 0], [y_cloud-25 y_cloud-25 y_cloud+30 y_cloud+30], ...
             [0.40 0.32 0.85], 'FaceAlpha', 0.08, 'EdgeColor', 'none');
        % Cloud label offset right to avoid CS-01 star overlap
        text(W*0.55, y_cloud, 'CLOUD LAYER', 'Color', [0.5 0.4 1.0], ...
            'FontSize', 9, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

        fill([0 qx+qw qx+qw 0], [y_dmz-25 y_dmz-25 y_dmz+25 y_dmz+25], ...
             [0.85 0.45 0.15], 'FaceAlpha', 0.08, 'EdgeColor', 'none');
        text(20, y_dmz, 'DMZ / GATEWAYS', 'Color', [1.0 0.6 0.2], 'FontSize', 9, 'FontWeight', 'bold');

        % Firewalls
        fw_y1 = H * 1.0;
        fw_y2 = y_dmz + 25;
        plot([0 qx+qw], [fw_y1 fw_y1], '--', 'Color', [0.87 0.90 0.91], 'LineWidth', 1.0);
        plot([0 qx+qw], [fw_y2 fw_y2], '--', 'Color', [0.87 0.90 0.91], 'LineWidth', 1.0);
        
        % 3. Dynamic Edges — distinct line weight per tier
        % Sensor→Fog: thin but visible intra-cluster links
        h.edges_sf = plot(nan, nan, '-', 'Color', [0.5 0.75 1.0 0.35], 'LineWidth', 0.8);
        % Fog→Gateway: medium, brighter (fewer, inter-zone links)
        h.edges_fg = plot(nan, nan, '-', 'Color', [0.9 0.85 0.5 0.30], 'LineWidth', 1.5);
        % Gateway→Cloud: thick, prominent (backbone links)
        h.edges_gc = plot(nan, nan, '-', 'Color', [0.7 0.5 1.0 0.55], 'LineWidth', 3.0);
        % Fog→Datacenter: teal dashed (storage replication links)
        h.edges_fd = plot(nan, nan, '--', 'Color', [0.06 0.67 0.52 0.25], 'LineWidth', 1.0);
        
        % Packet tracers: tiny diamonds (distinct from sensor circles) with glow
        h.traffic_pkts = scatter(nan, nan, 10, [0.3 0.8 1.0], 'd', 'filled', 'MarkerEdgeColor', 'none');
        h.attack_pkts  = scatter(nan, nan, 18, [1.0 0.15 0.15], 'd', 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.8);
        
        % 4. Nodes & Labels
        h.fog_labels = gobjects(nf, 1);
        for f = 1:nf
            fi = ns + f;
            h.fog_labels(f) = text(net.x(fi), net.y(fi) + 12, sprintf('FN-%02d', f), ...
                'Color', [1 1 1], 'FontSize', 7, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        end
        
        h.gw_labels = gobjects(ng, 1);
        for g = 1:ng
            gi = ns + nf + g;
            h.gw_labels(g) = text(net.x(gi), net.y(gi) + 14, sprintf('GW-%02d', g), ...
                'Color', [0.99 0.79 0.34], 'FontSize', 8, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        end
        
        h.cloud_labels = gobjects(nc, 1);
        for c = 1:nc
            ci = ns + nf + ng + c;
            h.cloud_labels(c) = text(net.x(ci), net.y(ci) + 15, sprintf('CS-%02d', c), ...
                'Color', [0.8 0.3 1.0], 'FontSize', 8, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        end
        
        h.sensors  = scatter(nan, nan, 25, 'o', 'filled', 'MarkerEdgeColor', 'none');
        h.honeypot = scatter(nan, nan, 45, [1.0 0.55 0.0], 'h', 'filled', 'MarkerEdgeColor', [1 1 1], 'LineWidth', 0.8);  % Hexagram, amber
        h.fog      = scatter(nan, nan, 80, [0 0.82 0.83], 'd', 'filled', 'MarkerEdgeColor', 'w', 'LineWidth', 1);
        h.gws      = scatter(nan, nan, 120, [0.99 0.79 0.34], 's', 'filled', 'MarkerEdgeColor', 'w', 'LineWidth', 1.5);
        h.cloud    = scatter(nan, nan, 200, [0.8 0.3 1.0], 'p', 'filled', 'MarkerEdgeColor', 'w', 'LineWidth', 1.5);
        h.dc       = scatter(nan, nan, 250, [0.06 0.67 0.52], 's', 'filled', 'MarkerEdgeColor', 'w', 'LineWidth', 2);
        h.quar     = scatter(nan, nan, 60, [1 0.2 0.2], 'x', 'LineWidth', 2);

        % Datacenter label
        nd = config.N_DATACENTER;
        for d = 1:nd
            di = ns + nf + ng + nc + d;
            text(net.x(di), net.y(di) + 18, 'DC-01', ...
                'Color', [0.06 0.67 0.52], 'FontSize', 9, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        end
        
        h.info_text = text(W/2, -20, '', 'Color', [0.8 0.85 0.9], 'FontSize', 11, ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold');
        
        % Limits
        xlim([-10 W + 150]);
        ylim([-40 y_cloud + 50]);
        
        % Setup Custom Tooltip
        dcm = datacursormode(fig);
        set(dcm, 'UpdateFcn', {@tooltip_callback, fig}, 'Enable', 'on');
        
        % Static Legend
        lg_items = {'Clean', 'Suspicious', 'Alarming', 'Dead', 'Quarantined', ...
            'Honeypot', 'Fog Node', 'Gateway', 'Cloud Server', 'Datacenter', ...
            'Normal Packet', 'Attack Packet'};
        lg_h = gobjects(12,1);
        lg_h(1)  = plot(nan,nan,'o','MarkerFaceColor',[0 1 0.5],'MarkerEdgeColor','none');
        lg_h(2)  = plot(nan,nan,'o','MarkerFaceColor',[1 1 0],'MarkerEdgeColor','none');
        lg_h(3)  = plot(nan,nan,'o','MarkerFaceColor',[1 0.5 0],'MarkerEdgeColor','none');
        lg_h(4)  = plot(nan,nan,'o','MarkerFaceColor',[0.4 0.4 0.4],'MarkerEdgeColor','none');
        lg_h(5)  = plot(nan,nan,'x','Color',[1 0.2 0.2],'MarkerSize',8,'LineWidth',2);
        lg_h(6)  = plot(nan,nan,'h','MarkerFaceColor',[1.0 0.55 0.0],'MarkerEdgeColor','w','MarkerSize',8);
        lg_h(7)  = plot(nan,nan,'d','MarkerFaceColor',[0 0.82 0.83],'MarkerEdgeColor','w');
        lg_h(8)  = plot(nan,nan,'s','MarkerFaceColor',[0.99 0.79 0.34],'MarkerEdgeColor','w');
        lg_h(9)  = plot(nan,nan,'p','MarkerFaceColor',[0.8 0.3 1.0],'MarkerEdgeColor','w');
        lg_h(10) = plot(nan,nan,'s','MarkerFaceColor',[0.06 0.67 0.52],'MarkerEdgeColor','w','MarkerSize',10);
        lg_h(11) = plot(nan,nan,'o','MarkerFaceColor',[0.2 0.8 1.0],'MarkerEdgeColor','none');
        lg_h(12) = plot(nan,nan,'o','MarkerFaceColor',[1 0.2 0.2],'MarkerEdgeColor','w');
        
        lg = legend(lg_h, lg_items, 'Location', 'northeast', 'TextColor', 'w', ...
            'Color', [0.1 0.1 0.15], 'EdgeColor', 'none', 'FontSize', 9);
        title(lg, 'Network Elements', 'Color', 'w');
        
        % Initialize packet progress (random phase so packets are spread across all edges)
        pkt_prog = rand(ns, 1);
        atk_prog = rand(ns, 1);
    end
    
    % Store data in figure for tooltip
    netData = struct('net', net, 'config', config, 'anomaly_score', anomaly_score, 'traffic', traffic_pkt);
    setappdata(fig, 'netData', netData);
    
    % -------------------------------------------------------------
    % UPDATE DYNAMIC ELEMENTS (Fast Render)
    % -------------------------------------------------------------
    
    % 1. Heatmap Overlay
    hmap = zeros(h.ny, h.nx);
    hcount = zeros(h.ny, h.nx);
    dx = W / h.nx; dy = H / h.ny;
    for i=1:ns
        if net.x(i) >= 0 && net.x(i) <= W && net.y(i) >= 0 && net.y(i) <= H
            cx = min(h.nx, max(1, ceil(net.x(i)/dx)));
            cy = min(h.ny, max(1, ceil(net.y(i)/dy)));
            hmap(cy, cx) = hmap(cy, cx) + anomaly_score(i);
            hcount(cy, cx) = hcount(cy, cx) + 1;
        end
    end
    hmap(hcount>0) = hmap(hcount>0) ./ hcount(hcount>0);
    
    % pcolor requires CData to be the same size as X/Y (ny+1 x nx+1)
    hmap_pad = zeros(h.ny+1, h.nx+1);
    hmap_pad(1:h.ny, 1:h.nx) = hmap;
    
    h.heatmap.CData = hmap_pad;
    h.heatmap.AlphaData = hmap_pad * 0.5; % Hotspots up to 50% opacity
    h.heatmap.FaceAlpha = 'flat';
    
    % 2. Sensor Status Colors (split honeypots from normal sensors)
    q_idx = []; 
    hp_idx = [];  % honeypot indices
    s_x = net.x(1:ns); s_y = net.y(1:ns);
    s_c = zeros(ns, 3);
    
    for i=1:ns
        is_hp = strcmp(net.device_type{i}, 'Honeypot');
        if strcmp(net.status{i}, 'quarantined')
            q_idx(end+1) = i; %#ok<AGROW>
            s_c(i,:) = [1 0.2 0.2];
            s_x(i) = nan; s_y(i) = nan; % Drawn by quarantine scatter
        elseif is_hp
            hp_idx(end+1) = i; %#ok<AGROW>
            s_x(i) = nan; s_y(i) = nan; % Drawn by honeypot scatter
            s_c(i,:) = [1.0 0.55 0.0];  % placeholder, won't be visible
        elseif strcmp(net.status{i}, 'dead')
            s_c(i,:) = [0.4 0.4 0.4];
        else
            if ~isempty(alarm) && alarm(i)
                s_c(i,:) = [1 0.5 0]; % Orange (Alarm)
            elseif anomaly_score(i) > 0.3
                s_c(i,:) = [1 1 0]; % Yellow (Suspicious)
            else
                s_c(i,:) = [0 1 0.5]; % Green (Clean)
            end
        end
    end
    h.sensors.XData = s_x;
    h.sensors.YData = s_y;
    h.sensors.CData = s_c;
    
    % Honeypot scatter (amber hexagram, always visible unless quarantined)
    if ~isempty(hp_idx)
        h.honeypot.XData = net.x(hp_idx);
        h.honeypot.YData = net.y(hp_idx);
    else
        h.honeypot.XData = nan; h.honeypot.YData = nan;
    end
    
    if ~isempty(q_idx)
        h.quar.XData = net.x(q_idx);
        h.quar.YData = net.y(q_idx);
    else
        h.quar.XData = nan; h.quar.YData = nan;
    end
    
    % 3. Fog, Gateways, Cloud Nodes
    h.fog.XData = net.x(ns+1:ns+nf);
    h.fog.YData = net.y(ns+1:ns+nf);
    h.gws.XData = net.x(ns+nf+1:ns+nf+ng);
    h.gws.YData = net.y(ns+nf+1:ns+nf+ng);
    h.cloud.XData = net.x(ns+nf+ng+1:ns+nf+ng+nc);
    h.cloud.YData = net.y(ns+nf+ng+1:ns+nf+ng+nc);
    
    % Datacenter node
    nd = config.N_DATACENTER;
    h.dc.XData = net.x(ns+nf+ng+nc+1:ns+nf+ng+nc+nd);
    h.dc.YData = net.y(ns+nf+ng+nc+1:ns+nf+ng+nc+nd);
    
    f_c = repmat([0 0.82 0.83], nf, 1);
    for f=1:nf
        % Fog Label Color
        if fog_alarm(f)
            h.fog_labels(f).Color = [1 0.5 0]; % Orange for alarm
            f_c(f,:) = [1 0.5 0];
        else
            h.fog_labels(f).Color = [1 1 1]; % White
            
            % Queue load color
            if net.fog_load(f) > 0.8
                f_c(f,:) = [1 0.3 0.3];
            elseif net.fog_load(f) > 0.5
                f_c(f,:) = [1 0.8 0];
            end
        end
    end
    h.fog.CData = f_c;
    
    % 4. Edges & Live Traffic Flow
    % Static edge lines
    esf_x = nan(3*ns, 1); esf_y = nan(3*ns, 1);
    idx = 1;
    for i=1:ns
        if net.cluster_id(i) > 0 && ~isnan(s_x(i)) && ~ismember(i, hp_idx)
            fi = ns + net.cluster_id(i);
            esf_x(idx:idx+2) = [net.x(i); net.x(fi); nan];
            esf_y(idx:idx+2) = [net.y(i); net.y(fi); nan];
            idx = idx + 3;
        end
    end
    h.edges_sf.XData = esf_x; h.edges_sf.YData = esf_y;
    
    efg_x = nan(3*nf, 1); efg_y = nan(3*nf, 1);
    idx = 1;
    for f=1:nf
        gi = ns + nf + net.fog_gateway(f);
        efg_x(idx:idx+2) = [net.x(ns+f); net.x(gi); nan];
        efg_y(idx:idx+2) = [net.y(ns+f); net.y(gi); nan];
        idx = idx + 3;
    end
    h.edges_fg.XData = efg_x; h.edges_fg.YData = efg_y;
    
    egc_x = nan(3*ng, 1); egc_y = nan(3*ng, 1);
    idx = 1;
    for g=1:ng
        ci = ns + nf + ng + net.gw_cloud(g);
        egc_x(idx:idx+2) = [net.x(ns+nf+g); net.x(ci); nan];
        egc_y(idx:idx+2) = [net.y(ns+nf+g); net.y(ci); nan];
        idx = idx + 3;
    end
    h.edges_gc.XData = egc_x; h.edges_gc.YData = egc_y;
    
    % Fog → Datacenter edges (all fog nodes replicate data to DC)
    if nd > 0
        di = ns + nf + ng + nc + 1;  % first datacenter node index
        efd_x = nan(3*nf, 1); efd_y = nan(3*nf, 1);
        idx = 1;
        for f=1:nf
            efd_x(idx:idx+2) = [net.x(ns+f); net.x(di); nan];
            efd_y(idx:idx+2) = [net.y(ns+f); net.y(di); nan];
            idx = idx + 3;
        end
        h.edges_fd.XData = efd_x; h.edges_fd.YData = efd_y;
    end
    
    % =================================================================
    % SUB-FRAME PACKET ANIMATION LOOP
    % Each simulation tick is divided into N_SUB frames.
    % Within each frame only the packet scatter XData/YData is updated,
    % all other (slow) elements are only updated on the first sub-frame.
    % This gives smooth Cisco Packet Tracer-style wire flow.
    % =================================================================
    N_SUB   = 8;          % sub-frames per simulation tick
    SUB_DT  = 0.10 / N_SUB; % seconds per sub-frame (total = 100ms/tick)
    PKT_SPD = 0.012;      % progress per sub-frame (full edge takes ~7 ticks @ 8 sub = ~56 frames)
    ATK_SPD = 0.020;      % attack packets are faster and denser
    
    % Active senders for this tick — force column vectors to prevent
    % MATLAB broadcasting (680×1 & 1×680 = 680×680 matrix)
    status_active = strcmp(net.status(1:ns), 'active');
    status_active = status_active(:);          % guarantee 680×1
    pkt_positive  = traffic_pkt(:) > 0;       % guarantee 680×1
    active_mask   = pkt_positive & status_active;
    active_list   = find(active_mask);
    n_active = length(active_list);
    
    % Limit to a visible sample — too many packets overlap and look like noise
    MAX_PKT = min(200, n_active);
    if n_active > MAX_PKT
        active_list = active_list(randperm(n_active, MAX_PKT));
    end
    
    % Pre-compute source/destination XY for active packets (static this tick)
    pkt_sx = zeros(MAX_PKT, 1); pkt_sy = zeros(MAX_PKT, 1);
    pkt_fx = zeros(MAX_PKT, 1); pkt_fy = zeros(MAX_PKT, 1);
    pkt_col = zeros(MAX_PKT, 3);
    valid_pkt = false(MAX_PKT, 1);
    for k = 1:length(active_list)
        si = active_list(k);
        if net.cluster_id(si) == 0, continue; end
        fi = ns + net.cluster_id(si);
        pkt_sx(k) = net.x(si); pkt_sy(k) = net.y(si);
        pkt_fx(k) = net.x(fi); pkt_fy(k) = net.y(fi);
        valid_pkt(k) = true;
        tp = traffic_pkt(si);
        if tp < 10,    pkt_col(k,:) = [0.20 0.75 1.00];
        elseif tp < 50, pkt_col(k,:) = [1.00 0.85 0.10];
        else,           pkt_col(k,:) = [1.00 0.35 0.10];
        end
    end
    pkt_prog_local = pkt_prog(active_list);
    
    % Attack packets (Only for internal malware/attacks, not external Honeypot probes)
    atk_list = [];
    if ~isempty(attack) && ~strcmpi(attack.type, 'Honeypot')
        for i = 1:length(attack.targets)
            ti = attack.targets(i);
            if ti <= ns && net.cluster_id(ti) > 0 && ~isnan(net.x(ti))
                atk_list(end+1) = ti; %#ok<AGROW>
            end
        end
    end
    n_atk = length(atk_list);
    atk_sx = zeros(n_atk*2,1); atk_sy = zeros(n_atk*2,1);
    atk_fx = zeros(n_atk*2,1); atk_fy = zeros(n_atk*2,1);
    atk_prog_pulse = zeros(n_atk*2,1);
    for k = 1:n_atk
        ti = atk_list(k);
        fi = ns + net.cluster_id(ti);
        atk_sx(2*k-1) = net.x(ti); atk_sy(2*k-1) = net.y(ti);
        atk_fx(2*k-1) = net.x(fi); atk_fy(2*k-1) = net.y(fi);
        atk_sx(2*k)   = net.x(ti); atk_sy(2*k)   = net.y(ti);
        atk_fx(2*k)   = net.x(fi); atk_fy(2*k)   = net.y(fi);
        atk_prog_pulse(2*k-1) = atk_prog(ti);
        atk_prog_pulse(2*k)   = mod(atk_prog(ti) + 0.5, 1.0);  % dual pulse
    end
    
    for sub = 1:N_SUB
        % Advance packet progress along their edges
        pkt_prog_local = mod(pkt_prog_local + PKT_SPD, 1.0);
        atk_prog_pulse = mod(atk_prog_pulse + ATK_SPD, 1.0);
        
        % Compute current XY positions via linear interpolation
        if any(valid_pkt)
            prog_v = pkt_prog_local;
            px = pkt_sx + (pkt_fx - pkt_sx) .* prog_v;
            py = pkt_sy + (pkt_fy - pkt_sy) .* prog_v;
            h.traffic_pkts.XData = px(valid_pkt);
            h.traffic_pkts.YData = py(valid_pkt);
            h.traffic_pkts.CData = pkt_col(valid_pkt, :);
        else
            h.traffic_pkts.XData = nan; h.traffic_pkts.YData = nan;
        end
        
        if n_atk > 0
            ax = atk_sx + (atk_fx - atk_sx) .* atk_prog_pulse;
            ay = atk_sy + (atk_fy - atk_sy) .* atk_prog_pulse;
            h.attack_pkts.XData = ax;
            h.attack_pkts.YData = ay;
        else
            h.attack_pkts.XData = nan; h.attack_pkts.YData = nan;
        end
        
        drawnow limitrate;  % efficient render — skips frames if GPU is busy
        pause(SUB_DT);
    end
    
    % Write back updated progress to persistent state
    pkt_prog(active_list) = pkt_prog_local;
    if n_atk > 0
        for k = 1:n_atk
            atk_prog(atk_list(k)) = atk_prog_pulse(2*k-1);
        end
    end
    
    % 5. Health Bars
    ward_names = fieldnames(config.WARDS);
    ward_h = H / 2; % since 2 rows
    for a = 1:6
        wname = ward_names{a};
        w_idx = find(strcmp(net.ward(1:ns), wname));
        act = sum(strcmp(net.status(w_idx), 'active'));
        ratio = act / max(1, length(w_idx));
        pos = h.health_bars(a).Position;
        h.health_bars(a).Position = [pos(1) pos(2) pos(3) max(0.1, (ward_h - 20)*ratio)];
        if ratio < 0.5
            h.health_bars(a).FaceColor = [1 0.2 0.2];
        elseif ratio < 0.8
            h.health_bars(a).FaceColor = [1 0.8 0.2];
        else
            h.health_bars(a).FaceColor = [0.2 1 0.5];
        end
    end
    
    % Info Text
    al_c = sum(alarm);
    d_c = sum(strcmp(net.status(1:ns), 'dead'));
    q_c = length(q_idx);
    t_str = sprintf('Tick: %d | Alarms: %d | Quarantined: %d | Dead: %d', t, al_c, q_c, d_c);
    if ~isempty(attack)
        t_str = sprintf('%s | Active Attack: %s', t_str, attack.type);
    end
    h.info_text.String = t_str;
    
    drawnow;
end

function cmap = custom_heat_cmap()
    % Black to Red colormap for heatmap
    n = 64;
    cmap = zeros(n, 3);
    cmap(:,1) = linspace(0, 1, n);
    cmap(:,2) = linspace(0, 0.2, n);
    cmap(:,3) = linspace(0, 0.2, n);
end

function txt = tooltip_callback(~, event_obj, fig)
    % Custom tooltip reading from figure appdata
    netData = getappdata(fig, 'netData');
    if isempty(netData), txt = 'No data'; return; end
    
    pos = get(event_obj, 'Position');
    net = netData.net;
    dists = (net.x - pos(1)).^2 + (net.y - pos(2)).^2;
    [~, idx] = min(dists);
    
    layers = {'Sensor', 'Fog', 'Gateway', 'Cloud'};
    lay = net.layer(idx);
    
    txt = {
        sprintf('Node ID: %d', idx-1), ...
        sprintf('Type: %s', net.device_type{idx}), ...
        sprintf('Layer: %s', layers{lay}), ...
        sprintf('Status: %s', net.status{idx})
    };
    
    if lay == 1
        txt{end+1} = sprintf('Ward: %s', net.ward{idx});
        txt{end+1} = sprintf('Anomaly Score: %.2f', netData.anomaly_score(idx));
        txt{end+1} = sprintf('Traffic: %d pkts/tick', netData.traffic(idx));
        if net.cluster_id(idx) > 0
            txt{end+1} = sprintf('Cluster: Fog-%d', net.cluster_id(idx));
        end
    elseif lay == 2
        f = idx - netData.config.N_SENSORS;
        txt{end+1} = sprintf('Fog Load: %.1f%%', net.fog_load(f)*100);
        txt{end+1} = sprintf('Queue: %d packets', net.fog_queue(f));
    end
end
