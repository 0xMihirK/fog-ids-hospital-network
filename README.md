# Hospital Fog Intrusion Detection System (IDS)

A comprehensive real-time network simulation and machine learning-based Intrusion Detection System for a 800-node hospital fog network. This system is designed to simulate complex medical device interactions, VLAN segmentation, and cyber-attacks, paired with a web-based monitoring dashboard.

## Features

* **800-Node Simulated Environment**: Accurate representation of a modern hospital network, segmented into functional areas (ICU, General Ward, Pharmacy, Radiology, Facility, Guest).
* **VLAN & ACL Enforcement**: Strict VLAN-based network isolation mapping (VLANs 10, 101-106, 200, 300, 400, 999).
* **7-Module Ensemble IDS**:
    1. Rate Anomaly (Volumetric Floods)
    2. Latency Anomaly (Routing / Delay attacks)
    3. CUSUM Change-Point Detection
    4. Payload Entropy Analysis
    5. Port Scan Heuristics
    6. DNS Tunneling Detection (APT)
    7. Vital Signs Data Integrity
* **Attack Simulation**: Automated persistent and manual triggers for DDoS, MITM, Replay, Nmap, APT, and Injection.
* **Honeypot & Isolation**: Decoy nodes on the DMZ/LAN and dynamic ACL quarantine assignments (VLAN 999).
* **Real-Time Visualization**: A modern dark-themed web dashboard with Chart.js analytics and event streams.

## Architecture

The project employs a dual-stack architecture:
1. **Simulation Engine (MATLAB)**: Handles the high-performance math for node clustering (LEACH), energy tracking, traffic generation, and IDS scoring.
2. **Web Dashboard (Python/Flask + JS)**: Provides a WebSocket-driven live UI to monitor health, manage simulated attacks, view traffic logs, and perform manual isolation.

The two systems communicate in real-time via a fast file-system bridge (`/sim_output`), polling tick states at 50ms intervals.

## Getting Started

### Prerequisites
* **MATLAB** (R2021a or newer recommended)
* **Python 3.8+**

### Setup Environment
```powershell
# Create virtual environment
python -m venv venv
.\venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

### Running the System
The system is designed to run the dashboard and the simulation concurrently.

**1. Start the Web Dashboard**
```powershell
.\venv\Scripts\activate
python -m backend.app
```
*Open http://localhost:5000 in your browser.*

**2. Start the MATLAB Simulation**
Open MATLAB, navigate to the `matlab/` directory, and run the main entry point:
```matlab
run_simulation_v2
```

The web dashboard will automatically detect the MATLAB simulation and begin streaming the live health and attack metrics. You can trigger attacks manually from the UI or watch the automated attacks unfold.

## License
MIT License
