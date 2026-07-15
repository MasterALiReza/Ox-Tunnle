🌍 English | 🇮🇷 [نسخه فارسی](README_FA.md)

# 🐂 Ox Tunnle

High-Performance Reverse TCP Tunnel Manager  
Multi-Slot • AutoSync • Health Check • BBR Optimization • Live Logs

**Telegram:** [t.me/WexortYT](https://t.me/WexortYT)


---

<p align="center">
  <b>Lightweight • Stable • Production Ready</b>
</p>

---

# 📌 Overview

Ox Tunnle is a reverse TCP tunneling system designed to connect two servers:

- 🇮🇷 IR (Iran Server)
- 🌍 EU (Outside Server)

It supports multi-slot configuration, automatic port synchronization, system optimization, and multiple port-forwarding methods.

---

# 🧠 Architecture

```
Client → IR Server ⇄ EU Server
             │
        Bridge Port (Main Tunnel)
             │
         Sync Port (AutoSync)
```

### 🔹 Bridge Port
Main persistent TCP tunnel connection between IR and EU.

### 🔹 Sync Port
Used for automatic port synchronization between servers.

---

# 🛠 Features

| Feature | Description |
|----------|------------|
| Reverse TCP Tunnel | Persistent IR ⇄ EU connection |
| Multi-Slot (1–10) | Store up to 10 independent tunnel configs |
| AutoSync | Automatic port creation & synchronization |
| Cron Health Check | Automatic restart if tunnel stops |
| BBR Optimization | Network performance tuning |
| Multi Port Forward | iptables, nftables, HAProxy, socat |
| systemd Integration | Auto-start on reboot |
| Performance Tuning | ENV-based tuning |
| Thread Control | Worker pool limitation |
| Graceful Shutdown | Clean SIGTERM/SIGINT handling |
| File-Based Logging | Live log via `tail -f` — safe, no crash on exit |

---

# 📦 Installation Guide

---

# 🟢 Step 1 — Setup IR Server

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/install.sh)
```

After installation, open the Tunnel Manager:

```bash
sudo ox-tunnle
```

### 1️⃣ Install Dependencies

Select:

```
5) Install / Complete Setup
```

---

### 2️⃣ Create Tunnel

```
1) Create/Update profile
2) IRAN Server
```

---

### 3️⃣ Select Slot (1–10)

Each slot represents a saved configuration.

---

### 4️⃣ Enter Bridge Port

Default:

```
7000
```

Must match on both servers.

---

### 5️⃣ Enter Sync Port

Default:

```
7001
```

Must match on both servers. Must be **different** from Bridge Port.

---

### 6️⃣ Enable AutoSync?

```
y  → Enable
n  → Disable
```

---

### 7️⃣ Enter Config Port

Enter your desired service port.

Press Enter to finish.

---

# 🔵 Step 2 — Setup EU Server

Repeat same process:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/install.sh)
```

After installation:

```bash
sudo ox-tunnle
```

Select:

```
5) Install / Complete Setup
1) Create/Update profile
2) EU Server
```

- Choose same Slot
- Enter IR Server IP
- Enter same Bridge Port
- Enter same Sync Port

Press Enter to finish.

---

# ▶️ Start Tunnel

## On IR:

```
2) Manage tunnel (select slot)
→ Select IRAN
→ Select Slot
→ 2) Start
→ 5) Status
```

Status must show:

```
Running
```

## On EU:

Repeat same steps.

---

# 🎉 Tunnel Connected Successfully

---

# ⚙ Optional Enhancements

---

## 🚀 Enable BBR Optimization

```
8) Optimize server (BBR + sysctl)
```

Enables:

- BBR congestion control
- fq queue discipline
- sysctl performance tuning

---

## 🕒 Enable Health Check (Cron)

```
3) Enable cron health-check
```

Choose interval in minutes.

Auto-restarts tunnel if stopped.

---

# 🔄 Port Forward Methods

Available methods:

1. iptables (DNAT)
2. nftables
3. HAProxy (Layer 4)
4. socat relay

Each method supports:
- Add rule
- Remove rule
- Show rules

---

# ⚡ Performance Tuning (Advanced)

You can configure environment variables:

```bash
export OXTUNNEL_POOL=128
export AUTO_SOCKBUF=1
export BUF_COPY_BYTES=262144
export METRICS_PORT=9109
```

> **Note:** The legacy `PAHLAVI_POOL` env var is still accepted for backward compatibility.

---

# 🔐 Security Recommendations

- Only open required ports
- Use firewall rules carefully
- Keep Bridge & Sync ports protected
- Monitor active connections
- Enable failover if using multiple EU servers

---

# 🛠 Troubleshooting

Check service:

```bash
systemctl status ox-tunnle
```

Check listening ports:

```bash
ss -lntp
```

Test connectivity:

```bash
nc -zv IR_IP 7000
```

---

# 📊 Recommended Production Setup

- Enable BBR
- Enable Cron HealthCheck
- Use HAProxy for managed forwarding
- Use AutoSync
- Monitor logs regularly

---

# ❓ FAQ

### Q: Bridge & Sync ports must match?
Yes, both servers must use identical values. They must also be **different from each other**.

### Q: Can I run multiple tunnels?
Yes, use different slots.

### Q: What if tunnel stops?
Enable Cron HealthCheck.

### Q: Does it survive reboot?
Yes (systemd integration).

### Q: What changed from PAHLAVI_POOL to OXTUNNEL_POOL?
Both env vars are supported. `OXTUNNEL_POOL` is the new name; `PAHLAVI_POOL` still works.

---

# 📁 Project Structure

```
ox-tunnle.sh   → Manager Script
ox-tunnle.py   → Core Tunnel Engine
install.sh     → One-line installer
```

---

# 📌 Final Notes

Any configuration change must be applied identically on both servers.

Restart tunnel after changes.

---

# ❤️ Maintained by Ox Tunnle
