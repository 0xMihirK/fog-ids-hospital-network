/**
 * app.js — Socket.IO client, tab management, Chart.js dashboard,
 * event dispatch, and simulation controls.
 */

const socket = io({
    reconnection: true, reconnectionDelay: 1000, reconnectionAttempts: 10,
});

// -- Global State --
const AppState = {
    connected: false, simRunning: false, simTick: 0, maxIter: 500,
    topology: null, health: null, config: null, alerts: [], mode: 'python',
    chartData: {
        pktTotal: [], avgLatency: [], avgFogLoad: [], avgEnergy: [],
        nAlarms: [], survival: [], ticks: [],
    },
    stats: { tp:0, fp:0, fn:0, tn:0, attack_counts:{} },
};

const DOM = {
    connectionStatus: document.getElementById('connectionStatus'),
    simTick: document.getElementById('simTick'),
    simMaxTick: document.getElementById('simMaxTick'),
    nodeCount: document.getElementById('nodeCount'),
    alertCount: document.getElementById('alertCount'),
    eventFeed: document.getElementById('eventFeed'),
    btnPlay: document.getElementById('btnPlay'),
    btnPause: document.getElementById('btnPause'),
    btnReset: document.getElementById('btnReset'),
};

// ═══ Tab Navigation ═══
document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        const tabId = btn.dataset.tab;
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
        const panel = document.getElementById('panel' + tabId.charAt(0).toUpperCase() + tabId.slice(1));
        if (panel) panel.classList.add('active');
        window.dispatchEvent(new Event('resize'));
        if (tabId === 'topology') socket.emit('request_topology');
        if (tabId === 'health') socket.emit('request_health');
    });
});

// ═══ Connection Events ═══
socket.on('connect', () => {
    AppState.connected = true;
    DOM.connectionStatus.classList.add('connected');
    DOM.connectionStatus.classList.remove('error');
    DOM.connectionStatus.querySelector('.status-text').textContent = 'Connected';
    fetch('/api/config').then(r=>r.json()).then(cfg => {
        AppState.config = cfg;
        DOM.simMaxTick.textContent = cfg.max_iter;
        DOM.nodeCount.textContent = cfg.n_total;
    }).catch(()=>{});
});
socket.on('disconnect', () => {
    AppState.connected = false;
    DOM.connectionStatus.classList.remove('connected');
    DOM.connectionStatus.classList.add('error');
    DOM.connectionStatus.querySelector('.status-text').textContent = 'Disconnected';
});

// ═══ Data Events ═══
socket.on('topology_state', data => {
    AppState.topology = data;
    if (typeof TopologyRenderer !== 'undefined') TopologyRenderer.render(data);
    DOM.nodeCount.textContent = data.nodes ? data.nodes.length : '--';
    buildLegend(data);
});

socket.on('health_state', data => {
    AppState.health = data;
    updateHealthCards(data);
});

socket.on('sim_status', data => {
    AppState.simRunning = data.running;
    AppState.simTick = data.tick;
    AppState.maxIter = data.max_iter;
    AppState.mode = data.mode || 'python';
    DOM.simTick.textContent = data.tick;
    DOM.simMaxTick.textContent = data.max_iter;
    updateSimButtons(data.running);
    // Show mode indicator
    const modeText = data.mode === 'matlab' ? 'MATLAB' : 'Python';
    DOM.connectionStatus.querySelector('.status-text').textContent = 'Connected (' + modeText + ')';
});

