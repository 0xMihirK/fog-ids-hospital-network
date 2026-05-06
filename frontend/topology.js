/**
 * topology.js — Canvas-based network topology renderer with live traffic
 * flow animation (normal packets = blue dots, attack packets = red pulses).
 */

const TopologyRenderer = (() => {
    const canvas = document.getElementById('topologyCanvas');
    if (!canvas) return {};
    const ctx = canvas.getContext('2d');

    let zoom = 1, panX = 60, panY = 20;
    let isDragging = false, dragStartX, dragStartY;
    let topology = null;
    let animFrame = null;
    let hoveredNode = null;
    let mouseX = 0, mouseY = 0;

    // Traffic flow particles
    let particles = [];
    const MAX_PARTICLES = 300;

    const ZONE_COLORS = {
        'ICU':         { bg: 'rgba(255,71,87,.06)',   border: '#ff4757' },
        'General Ward':{ bg: 'rgba(46,213,115,.06)',  border: '#2ed573' },
        'Pharmacy':    { bg: 'rgba(255,165,2,.06)',   border: '#ffa502' },
        'Radiology':   { bg: 'rgba(55,66,250,.06)',   border: '#3742fa' },
        'Facility':    { bg: 'rgba(165,94,234,.06)',  border: '#a55eea' },
        'Guest':       { bg: 'rgba(116,125,140,.06)', border: '#747d8c' },
        'DMZ':         { bg: 'rgba(225,112,85,.08)',  border: '#e17055' },
    };

    const VLAN_COLORS = {
        101:'#ff4757', 102:'#2ed573', 103:'#ffa502', 104:'#3742fa',
        105:'#a55eea', 106:'#747d8c', 200:'#00d2d3', 300:'#feca57',
        400:'#ff6b6b', 500:'#10ac84', 10:'#e17055', 999:'#636e72',
    };

    const LAYER_SHAPES = { 1:'circle', 2:'diamond', 3:'square', 4:'triangle', 5:'square' };
    const LAYER_SIZES  = { 1:3, 2:6, 3:8, 4:10, 5:14 };

    const ATTACK_COLORS = {
        'DDoS':'#ef4444', 'MITM':'#f59e0b', 'Replay':'#3b82f6',
        'Nmap':'#8b5cf6', 'APT':'#06b6d4', 'Injection':'#ec4899',
    };

    const DEVICE_ICONS = {
        'PatientMonitor': '❤️',
        'Ventilator': '🫁',
        'InfusionPump': '💊',
        'PACS': '🖥️',
        'NurseCall': '📡',
        'PharmDispenser': '💊',
        'HVAC': '❄️',
        'AccessControl': '🔐',
        'GuestDevice': '📱',
        'Datacenter': '🗄️',
        'Honeypot': '🍯'
    };

    // -- Resize --
    function resize() {
        const rect = canvas.parentElement.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        canvas.width = rect.width * dpr;
        canvas.height = rect.height * dpr;
        canvas.style.width = rect.width + 'px';
        canvas.style.height = rect.height + 'px';
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    window.addEventListener('resize', resize);
    setTimeout(resize, 100);

    // -- Pan & Zoom --
    canvas.addEventListener('mousedown', e => {
        isDragging = true; dragStartX = e.clientX - panX; dragStartY = e.clientY - panY;
    });
    canvas.addEventListener('mousemove', e => {
        const rect = canvas.getBoundingClientRect();
        mouseX = e.clientX - rect.left;
        mouseY = e.clientY - rect.top;

        if (isDragging) {
            panX = e.clientX - dragStartX; 
            panY = e.clientY - dragStartY;
            return;
        }

        // Check for hover
        hoveredNode = null;
        if (topology && topology.nodes) {
            for (let i = 0; i < topology.nodes.length; i++) {
                const n = topology.nodes[i];
                const nx = tx(n.x);
                const ny = ty(n.y);
                const dx = nx - mouseX;
                const dy = ny - mouseY;
                if (dx*dx + dy*dy < 100) { // roughly 10px radius
                    hoveredNode = n;
                    break;
                }
            }
        }
        canvas.style.cursor = hoveredNode ? 'pointer' : 'default';
    });
    canvas.addEventListener('mouseup', () => isDragging = false);
    canvas.addEventListener('mouseleave', () => isDragging = false);
    canvas.addEventListener('wheel', e => {
        e.preventDefault();
        zoom = Math.max(0.3, Math.min(5, zoom * (e.deltaY > 0 ? 0.9 : 1.1)));
    }, { passive: false });

    document.getElementById('btnZoomIn')?.addEventListener('click', () => { zoom = Math.min(5, zoom * 1.2); });
    document.getElementById('btnZoomOut')?.addEventListener('click', () => { zoom = Math.max(0.3, zoom * 0.8); });
    document.getElementById('btnZoomReset')?.addEventListener('click', () => { zoom = 1; panX = 60; panY = 20; });

    // -- Coordinate transforms --
    function tx(x) { return x * zoom + panX; }
    function ty(y) {
        const ch = canvas.height / (window.devicePixelRatio || 1);
        const fh = topology ? topology.floor.h : 400;
        const scale = (ch * 0.55) / fh;
        return ch * 0.75 - y * scale * zoom + panY;
    }
    function ts(s) { return s * zoom; }

    // -- Animation Loop --
    function animate() {
        if (!topology) { animFrame = requestAnimationFrame(animate); return; }
        const w = canvas.width / (window.devicePixelRatio || 1);
        const h = canvas.height / (window.devicePixelRatio || 1);

        ctx.clearRect(0, 0, w, h);
        drawZones(); drawRoutingLines(); drawFirewalls(w);
        drawDMZNodes(); drawNodes(); drawParticles(); drawLabels(w);

        animFrame = requestAnimationFrame(animate);
    }

    // -- Zone Backgrounds --
    function drawZones() {
        if (!topology?.clinical_areas) return;
        const floor = topology.floor;
        const areas = Object.keys(topology.clinical_areas);
        const cols = 3, rows = 2;
        const wardW = floor.w / cols, wardH = floor.h / rows;

        areas.forEach((name, i) => {
            const col = i % cols, row = Math.floor(i / cols);
            const zc = ZONE_COLORS[name] || { bg:'rgba(255,255,255,.03)', border:'#555' };
            ctx.fillStyle = zc.bg; ctx.strokeStyle = zc.border; ctx.lineWidth = 1;
            ctx.globalAlpha = 0.8;
            roundRect(tx(col*wardW), ty((row+1)*wardH), ts(wardW), ts(wardH), 6);
            ctx.globalAlpha = 0.7; ctx.fillStyle = zc.border;
            ctx.font = `${Math.max(9, 11*zoom)}px Inter, sans-serif`;
            ctx.textAlign = 'left';
            ctx.fillText(name, tx(col*wardW) + 6, ty((row+1)*wardH) + 14);
            ctx.globalAlpha = 1;
        });

        // DMZ zone
        const dmzY = topology.floor.h * 1.1;
        ctx.fillStyle = ZONE_COLORS['DMZ'].bg; ctx.strokeStyle = ZONE_COLORS['DMZ'].border;
        ctx.lineWidth = 1.5; ctx.setLineDash([6, 4]);
        roundRect(tx(0), ty(dmzY + 80), ts(topology.floor.w), ts(80), 8);
        ctx.setLineDash([]);
        ctx.fillStyle = ZONE_COLORS['DMZ'].border;
        ctx.font = `bold ${Math.max(10,12*zoom)}px Inter`;
        ctx.fillText('DMZ (VLAN 10)', tx(10), ty(dmzY + 75));

        // Datacenter Zone (above Quarantine on the right)
        const qx = topology.floor.w + 20;
        const qw = 120;
        const dc_y0 = topology.floor.h * 0.45;
        const dc_h = topology.floor.h * 0.45;
        
        ctx.fillStyle = 'rgba(16,172,132,.06)'; ctx.strokeStyle = '#10ac84';
        ctx.lineWidth = 1.5; ctx.setLineDash([8, 5]);
        roundRect(tx(qx), ty(dc_y0), ts(qw), ts(dc_h), 8);
        ctx.setLineDash([]);
        
        ctx.save();
        ctx.translate(tx(qx + qw/2), ty(dc_y0 + dc_h/2));
        ctx.rotate(Math.PI / 2);
        ctx.fillStyle = 'rgba(16,172,132,.3)';
        ctx.font = `bold ${Math.max(12,14*zoom)}px Inter`;
        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        ctx.fillText('LOCAL DATACENTER', 0, 0);
        ctx.restore();
    }

    function roundRect(x, y, w, h, r) {
        ctx.beginPath();
        ctx.moveTo(x+r,y); ctx.lineTo(x+w-r,y);
        ctx.quadraticCurveTo(x+w,y,x+w,y+r); ctx.lineTo(x+w,y+h-r);
        ctx.quadraticCurveTo(x+w,y+h,x+w-r,y+h); ctx.lineTo(x+r,y+h);
        ctx.quadraticCurveTo(x,y+h,x,y+h-r); ctx.lineTo(x,y+r);
        ctx.quadraticCurveTo(x,y,x+r,y);
        ctx.closePath(); ctx.fill(); ctx.stroke();
    }

    // -- Routing Lines --
    function drawRoutingLines() {
        if (!topology?.nodes) return;
        
        // Sensor -> Fog (Star Topology)
        ctx.globalAlpha = 0.04; ctx.strokeStyle = '#4b6584'; ctx.lineWidth = 0.5;
        ctx.beginPath();
        topology.nodes.forEach(n => {
            if (n.layer === 1 && n.cluster_id !== undefined) {
                // The cluster_id corresponds to the index of the fog node, but wait: cluster_id is 0-indexed in JS
                // Let's verify the ID matches. n.cluster_id is the exact node ID of the fog node if we map it?
                // Actually, MATLAB exports `cluster_id` as the 0-indexed index of the fog node within the FOG array, NOT the global nodes array!
                // Wait, let's look at MATLAB write_topology_json: `n.cluster_id = net.cluster_id(i) - 1`. 
                // net.cluster_id(i) goes from 1 to nf. So n.cluster_id is 0 to nf-1.
                // The fog nodes are located at indices `ns` to `ns + nf - 1`.
                // BUT `topology.nodes` might not have `ns` easily accessible. Let's find the first fog node index by finding the first layer === 2 node.
                const firstFogIdx = topology.nodes.findIndex(f => f.layer === 2);
                if (firstFogIdx !== -1) {
                    const fog = topology.nodes[firstFogIdx + n.cluster_id];
                    if (fog) {
                        ctx.moveTo(tx(n.x), ty(n.y));
                        ctx.lineTo(tx(fog.x), ty(fog.y));
                    }
                }
            }
        });
        ctx.stroke();

        if (!topology?.fog_links) return;
        ctx.globalAlpha = 0.08; ctx.strokeStyle = '#5a6478'; ctx.lineWidth = 0.5;
        topology.fog_links.forEach(l => {
            const a = topology.nodes[l.from], b = topology.nodes[l.to];
            if (!a || !b) return;
            ctx.beginPath(); ctx.moveTo(tx(a.x),ty(a.y)); ctx.lineTo(tx(b.x),ty(b.y)); ctx.stroke();
        });
        ctx.globalAlpha = 0.2; ctx.strokeStyle = '#ff6b6b'; ctx.lineWidth = 1;
        topology.gw_links?.forEach(l => {
            const a = topology.nodes[l.from], b = topology.nodes[l.to];
            if (!a || !b) return;
            ctx.beginPath(); ctx.moveTo(tx(a.x),ty(a.y)); ctx.lineTo(tx(b.x),ty(b.y)); ctx.stroke();
        });
        // Datacenter links (DC <-> Gateway)
        ctx.globalAlpha = 0.35; ctx.strokeStyle = '#10ac84'; ctx.lineWidth = 1.5;
        topology.dc_links?.forEach(l => {
            const a = topology.nodes[l.from], b = topology.nodes[l.to];
            if (!a || !b) return;
            ctx.beginPath(); ctx.moveTo(tx(a.x),ty(a.y)); ctx.lineTo(tx(b.x),ty(b.y)); ctx.stroke();
        });
        ctx.globalAlpha = 1;
    }

    // -- Firewalls --
    function drawFirewalls(w) {
        if (!topology?.firewalls) return;
        Object.values(topology.firewalls).forEach(fw => {
            const fx = tx(fw.x), fy = ty(fw.y);
            ctx.strokeStyle = '#dfe6e9'; ctx.lineWidth = 2;
            ctx.setLineDash([8,6]);
            ctx.beginPath(); ctx.moveTo(tx(0),fy); ctx.lineTo(tx(topology.floor.w),fy); ctx.stroke();
            ctx.setLineDash([]);
            ctx.fillStyle = '#dfe6e9';
            ctx.beginPath(); ctx.arc(fx,fy,ts(8),0,Math.PI*2); ctx.fill();
            ctx.fillStyle = '#0a0e17'; ctx.font = `bold ${Math.max(8,10*zoom)}px Inter`;
            ctx.textAlign = 'center'; ctx.fillText('FW', fx, fy+3.5);
            ctx.fillStyle = '#dfe6e9'; ctx.font = `${Math.max(8,9*zoom)}px Inter`;
            ctx.fillText(fw.label, fx, fy - ts(12));
        });
    }

    // -- DMZ Nodes --
    function drawDMZNodes() {
        if (!topology?.dmz_nodes) return;
        topology.dmz_nodes.forEach(n => {
            const nx=tx(n.x), ny=ty(n.y), r=ts(7);
            ctx.fillStyle='#e17055'; ctx.strokeStyle='#fab1a0'; ctx.lineWidth=1.5;
            ctx.beginPath(); ctx.arc(nx,ny,r,0,Math.PI*2); ctx.fill(); ctx.stroke();
            ctx.fillStyle='#fff'; ctx.font=`${Math.max(7,8*zoom)}px Inter`;
            ctx.textAlign='center'; ctx.fillText(n.type.split(' ')[0], nx, ny+r+12);
        });
    }

    // -- Network Nodes --
    function drawNodes() {
        if (!topology?.nodes) return;
        topology.nodes.forEach(node => {
            const nx=tx(node.x), ny=ty(node.y);
            let color = VLAN_COLORS[node.vlan] || '#8b95a8';
            if (node.device_type === 'Honeypot') color = '#e056fd'; // Honeypot override color

            const size = ts(LAYER_SIZES[node.layer] || 3);
            const shape = LAYER_SHAPES[node.layer] || 'circle';

            let alpha = 1, strokeColor = null, strokeW = 0;
            if (node.status === 'dead') { alpha = 0.2; }
            else if (node.status === 'quarantined') { alpha = 0.6; strokeColor = '#636e72'; strokeW = 2; }

            // Warning/sustained rings
            if (node.anomaly_score > 0.5 && node.status === 'active') {
                strokeColor = '#f59e0b'; strokeW = 2;
            }
            if (node.sustained) {
                strokeColor = '#ef4444'; strokeW = 2.5;
            }

            ctx.globalAlpha = alpha; ctx.fillStyle = color;
            
            if ((node.layer === 1 || node.device_type === 'Datacenter' || node.device_type === 'Honeypot') && node.device_type) {
                // Use Unicode icons for sensors, datacenter, and honeypots
                const icon = DEVICE_ICONS[node.device_type] || '📡';
                ctx.font = `${size*1.5}px Arial`;
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                // To keep the color tinting effect slightly, we can draw a faint colored background circle
                ctx.beginPath(); ctx.arc(nx,ny,size*0.8,0,Math.PI*2); 
                ctx.globalAlpha = alpha * 0.3; ctx.fill();
                ctx.globalAlpha = alpha;
                ctx.fillText(icon, nx, ny);
            } else {
                // Use shapes for Fog/Gateway/Cloud
                switch (shape) {
                    case 'circle':
                        ctx.beginPath(); ctx.arc(nx,ny,size,0,Math.PI*2); ctx.fill(); break;
                    case 'diamond':
                        ctx.beginPath(); ctx.moveTo(nx,ny-size); ctx.lineTo(nx+size,ny);
                        ctx.lineTo(nx,ny+size); ctx.lineTo(nx-size,ny); ctx.closePath(); ctx.fill(); break;
                    case 'square':
                        ctx.fillRect(nx-size,ny-size,size*2,size*2); break;
                    case 'triangle':
                        ctx.beginPath(); ctx.moveTo(nx,ny-size); ctx.lineTo(nx+size,ny+size);
                        ctx.lineTo(nx-size,ny+size); ctx.closePath(); ctx.fill(); break;
                }
            }
            
            if (strokeColor) {
                ctx.strokeStyle = strokeColor; ctx.lineWidth = strokeW;
                ctx.beginPath(); ctx.arc(nx,ny,size+3,0,Math.PI*2); ctx.stroke();
            }
            ctx.globalAlpha = 1;
        });
    }

    // -- Traffic Particles --
    function drawParticles() {
        const now = Date.now();
        particles = particles.filter(p => now - p.born < p.life);

        particles.forEach(p => {
            const t = (now - p.born) / p.life;  // 0->1 progress
            const x = p.sx + (p.ex - p.sx) * t;
            const y = p.sy + (p.ey - p.sy) * t;
            const alpha = t < 0.1 ? t*10 : t > 0.9 ? (1-t)*10 : 1;

            ctx.globalAlpha = alpha * 0.8;
            ctx.fillStyle = p.color;
            ctx.beginPath();
            ctx.arc(x, y, p.size, 0, Math.PI * 2);
            ctx.fill();

            // Glow effect for attack particles
            if (p.isAttack) {
                ctx.globalAlpha = alpha * 0.3;
                ctx.beginPath();
                ctx.arc(x, y, p.size * 3, 0, Math.PI * 2);
                ctx.fill();
            }
            ctx.globalAlpha = 1;
        });
    }

    // -- Labels & Tooltips --
    function drawLabels(w) {
        ctx.fillStyle = '#e8ecf4'; ctx.font = `bold ${Math.max(12,14*zoom)}px Inter`;
        ctx.textAlign = 'center';
        ctx.fillText('Hospital Fog Network -- VLAN-Segmented DMZ Architecture', w/2, 24);
        ctx.fillStyle = '#636e72'; ctx.font = `${Math.max(10,11*zoom)}px Inter`;
        if (topology) ctx.fillText('INTERNET', tx(topology.floor.w/2), ty(topology.floor.h*1.35));

        // Draw Tooltip
        if (hoveredNode) {
            const hx = mouseX + 15;
            const hy = mouseY + 15;
            
            // Tooltip background
            ctx.fillStyle = 'rgba(10, 15, 30, 0.9)';
            ctx.strokeStyle = '#4b6584';
            ctx.lineWidth = 1;
            
            const tooltipText = [
                `ID: N-${hoveredNode.id}`,
                `IP: ${hoveredNode.ip || 'N/A'}`,
                `Type: ${hoveredNode.device_type}`,
                `Status: ${hoveredNode.status.toUpperCase()}`,
                `VLAN: ${hoveredNode.vlan}`
            ];
            
            ctx.font = '12px "Consolas", monospace';
            ctx.textAlign = 'left';
            ctx.textBaseline = 'top';
            
            const maxW = Math.max(...tooltipText.map(t => ctx.measureText(t).width)) + 20;
            const th = tooltipText.length * 16 + 10;
            
            roundRect(hx, hy, maxW, th, 4);
            
            ctx.fillStyle = '#d1d8e0';
            tooltipText.forEach((t, i) => {
                if (t.includes('Warning') || t.includes('QUARANTINE')) ctx.fillStyle = '#eb3b5a';
                ctx.fillText(t, hx + 10, hy + 8 + i * 16);
            });
        }
    }

    // -- Spawn traffic particles from flow data --
    function spawnTrafficParticles(flows) {
        if (!topology?.nodes || !flows) return;
        const now = Date.now();

        flows.forEach(flow => {
            if (particles.length >= MAX_PARTICLES) return;
            const src = topology.nodes[flow.src];
            const fog = topology.nodes[flow.fog];
            if (!src || !fog) return;

            const isAtk = flow.is_attack;
            const color = isAtk ? (ATTACK_COLORS[flow.attack_type] || '#ef4444') : '#3b82f6';
            const size = isAtk ? ts(3) : ts(1.5);
            const life = isAtk ? 1200 : 800;

            // Spawn 1-3 particles per flow
            const count = isAtk ? 3 : 1;
            for (let i = 0; i < count; i++) {
                particles.push({
                    sx: tx(src.x), sy: ty(src.y),
                    ex: tx(fog.x), ey: ty(fog.y),
                    color, size, isAttack: isAtk,
                    born: now + i * 100, life: life + Math.random() * 400,
                });
            }
        });
    }

    // -- Generate ambient normal traffic particles --
    function spawnAmbientTraffic() {
        if (!topology?.nodes || particles.length >= MAX_PARTICLES * 0.5) return;
        const now = Date.now();
        const ns = topology.nodes.filter(n => n.layer === 1 && n.status === 'active');
        const fogs = topology.nodes.filter(n => n.layer === 2);
        if (ns.length === 0 || fogs.length === 0) return;

        // Spawn a few random normal traffic particles
        for (let i = 0; i < 5; i++) {
            const s = ns[Math.floor(Math.random() * ns.length)];
            const f = fogs[Math.floor(Math.random() * fogs.length)];
            particles.push({
                sx: tx(s.x), sy: ty(s.y),
                ex: tx(f.x), ey: ty(f.y),
                color: '#3b82f6', size: ts(1.2), isAttack: false,
                born: now + Math.random() * 500, life: 1000 + Math.random() * 500,
            });
        }
    }

    // Start ambient traffic every 600ms
    setInterval(() => { if (topology) spawnAmbientTraffic(); }, 600);

    // Start animation loop
    animate();

    // -- Public API --
    return {
        render(data) { topology = data; resize(); },
        updateNodes(updates) {
            if (!topology?.nodes || !updates) return;
            updates.forEach(u => {
                if (topology.nodes[u.id]) Object.assign(topology.nodes[u.id], u);
            });
        },
        addTrafficFlows(flows) { spawnTrafficParticles(flows); },
        getTopology() { return topology; },
    };
})();
