# Fog IDS Hospital Network Simulation

<div align="center">
  <img src="docs/dashboard.png" alt="Hospital Fog IDS Dashboard - Health Monitor">
  <br>
  <em>Real-time network monitoring and analysis dashboard</em>
</div>

This project implements a highly realistic, large-scale simulation of an Internet of Medical Things (IoMT) hospital network, paired with a custom machine learning-based Intrusion Detection System (IDS) deployed at the "Fog" computing layer.

Instead of focusing purely on the backend mechanics, this simulation aims to provide an accurate representation of a critical-infrastructure environment, showcasing how modern hospitals can maintain high availability and life-saving operations even while under active cyberattack.

## 🏥 Simulating a Real-World Hospital Scale

The network is modeled on a 5-acre (200,000 square feet or 500m x 400m) hospital floor plan, bringing true spatial realism to the network behavior.

<div align="center">
  <img src="docs/sim.png" alt="Network Topology Simulation">
  <br>
  <em>1,481-node network topology visualization mapped across 6 clinical zones</em>
</div>

* **Massive Scale**: The environment consists of 1,481 distinct network nodes (1,360 IoMT sensors, 100 Fog clusters, 15 Gateways, and Cloud infrastructure).
* **Segmented Clinical Zones**: The simulation accurately models functional isolation. Devices are split across 6 distinct clinical zones, each behaving differently:
  * **Intensive Care Unit (ICU)**: 240 nodes (Continuous high-frequency monitoring)
  * **General Wards**: 480 nodes (Periodic vital sign checking)
  * **Radiology**: 120 nodes (High bandwidth, bursty traffic)
  * **Pharmacy**: 120 nodes
  * **Facilities (HVAC/Power)**: 240 nodes
  * **Guest/Public Wi-Fi**: 160 nodes (Low trust zone)
* **Distance-Based Latency**: Because node placement is physically modeled on the 5-acre grid, signal latency and packet drop rates are calculated using actual distance equations from the sensors to their assigned Fog processing nodes.

## 🛡️ Critical Infrastructure & High Uptime Design

Hospitals cannot simply "shut down" when compromised. The network architecture in this simulation is built around resilience.

* **Hierarchical Routing (Sensor → Fog → Gateway → Cloud)**: By pushing processing to the Fog layer (local cluster heads), the network prevents the central cloud from becoming a single point of failure or an easy DDoS target.
* **VLAN Strictness**: The network heavily utilizes VLAN segmentation (VLANs 101-106 for clinical zones). If a device in the Guest network is compromised by ransomware, the VLAN ACLs physically prevent lateral movement into the ICU's ventilator network.
* **Decoy Infrastructure (Honeypots)**: Fake medical devices (e.g., simulated unpatched infusion pumps) are placed in the DMZ. Since no legitimate traffic should ever touch these honeypots, any interaction instantly flags the source as a malicious actor performing reconnaissance (like Nmap scanning).

## 🚨 Attack Detection & Isolation

The simulation continuously monitors the health of the environment. Attacks are caught by a **7-Module Ensemble IDS** running at the Fog layer.

<div align="center">
  <img src="docs/dashboard1.png" alt="Attack Distribution and Alerts">
  <br>
  <em>Live event feed and attack distribution monitoring</em>
</div>

1. **Statistical Baselines**: The IDS learns what "normal" looks like for every single device. It tracks Exponentially Weighted Moving Averages (EWMA) of packet rates and latencies.
2. **Multi-Vector Detection**: The system doesn't rely on one method. It uses:
   * Volumetric rate checking (for DDoS)
   * Latency anomaly detection (for Man-in-the-Middle delays)
   * Payload Entropy (to catch data encryption/injection)
   * Biological Sanity Checks (If a ventilator suddenly reports a heart rate of 500 BPM, the IDS flags it as data injection, not a medical emergency).
3. **Dynamic Isolation (VLAN 999)**: When an attack is confirmed, the node is not simply turned off—which could be dangerous in a hospital. Instead, the simulation dynamically rewrites the network rules, dropping the compromised node into a Quarantine Zone (VLAN 999). This cuts off its ability to transmit to the outside world or infect other devices, while still keeping the device powered on.

<div align="center">
  <img src="docs/matrix.png" alt="IDS Confusion Matrix">
  <br>
  <em>Live statistical performance tracking and detection accuracy</em>
</div>

---
*Developed by Mihir Katoch as part of the Fog-Project research initiative.*
