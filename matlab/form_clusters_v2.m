function net = form_clusters_v2(net, config)
% FORM_CLUSTERS_V2 - Fixed-head clustering for VLAN-segmented network.
% All fog nodes act as permanent cluster heads so sensors always orbit
% their nearest fog node — LEACH randomness is kept for load-balancing
% statistics but does NOT affect topology layout.

    ns = config.N_SENSORS;
    nf = config.N_FOG;

    % All fog nodes are cluster heads (ensures sensors stay near their fog node)
    is_ch = true(nf, 1);
    ch_indices = 1:nf;
    ch_x = net.x(ns + ch_indices);
    ch_y = net.y(ns + ch_indices);

    net.cluster_id  = zeros(ns, 1);
    net.dist_to_fog = zeros(ns, 1);
    net.is_ch       = is_ch;

    for i = 1:ns
        if ~strcmp(net.status{i}, 'active')
            continue;
        end
        dists = sqrt((ch_x - net.x(i)).^2 + (ch_y - net.y(i)).^2);
        [min_d, nearest] = min(dists);
        net.cluster_id(i)  = ch_indices(nearest);
        net.dist_to_fog(i) = min_d;
    end

    % Build reverse mapping
    net.fog_members = cell(nf, 1);
    net.cluster_sizes = zeros(nf, 1);
    for i = 1:ns
        if strcmp(net.status{i}, 'active') && net.cluster_id(i) > 0
            f = net.cluster_id(i);
            net.fog_members{f}(end+1) = i;
        end
    end
    for f = 1:nf
        net.cluster_sizes(f) = length(net.fog_members{f});
    end
end