socket.on('sim_tick', data => {
    AppState.simTick = data.tick;
    DOM.simTick.textContent = data.tick;

    if (data.health) updateHealthCards(data.health);

    // Process alerts
    if (data.alerts && data.alerts.length > 0) {
        data.alerts.forEach(a => addEventItem(a));
        DOM.alertCount.textContent = parseInt(DOM.alertCount.textContent || 0) + data.alerts.length;
    }

    // Update stats
    if (data.stats) {
        const s = data.stats;
        AppState.stats = s;
        const t = data.tick;
        const cd = AppState.chartData;
        cd.ticks.push(t);
        cd.pktTotal.push(s.pkt_total);
        cd.avgLatency.push(s.avg_latency);
        cd.avgFogLoad.push(s.avg_fog_load);
        cd.avgEnergy.push(s.avg_energy);
        cd.nAlarms.push(s.n_alarms);
        cd.survival.push(s.survival);

        // Keep rolling window of 200
        if (cd.ticks.length > 200) {
            cd.ticks.shift(); cd.pktTotal.shift(); cd.avgLatency.shift();
            cd.avgFogLoad.shift(); cd.avgEnergy.shift(); cd.nAlarms.shift();
            cd.survival.shift();
        }

        updateCharts();
        updateLiveStats(s);
    }

    // Suspicious nodes
    if (data.suspicious) updateSuspiciousTable(data.suspicious);

    // Traffic flow animation
    if (data.traffic_flows && typeof TopologyRenderer !== 'undefined') {
        TopologyRenderer.addTrafficFlows(data.traffic_flows);
    }

    // Node state updates for topology
    if (data.topology_update && typeof TopologyRenderer !== 'undefined') {
        TopologyRenderer.updateNodes(data.topology_update);
    }

    // Traffic logs
    if (data.traffic_logs) {
        updateTrafficLogs(data.traffic_logs);
    }
});

socket.on('sim_complete', data => {
    addEventItem({ type: 'alarm', time: AppState.simTick, msg: 'Simulation complete!' });
    if (data) updateLiveStats(data);
});

// ═══ Health Cards ═══
function updateHealthCards(h) {
    const el = id => document.getElementById(id);
    if (h.active_sensors !== undefined) el('healthActive').textContent = h.active_sensors;
    if (h.dead_sensors !== undefined) el('healthDead').textContent = h.dead_sensors;
    if (h.quarantined_sensors !== undefined) el('healthQuarantined').textContent = h.quarantined_sensors;
    if (h.survival_rate !== undefined) el('healthUptime').textContent = h.survival_rate.toFixed(1) + '%';
    if (h.avg_fog_load !== undefined) el('healthLatency').textContent = (h.avg_fog_load * 100).toFixed(1);
    if (h.total_sensors !== undefined) {
        const nodeCountEl = el('nodeCount');
        if (nodeCountEl) nodeCountEl.textContent = h.total_sensors + 120; // +100 fog, 15 GW, 5 Cloud
    }

    // Update Health Meter
    if (h.survival_rate !== undefined && h.avg_fog_load !== undefined) {
        // Simple formula: high survival rate is good, high fog load reduces health
        let healthScore = h.survival_rate - (h.avg_fog_load * 10);
        healthScore = Math.max(0, Math.min(100, healthScore));

        const meterValue = el('healthMeterValue');
        const meterBar = el('healthMeterBar');
        if (meterValue && meterBar) {
            meterValue.textContent = healthScore.toFixed(1) + '%';
            meterBar.style.width = healthScore + '%';

            let color = 'var(--gradient-green)';
            let textColor = 'var(--accent-green)';
            if (healthScore < 60) {
                color = 'var(--gradient-red)';
                textColor = 'var(--accent-red)';
            } else if (healthScore < 85) {
                color = 'linear-gradient(135deg, var(--accent-orange), #fcd34d)';
                textColor = 'var(--accent-orange)';
            }
            meterBar.style.background = color;
            meterValue.style.color = textColor;
        }
    }
}

// ═══ Event Feed ═══
function addEventItem(evt) {
    const feed = document.getElementById('eventFeed');
    if (!feed) return;
    if (feed.querySelector('.event-placeholder')) feed.innerHTML = '';
    const item = document.createElement('div');
    item.className = 'event-item';
    item.innerHTML = `<span class="event-time">T${evt.time||'--'}</span>
        <span class="event-badge ${evt.type||'alarm'}">${(evt.type||'INFO').toUpperCase()}</span>
        <span class="event-msg">${evt.msg||''}</span>`;
    feed.insertBefore(item, feed.firstChild);
    while (feed.children.length > 200) feed.removeChild(feed.lastChild);
    AppState.alerts.push(evt);
    
    // Add to logs table
    addLogEntry(evt);
}

