# iMac Health Monitoring System

The iMac Health Monitor is a Bash-based system that collects hardware, OS, user, and error metrics every 20 minutes and sends them to Airtable for centralized analysis. It is optimized for a 2019 iMac running macOS Sonoma from an external Thunderbolt SSD, with statistically calibrated thresholds that reflect real macOS log volume.

**Note (Jan 2026):** The monitor now runs as a **system LaunchDaemon** (system domain) so it works outside of user login sessions. The older **LaunchAgent** instructions are retained for reference but should be considered deprecated.


**Version 3.4.0** adds RTC clock drift monitoring to detect hardware timing issues that can cause GPU timeouts and system instability.

This README covers what the system is, how to install it, how to configure it, and what metrics it reports.

---

## Installation

### Prerequisites
- macOS Sonoma 15.7.2+
- Airtable account with API access
- Homebrew (optional for CPU temperature)
- Full Disk Access (optional for Time Machine)

### Setup Steps

### Setup Steps (LaunchDaemon — Current)

0. **Create system env file (root-only)**
```bash
sudo tee /etc/imac-health-monitor.env >/dev/null << 'EOF'
AIRTABLE_PAT=your_personal_access_token_here
AIRTABLE_BASE_ID=your_base_id_here
AIRTABLE_TABLE_NAME=System Health
EOF
sudo chown root:wheel /etc/imac-health-monitor.env
sudo chmod 600 /etc/imac-health-monitor.env
sudo cp com.slavicany.imac-health-monitor.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.slavicany.imac-health-monitor.plist
sudo chmod 644 /Library/LaunchDaemons/com.slavicany.imac-health-monitor.plist

sudo launchctl bootstrap system /Library/LaunchDaemons/com.slavicany.imac-health-monitor.plist
sudo launchctl enable system/com.slavicany.imac-health-monitor
sudo launchctl kickstart -k system/com.slavicany.imac-health-monitor

Daemon logs:

/var/log/imac_health_monitor.launchd.log

/var/log/imac_health_monitor.launchd.err

/var/log/imac_health_monitor.script.log


Then leave the existing “Setup Steps” (1–7) in place, but add a one-line label above them:

**Insert immediately above your existing “1. Clone repository”**:

```md
### Setup Steps (LaunchAgent — Legacy / Deprecated)

1. **Clone repository**
```bash
cd ~/Documents
git clone https://github.com/darrenchilton/imac-health-monitor.git
cd imac-health-monitor
```

2. **Create `.env`**
```bash
cat > .env << 'EOF'
AIRTABLE_PAT=your_personal_access_token_here
AIRTABLE_BASE_ID=your_base_id_here
AIRTABLE_TABLE_NAME=System Health
EOF
chmod 600 .env
```

3. **Optional: Install temperature monitor**
```bash
brew install osx-cpu-temp
```

4. **Manual test**
```bash
./imac_health_monitor.sh
```

5. **Install LaunchAgent**
```bash
cp com.slavicany.imac-health-monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
```

6. **Optional updater**
```bash
cp com.slavicanikolic.imac-health-updater.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

7. **Prevent sleep (required for 24/7 monitoring)**
```bash
sudo pmset -c sleep 0
sudo pmset -c disksleep 0
sudo pmset -c displaysleep 10
```

---

## Configuration

The monitor loads Airtable credentials from `/etc/imac-health-monitor.env` when running as a LaunchDaemon. If that file is not present, it falls back to a local `.env` file in the repository directory.


```
AIRTABLE_PAT=
AIRTABLE_BASE_ID=
AIRTABLE_TABLE_NAME="System Health"
```

**Airtable PAT note:**  
*2025-12-08: Rotated Airtable PAT and restricted scopes to the System Health base (read/write records).*

The LaunchAgent (`com.slavicany.imac-health-monitor.plist`) runs every 1200 seconds (20 minutes) and writes logs to `~/Library/Logs/`.

---

## Metrics Reported

The monitor collects hardware state, OS activity, and diagnostic information:

### Hardware
- SMART drive status  
- Kernel panics (24h window)  
- CPU temperature  
- Memory pressure  
- Drive space  

### System Health & Errors
- Error Count (1 hour)  
- Recent Error Count (5 minutes)  
- Critical Fault Count  
- Subsystem error buckets (kernel, WindowServer/GPU, Spotlight, iCloud, disk I/O, network, systemstats, power)  
- Thermal throttling indicators  
- Top errors (1h)  
- Unclassified top errors (1h)
- **RTC Clock Drift Monitoring**
  - Clock Drift Status (Healthy/Warning/Critical)
  - Clock Offset (seconds from NTP)
  - Clock Drift Details (includes rateSf clamping events)

### Users & Applications
- Active console users  
- Idle time  
- Running GUI applications with versions  
- Resource hog detection (>80% CPU / >4GB RAM)  
- Legacy software detection  

### VMware
- VMware status (Running / Not Running)  
- Per-VM CPU, memory, runtime  
- Guest OS detection  
- Legacy guest OS flags  
- Aggregated CPU / memory across VMs  

### Remote Access & Reachability
- SSH server running + port open  
- Screen Sharing running + VNC port  
- Tailscale CLI presence  
- Tailscale peer reachable  
- AnyDesk/Splashtop artifacts and count  

### Run Metadata
- Run duration  
- Debug log  
- System error summaries  
- Recent crash list

- ### GPU Stability (Baseline Instrumentation)

The monitor currently reports a minimal set of GPU-related indicators intended for long-term correlation, not real-time alerting:

- gpu_timeout_1h  
  Count of GPU timeout-style log messages observed in the last hour.

- gpu_reset_1h  
  Count of GPU reset / restart messages observed in the last hour.

- gpu_last_event_ts  
  Timestamp of the most recent GPU timeout event (only populated when gpu_timeout_1h > 0).

- gpu_last_event_excerpt  
  Short log excerpt from the most recent GPU timeout event (only populated when gpu_timeout_1h > 0).

Notes:
- These fields are expected to be zero or blank under normal conditions.
- Blank values indicate absence of GPU-related instability, not a data collection failure.
- Additional GPU/WindowServer correlation fields are intentionally deferred until sufficient baseline data is collected.


---

## Current Version: v3.4.0

### RTC Clock Drift Monitoring (v3.4.0 - Dec 2025)
- Real-time NTP offset detection via `sntp`
- Automatic classification: Healthy (<0.1s), Warning (0.1-0.2s), Critical (>0.2s)
- Detects rateSf clamping errors (indicates persistent hardware clock issues)
- Integrated into health scoring and severity assessment
- Addresses correlation between clock drift and GPU timeouts/watchdog panics

### Previous Enhancements (v3.2.x - v3.3.0)
This version builds on statistical thresholds, crash detection, reachability checks, and unclassified error analysis from v3.2-3.3 series.  
Full details are in `SYSTEM_NOTES.md`.

**Also included:**  
*2025-12-08: Airtable PAT rotated; scopes restricted to System Health base (read/write).*

---

## Troubleshooting (Quick)

### LaunchAgent not running
```bash
launchctl list | grep imac-health
sudo tail -n 200 /var/log/imac_health_monitor.launchd.err
sudo tail -n 200 /var/log/imac_health_monitor.launchd.log
```

### Always “Critical”
Upgrade to >= v3.2.0 (calibrated thresholds).

### Airtable errors
```bash
curl -X GET "https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}" \
  -H "Authorization: Bearer ${AIRTABLE_PAT}"
```

---

## License
MIT License
