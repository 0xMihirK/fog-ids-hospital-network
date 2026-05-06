"""
app.py -- Flask + SocketIO server for the Hospital Fog Network IDS.
Serves the frontend, runs Python simulation, and watches MATLAB output
for real-time MATLAB->Python->JS data pipeline.
"""

import os
import json
import time
import glob
import threading

from flask import Flask, send_from_directory, jsonify
from flask_socketio import SocketIO, emit
from flask_cors import CORS

from backend.config import Config
from backend.network import HospitalNetwork
from backend.sim_engine import SimulationEngine

# -- Flask App Setup --
app = Flask(
    __name__,
    static_folder=os.path.join(os.path.dirname(__file__), '..', 'frontend'),
    template_folder=os.path.join(os.path.dirname(__file__), '..', 'frontend'),
)
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

# -- Global State --
network = None
sim_engine = None
matlab_watcher = None


def init_network():
    """Initialize the hospital network."""
    global network, sim_engine
    print("[INIT] Building 800-node hospital network...")
    network = HospitalNetwork()
    sim_engine = SimulationEngine(socketio, network)
    print("[INIT] Network ready: %d sensors, %d fog, %d gateways, %d cloud" % (
        Config.N_SENSORS, Config.N_FOG, Config.N_GATEWAYS, Config.N_CLOUD))
    print("[INIT] VLANs: %d configured" % len(Config.VLANS))
    print("[INIT] Clinical areas: %s" % ', '.join(Config.CLINICAL_AREAS.keys()))
    return network





# -- Routes --

@app.route('/')
def index():
    return send_from_directory(app.static_folder, 'index.html')


@app.route('/<path:filename>')
def static_files(filename):
    return send_from_directory(app.static_folder, filename)


@app.route('/api/config')
def get_config():
    return jsonify({
        'n_sensors': Config.N_SENSORS,
        'n_fog': Config.N_FOG,
        'n_gateways': Config.N_GATEWAYS,
        'n_cloud': Config.N_CLOUD,
        'n_total': Config.N_TOTAL,
        'floor_w': Config.FLOOR_W,
        'floor_h': Config.FLOOR_H,
        'max_iter': Config.MAX_ITER,
        'attack_types': Config.ATTACK_TYPES,
        'vlans': {str(k): v for k, v in Config.VLANS.items()},
        'clinical_areas': Config.CLINICAL_AREAS,
    })


@app.route('/api/topology')
def get_topology():
    if network is None:
        return jsonify({'error': 'Network not initialized'}), 500
    return jsonify(network.to_topology_state())


@app.route('/api/health')
def get_health():
    if network is None:
        return jsonify({'error': 'Network not initialized'}), 500
    return jsonify(network.to_health_state())


# -- WebSocket Events --

@socketio.on('connect')
def handle_connect():
    print("[WS] Client connected")
    if network is not None:
        emit('topology_state', network.to_topology_state())
        emit('health_state', network.to_health_state())
        emit('sim_status', {
            'running': sim_engine.running if sim_engine else False,
            'tick': sim_engine.tick if sim_engine else 0,
            'max_iter': Config.MAX_ITER,
            'mode': sim_engine.mode if sim_engine else 'python',
        })
        
        # Send the latest tick data if in MATLAB mode so the dashboard isn't blank
        if sim_engine and sim_engine.mode == 'matlab' and sim_engine.tick > 0:
            tick_path = os.path.join(os.path.dirname(__file__), '..', 'sim_output', f'tick_{sim_engine.tick:04d}.json')
            if os.path.exists(tick_path):
                try:
                    with open(tick_path, 'r') as f:
                        emit('sim_tick', json.load(f))
                except Exception:
                    pass


@socketio.on('disconnect')
def handle_disconnect():
    print("[WS] Client disconnected")


@socketio.on('request_topology')
def handle_request_topology():
    if network is not None:
        emit('topology_state', network.to_topology_state())


@socketio.on('request_health')
def handle_request_health():
    if network is not None:
        emit('health_state', network.to_health_state())


@socketio.on('sim_start')
def handle_sim_start(data):
    if sim_engine:
        speed = data.get('speed', 5) if data else 5
        sim_engine.start(speed)
        print("[SIM] Started (speed=%dx)" % speed)


@socketio.on('sim_pause')
def handle_sim_pause():
    if sim_engine:
        sim_engine.pause()
        print("[SIM] Paused")


@socketio.on('sim_resume')
def handle_sim_resume():
    if sim_engine:
        sim_engine.resume()


@socketio.on('sim_reset')
def handle_sim_reset():
    global network, sim_engine
    if sim_engine:
        sim_engine.reset()
    print("[SIM] Reset")


@socketio.on('sim_speed')
def handle_sim_speed(data):
    if sim_engine and data:
        sim_engine.set_speed(data.get('speed', 5))


@socketio.on('trigger_attack')
def handle_trigger_attack(data):
    if sim_engine and data:
        attack_type = data.get('type', 'DDoS')
        sim_engine.trigger_attack(attack_type)
        print("[SIM] Manual attack triggered: %s" % attack_type)

    # For MATLAB mode, we write the trigger directly to sim_output
    if (sim_engine and sim_engine.mode == 'matlab') or not sim_engine:
        attack_type = data.get('type', 'DDoS') if data else 'DDoS'
        trigger_path = os.path.join(os.path.dirname(__file__), '..', 'sim_output', 'attack_trigger.json')
        try:
            with open(trigger_path, 'w') as f:
                json.dump({'type': attack_type}, f)
        except Exception:
            pass


@socketio.on('isolate_node')
def handle_isolate_node(data):
    if data:
        node_id = data.get('node_id')
        trigger_path = os.path.join(os.path.dirname(__file__), '..', 'sim_output', 'isolate_trigger.json')
        try:
            with open(trigger_path, 'w') as f:
                json.dump({'node_id': node_id}, f)
            print(f"[SIM] Manual isolate trigger written for node {node_id}")
        except Exception as e:
            print(f"Error writing isolate trigger: {e}")


# -- Entry Point --

def main():
    print("=" * 62)
    print("   Hospital Fog IDS -- Web Dashboard")
    print("   MATLAB Simulation + Python Bridge + JS Frontend")
    print("=" * 62)
    print()

    init_network()

    print()
    print("[SERVER] Starting on http://localhost:5000")
    print("[SERVER] Modes:")
    print("   - MATLAB: Run run_simulation_v2.m in MATLAB (auto-detected)")
    print("   - Python: Click 'Start' in browser for Python fallback sim")
    print()
    
    # Auto-start simulation immediately upon backend launch
    sim_engine.start(5)

    socketio.run(app, host='0.0.0.0', port=5000, debug=False, allow_unsafe_werkzeug=True)


if __name__ == '__main__':
    main()