// ═══ Logs Table ═══
function addLogEntry(evt) {
    const tbody = document.getElementById('logsBody');
    if (!tbody) return;
    if (tbody.querySelector('.empty-row')) tbody.innerHTML = '';
    
    const tr = document.createElement('tr');
    tr.className = `log-row log-${evt.type || 'info'}`;
    
    // Extract info if available, otherwise defaults
    const tick = evt.time || AppState.simTick || '--';
    const srcIp = evt.src_ip || '10.x.x.x';
    const srcId = evt.node_id ? `N-${evt.node_id}` : '--';
    const dest = evt.dest || 'Core Switch';
    const vlan = evt.vlan || '--';
    const type = (evt.type || 'INFO').toUpperCase();
    const result = evt.type === 'quarantine' ? '<span style="color:#ef4444">Blocked</span>' : '<span style="color:#f59e0b">Alert</span>';
    
    tr.innerHTML = `
        <td>${tick}</td>
        <td>${srcIp}</td>
        <td>${srcId}</td>
        <td>${dest}</td>
        <td>${vlan}</td>
        <td><span class="event-badge ${evt.type||'alarm'}">${type}</span></td>
        <td>${result}</td>
        <td style="max-width: 300px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title="${evt.msg||''}">${evt.msg||''}</td>
    `;
    
    tbody.insertBefore(tr, tbody.firstChild);
    while (tbody.children.length > 500) tbody.removeChild(tbody.lastChild);
}

// Log Filters
document.getElementById('logSearch')?.addEventListener('input', (e) => {
    filterLogs();
});
document.getElementById('logFilterType')?.addEventListener('change', filterLogs);
document.getElementById('btnClearLogs')?.addEventListener('click', () => {
    const tbody = document.getElementById('logsBody');
    if(tbody) tbody.innerHTML = '<tr><td colspan="8" class="empty-row">No traffic logs yet — start simulation to begin logging</td></tr>';
});

function filterLogs() {
    const term = (document.getElementById('logSearch')?.value || '').toLowerCase();
    const type = document.getElementById('logFilterType')?.value || 'all';
    
    document.querySelectorAll('#logsBody tr').forEach(tr => {
        if (tr.classList.contains('empty-row')) return;
        const matchTerm = tr.textContent.toLowerCase().includes(term);
        const matchType = type === 'all' || tr.classList.contains(`log-${type}`);
        tr.style.display = (matchTerm && matchType) ? '' : 'none';
    });
}

// ═══ Legend ═══
function buildLegend(topology) {
    const c = document.querySelector('.legend-items');
    if (!c || !topology.vlans) return;
    c.innerHTML = '';
    const entries = [
        {l:'Sensor (ICU)',c:'#ff4757'}, {l:'Sensor (General)',c:'#2ed573'},
        {l:'Sensor (Pharmacy)',c:'#ffa502'}, {l:'Sensor (Radiology)',c:'#3742fa'},
        {l:'Sensor (Facility)',c:'#a55eea'}, {l:'Sensor (Guest)',c:'#747d8c'},
        {l:'Fog Node',c:'#00d2d3'}, {l:'Gateway',c:'#feca57'},
        {l:'Cloud',c:'#ff6b6b'}, {l:'DMZ Service',c:'#e17055'},
        {l:'Normal Traffic',c:'#3b82f6'}, {l:'Attack Traffic',c:'#ef4444'},
        {l:'Quarantined',c:'#636e72'}, {l:'Firewall',c:'#dfe6e9'},
    ];
    entries.forEach(e => {
        const d = document.createElement('div');
        d.className = 'legend-item';
        d.innerHTML = `<span class="legend-dot" style="background:${e.c}"></span><span>${e.l}</span>`;
        c.appendChild(d);
    });
}

