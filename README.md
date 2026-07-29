🌍 English | 🇮🇷 [نسخه فارسی](README_FA.md)

# 🐂 Ox Tunnle

High-Performance Asynchronous Reverse TCP Tunnel Manager  
Multi-Slot • AutoSync • HMAC Security • Systemd Ready • BBR & AsyncIO Powered

**Telegram:** [t.me/WexortYT](https://t.me/WexortYT)

---

<p align="center">
  <b>Lightweight • Secure • Production Ready</b>
</p>

---

# 📌 Overview

Ox Tunnle is a state-of-the-art reverse TCP tunneling system designed to reliably bridge two servers:

- 🇮🇷 IR (Iran Server / Bridge Ingress)
- 🌍 EU (Outside Server / Target Gateway)

Built on an ultra-fast **AsyncIO** core engine (with optional `uvloop` acceleration), it eliminates CPU thread overhead and reduces memory usage to under 50MB even under high concurrent loads. It features integrated **HMAC-SHA256 Challenge-Response** authentication to defend against scanners, replay attacks, and unauthorized connections.

---

# 🧠 Architecture

```
Client → IR Server (0.0.0.0:Port) ⇄ [HMAC-Protected Tunnel] ⇄ EU Server → Local Target (127.0.0.1:Port)
                                  │
                          Bridge Port (Main TCP Stream)
                                  │
                           Sync Port (AutoSync API)
```

### 🔹 Bridge Port
Main persistent TCP tunnel connection between IR and EU. Protected by challenge-response HMAC authentication.

### 🔹 Sync Port
Low-latency channel used for real-time automatic port listening synchronization from EU to IR.

---

# 🛠 Features

| Feature | Description |
| :--- | :--- |
| **AsyncIO Engine** | Event-driven high-speed engine with near-zero thread overhead & `uvloop` acceleration |
| **HMAC-SHA256 Security** | Challenge-response protocol preventing replay attacks, probes, and unauthorized access |
| **Reverse TCP Tunnel** | Persistent bi-directional data stream between IR ⇄ EU |
| **Multi-Slot (1–10)** | Maintain up to 10 isolated tunnel profiles (`eu1`, `ir1`, etc.) |
| **AutoSync** | Automatically detects open listening ports on EU and mirrors them on IR |
| **Native Systemd Integration** | Runs as dedicated Linux service instances (`ox-tunnle@<profile>.service`) with auto-reboot recovery |
| **Cron Health Check** | Automated watchdog ensuring continuous operation and auto-restart |
| **BBR Optimization** | Linux kernel TCP congestion control & sysctl performance tuning |
| **Graceful Shutdown** | Safe termination on SIGTERM/SIGINT with port and socket pruning |
| **Live Logging** | Standard system journal logs (`journalctl`) and safe file-based logs |

---

# 📦 Installation Guide

---

# 🟢 Step 1 — Setup IR Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/install.sh)
```

After installation, launch the Tunnel Manager:

```bash
sudo ox-tunnle
```

### 1️⃣ Complete Setup & Dependencies

Select from menu:
```
5) Install / Complete Setup
```
This automatically installs required dependencies and registers the native systemd template service.

---

### 2️⃣ Create Tunnel Profile

```
1) Create/Update profile
2) IRAN Server
```

- **Select Slot (1–10):** Choose an identifier (e.g., Slot 1 corresponds to `ir1`).
- **Enter Bridge Port:** Default is `7000` (must match on both servers).
- **Enter Sync Port:** Default is `7001` (must match on both servers and be distinct from Bridge Port).
- **AutoSync Mode:** Enable (`y`) to automatically detect and open ports, or disable (`n`) to manually provide a comma-separated list of ports.
- **Security Token (HMAC):** Enter a strong custom secret token or press Enter to auto-generate a 32-character hex key. *Save this key to enter on the EU server!*

---

# 🔵 Step 2 — Setup EU Server

Repeat the installation command on your outside (EU) server:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/install.sh)
```

Launch manager and setup profile:
```bash
sudo ox-tunnle
```
Select:
```
5) Install / Complete Setup
1) Create/Update profile
2) EU Server
```
- Choose the same slot number (e.g., `eu1`).
- Enter your **IR Server IP Address**.
- Enter the identical **Bridge Port** and **Sync Port**.
- Enter the exact same **Security Token** generated on the IR server.

---

# ▶️ Service Management

You can control active slots directly from the interactive menu or using standard systemd commands:

## Via Menu:
```
2) Manage tunnel (select slot)
→ Select IRAN or EU
→ Select Slot Number
→ 2) Start / Restart
→ 5) Status / Live Logs
```

## Via Native Systemd CLI:
```bash
# Start a specific slot (e.g., EU Slot 1 or IR Slot 1)
systemctl start ox-tunnle@eu1
systemctl start ox-tunnle@ir1

# Check real-time service status
systemctl status ox-tunnle@eu1

# Stop a tunnel instance
systemctl stop ox-tunnle@eu1

# View live stream of execution logs
journalctl -u ox-tunnle@eu1 -f
```

---

# 🔐 Security & Architecture Hardening

Ox Tunnle enforces modern security and stability practices:
- **Challenge-Response Auth:** Unlike static hashes, every connection performs a dynamic 16-byte nonce challenge verified via HMAC-SHA256, nullifying packet replay attempts.
- **Anti-Probing & Scanner Drop:** Unauthenticated attempts on Bridge or Sync ports are dropped immediately within 3 seconds without leaking handshake banners.
- **Resource Protection:** Dynamic pool allocation scales with system RAM and file descriptor limits, preventing connection starvation and memory overflow.

---

# ⚡ Advanced CLI & Environment Tuning

The core engine (`ox-tunnle.py`) supports full command-line arguments and environment variables:

```bash
# Manual command-line execution
python3 /usr/local/bin/ox-tunnle.py --role ir --bridge-port 7000 --sync-port 7001 --secret YOUR_SECRET_KEY

# Environmental performance overrides
export OXTUNNEL_POOL=256      # Override automatic worker pool size
export OXTUNNEL_LOG=/var/log/ox-tunnle/engine.log  # Enable rotating log file output
```

---

# 🛠 Troubleshooting & Diagnostics

- **Verify Active Ports:** Check if bridge and sync ports are listening on IR:
  ```bash
  ss -lntp | grep python3
  ```
- **Test EU ⇄ IR Connectivity:** Verify port reachability from EU:
  ```bash
  nc -zv IR_SERVER_IP 7000
  nc -zv IR_SERVER_IP 7001
  ```
- **Inspect Detailed Logs:**
  ```bash
  journalctl -u ox-tunnle@ir1.service -n 50 --no-pager
  ```

---

# 📁 Project Structure

```
ox-tunnle.sh   → Comprehensive Shell Manager & Interface
ox-tunnle.py   → AsyncIO Core Tunnel & HMAC Authentication Engine
install.sh     → Automated One-Line Deployment Script
```

---

# ❤️ Maintained by Ox Tunnle