// ═══ Suspicious Nodes Table ═══
function updateSuspiciousTable(nodes) {
    const tbody = document.getElementById('suspiciousBody');
    if (!tbody) return;
    if (!nodes || nodes.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty-row">No suspicious nodes detected</td></tr>';
        return;
    }
    tbody.innerHTML = nodes.map(n => `<tr>
        <td>N-${n.id}</td><td>${n.device_type}</td><td>${n.ward}</td>
        <td style="color:${n.score>0.7?'#ef4444':'#f59e0b'}">${n.score.toFixed(2)}</td>
        <td>${n.status}</td>
        <td><button class="ctrl-btn" onclick="isolateNode(${n.id})" style="font-size:.7rem;padding:2px 8px">Isolate</button></td>
    </tr>`).join('');
}

function isolateNode(nodeId) {
    socket.emit('isolate_node', { node_id: nodeId });
    addEventItem({ type:'quarantine', time:AppState.simTick, msg:'Manual isolate: Node '+nodeId });
}

// ═══ Live Stats ═══
function updateLiveStats(s) {
    const el = id => document.getElementById(id);
    const tp=s.tp||0, fp=s.fp||0, fn=s.fn||0, tn=s.tn||0;
    const total = tp+fp+fn+tn;
    el('statAccuracy').textContent = total>0 ? ((tp+tn)/total*100).toFixed(1)+'%' : '--';
    el('statDetRate').textContent = (tp+fn)>0 ? (tp/(tp+fn)*100).toFixed(1)+'%' : '--';
    el('statPrecision').textContent = (tp+fp)>0 ? (tp/(tp+fp)*100).toFixed(1)+'%' : '--';
    el('statF1').textContent = (2*tp+fp+fn)>0 ? (2*tp/(2*tp+fp+fn)).toFixed(3) : '--';
    el('statFPR').textContent = (fp+tn)>0 ? (fp/(fp+tn)).toFixed(4) : '--';
    el('statTP').textContent = tp; el('statFP').textContent = fp;
    el('statFN').textContent = fn; el('statTN').textContent = tn;
}

// ═══ Chart.js Setup ═══
const chartOpts = {
    responsive: true, maintainAspectRatio: false, animation: false,
    scales: {
        x: { grid:{color:'rgba(255,255,255,.05)'}, ticks:{color:'#8b95a8',maxTicksLimit:8} },
        y: { grid:{color:'rgba(255,255,255,.05)'}, ticks:{color:'#8b95a8'} },
    },
    plugins: { legend:{display:false} },
};

const charts = {};

function initCharts() {
    const mk = (id, label, color) => {
        const el = document.getElementById(id);
        if (!el) return null;
        return new Chart(el, {
            type: 'line',
            data: { labels:[], datasets:[{ label, data:[], borderColor:color, backgroundColor:color+'22',
                borderWidth:1.5, pointRadius:0, fill:true, tension:0.3 }] },
            options: {...chartOpts},
        });
    };
    charts.pktRate = mk('pktRateChart', 'Packets/tick', '#3b82f6');
    charts.latency = mk('latencyChart', 'Avg Latency (ms)', '#06b6d4');
    charts.fogLoad = mk('fogLoadChart', 'Fog Load', '#feca57');
    charts.energy = mk('energyChart', 'Avg Energy (J)', '#10b981');
    charts.alarmHistory = mk('alarmHistoryChart', 'Alarms', '#ef4444');

    // Attack distribution bar chart
    const atEl = document.getElementById('attackDistChart');
    if (atEl) {
        charts.attackDist = new Chart(atEl, {
            type: 'bar',
            data: {
                labels: ['DDoS','MITM','Replay','Nmap','APT','Injection'],
                datasets: [{ data:[0,0,0,0,0,0],
                    backgroundColor: ['#ef4444','#f59e0b','#3b82f6','#8b5cf6','#06b6d4','#ec4899'],
                    borderWidth: 0, borderRadius: 4 }]
            },
            options: { ...chartOpts, indexAxis:'y',
                scales: {
                    x:{grid:{color:'rgba(255,255,255,.05)'},ticks:{color:'#8b95a8'}},
                    y:{grid:{display:false},ticks:{color:'#e8ecf4'}}
                }
            },
        });
    }
}

function updateCharts() {
    const cd = AppState.chartData;
    const labels = cd.ticks;
    if (charts.pktRate) { charts.pktRate.data.labels=labels; charts.pktRate.data.datasets[0].data=cd.pktTotal; charts.pktRate.update(); }
    if (charts.latency) { charts.latency.data.labels=labels; charts.latency.data.datasets[0].data=cd.avgLatency; charts.latency.update(); }
    if (charts.fogLoad) { charts.fogLoad.data.labels=labels; charts.fogLoad.data.datasets[0].data=cd.avgFogLoad; charts.fogLoad.update(); }
    if (charts.energy) { charts.energy.data.labels=labels; charts.energy.data.datasets[0].data=cd.avgEnergy; charts.energy.update(); }
    if (charts.alarmHistory) { charts.alarmHistory.data.labels=labels; charts.alarmHistory.data.datasets[0].data=cd.nAlarms; charts.alarmHistory.update(); }

    // Attack distribution
    if (charts.attackDist && AppState.stats.attack_counts) {
        const ac = AppState.stats.attack_counts;
        charts.attackDist.data.datasets[0].data = [
            ac.DDoS||0, ac.MITM||0, ac.Replay||0, ac.Nmap||0, ac.APT||0, ac.Injection||0
        ];
        charts.attackDist.update();
    }
}

// Init charts on load
setTimeout(initCharts, 200);

// ═══ Simulation Controls ═══
document.getElementById('btnPlay')?.addEventListener('click', () => {
    socket.emit('sim_start', { speed: 5 });
});
document.getElementById('btnPause')?.addEventListener('click', () => { socket.emit('sim_pause'); });
document.getElementById('btnReset')?.addEventListener('click', () => {
    socket.emit('sim_reset');
    DOM.simTick.textContent = '0'; DOM.alertCount.textContent = '0';
    DOM.eventFeed.innerHTML = '<div class="event-placeholder">Waiting for simulation data...</div>';
    AppState.alerts = [];
    AppState.chartData = { pktTotal:[], avgLatency:[], avgFogLoad:[], avgEnergy:[], nAlarms:[], survival:[], ticks:[] };
    AppState.stats = { tp:0, fp:0, fn:0, tn:0, attack_counts:{} };
    Object.values(charts).forEach(c => { if(c){ c.data.labels=[]; c.data.datasets[0].data=[]; c.update(); }});
});
// Speed event listeners removed

// Attack triggers
document.querySelectorAll('.attack-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        const t = btn.dataset.attack;
        socket.emit('trigger_attack', { type: t });
        addEventItem({ type:'alarm', time:AppState.simTick, msg:'Manual '+t+' attack triggered by operator' });

        // Pipeline animation
        animatePipeline(t);
    });
});

function animatePipeline(attackType) {
    const stages = ['stageIngest','stageExtract','stageNoise','stageClassify','stageAlert','stageIsolate'];
    stages.forEach((s,i) => {
        setTimeout(() => {
            const el = document.getElementById(s);
            if (el) { el.classList.add('active'); setTimeout(() => el.classList.remove('active'), 1500); }
        }, i * 400);
    });
}

function updateSimButtons(running) {
    const play = document.getElementById('btnPlay'), pause = document.getElementById('btnPause');
    if (play) play.disabled = running;
    if (pause) pause.disabled = !running;
}

// Log filtering
let allLogs = [];
function updateTrafficLogs(logs) {
    if (!logs || logs.length === 0) return;
    const tbody = document.getElementById('logsBody');
    if (!tbody) return;

    const empty = tbody.querySelector('.empty-row');
    if (empty) empty.remove();

    allLogs = [...logs, ...allLogs].slice(0, 1000);

    logs.forEach(log => {
        const tr = document.createElement('tr');
        tr.dataset.type = log.type;
        let resColor = log.result === 'ALLOW' ? '#2ed573' : (log.result === 'BLOCKED' ? '#ff6b6b' : '#ffa502');
        if (log.result === 'LOGGED') resColor = '#06b6d4';

        let srcIdStr = log.src;
        let srcIp = 'External';
        
        // If src is 'N-123', look up IP
        if (srcIdStr.startsWith('N-')) {
            const nodeId = parseInt(srcIdStr.substring(2));
            if (!isNaN(nodeId) && typeof TopologyRenderer !== 'undefined') {
                const topo = TopologyRenderer.getTopology();
                if (topo && topo.nodes && topo.nodes[nodeId]) {
                    srcIp = topo.nodes[nodeId].ip || 'N/A';
                }
            }
        } else if (srcIdStr === 'Ext-Attacker') {
            srcIp = '185.15.22.40'; // Fake external attacker IP
        }

        tr.innerHTML = `
            <td>${log.tick}</td>
            <td style="font-family: 'Consolas', monospace; color: var(--accent-blue);">${srcIp}</td>
            <td>${log.src}</td>
            <td>${log.dest}</td>
            <td><span class="vlan-badge">VLAN ${log.vlan}</span></td>
            <td><span class="type-badge ${log.type}">${log.type.toUpperCase()}</span></td>
            <td style="color:${resColor};font-weight:600">${log.result}</td>
            <td class="log-details">${log.details}</td>
        `;
        tbody.insertBefore(tr, tbody.firstChild);
    });

    while(tbody.children.length > 200) {
        tbody.removeChild(tbody.lastChild);
    }

    applyLogFilter();
}

function applyLogFilter() {
    const filter = document.getElementById('logFilterType')?.value || 'all';
    const search = document.getElementById('logSearch')?.value.toLowerCase() || '';

    document.querySelectorAll('#logsBody tr').forEach(tr => {
        if (tr.querySelector('.empty-row')) return;
        const typeMatch = filter === 'all' || tr.dataset.type === filter;
        const textMatch = tr.textContent.toLowerCase().includes(search);
        tr.style.display = (typeMatch && textMatch) ? '' : 'none';
    });
}

document.getElementById('logFilterType')?.addEventListener('change', applyLogFilter);
document.getElementById('logSearch')?.addEventListener('input', applyLogFilter);

document.getElementById('btnClearLogs')?.addEventListener('click', () => {
    document.getElementById('logsBody').innerHTML = '<tr><td colspan="7" class="empty-row">Logs cleared</td></tr>';
    allLogs = [];
});

document.getElementById('btnExportLogs')?.addEventListener('click', () => {
    if (allLogs.length === 0) return alert('No logs to export');
    const headers = ['Tick', 'Source', 'Dest', 'VLAN', 'Type', 'Result', 'Details'];
    const csvContent = [
        headers.join(','),
        ...allLogs.map(l => `${l.tick},${l.src},${l.dest},${l.vlan},${l.type},${l.result},"${l.details}"`)
    ].join('\n');
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = `fog_ids_logs_tick_${AppState.simTick}.csv`;
    link.click();
});

console.log('[APP] Hospital Fog IDS Dashboard initialized');

// -- Tab Navigation Logic --
const TAB_PANEL_MAP = {
    'health': 'panelHealth',
    'ids': 'panelIDS',
    'simulate': 'panelSimulate',
    'logs': 'panelLogs',
};
document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        // Remove active class from all buttons and panels
        document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
        document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
        
        // Add active class to clicked button and target panel
        btn.classList.add('active');
        const targetId = TAB_PANEL_MAP[btn.dataset.tab];
        const targetPanel = document.getElementById(targetId);
        if (targetPanel) {
            targetPanel.classList.add('active');
        }
    });
});
