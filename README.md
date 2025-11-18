# **iMac Health Monitor**

![Version](https://img.shields.io/badge/version-1.1.0-green)

A lightweight health-monitoring system for macOS (optimized for iMacs) that collects system diagnostics and pushes them to Airtable for centralized monitoring.
Includes automatic updates from GitHub → local machine, and an optional local → GitHub push script.

---

## **📌 Features**

### **Monitors system health**

| Category        | What Is Checked                        | Notes                                  |
| --------------- | -------------------------------------- | -------------------------------------- |
| SMART Status    | Boot disk SMART status                 | Works with external SSDs               |
| Kernel Panics   | **Last 24 hours**                      | Shows count + latest file              |
| System Logs     | Errors & critical faults (past 1 hour) | Uses `log show` with timeout           |
| Disk Usage      | Total / Used / % Used                  | Uses HOME volume                       |
| Memory Pressure | Active + wired memory usage            | Works without FDA                      |
| CPU Temperature | If sensors available                   | Supports Homebrew installs             |
| Time Machine    | Status + time of last backup           | Works with or without Full Disk Access |
| Uptime          | System uptime                          | Simple and reliable                    |

### **Calculates a Health Score**

* **Healthy**
* **Attention Needed**

Based on thresholds for:

* SMART status
* Kernel panics
* Disk % used
* CPU temperature
* System log errors
* Time Machine backup age

---

## **📡 Sends Data to Airtable**

Fields sent:

* Timestamp
* Hostname
* macOS version
* SMART Status
* Kernel Panics
* System Errors
* Drive Space
* Uptime
* Memory Pressure
* CPU Temperature
* Time Machine Status
* Health Score
* Severity
* Reasons

All JSON sent to Airtable is sanitized and can optionally use `jq` for safer encoding.

---

## **🆕 Update System**

The project now supports **two update workflows:**

---

# **1️⃣ GitHub → iMac (Automatic Updates)**

When you're away from the iMac, you can edit the script on GitHub and the computer will automatically stay in sync.

### **How it works**

* A script (`update_from_github.sh`) checks GitHub periodically.
* If the remote `main` branch has new commits:

  * It pulls them
  * Updates local files
  * Re-chmods the monitor script
* A `launchd` job runs every 15 minutes.

### **Install the updater**

Files involved:

```
update_from_github.sh
~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

Once installed:

```bash
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

You never need to manually update the script again when editing via GitHub.

---

# **2️⃣ iMac → GitHub (Manual Push Script)**

When you make local changes on the iMac, run this command to commit and push everything to GitHub:

```bash
./push_to_github.sh "Your commit message"
```

If you run it with no arguments, it will ask for a message.

Files involved:

```
push_to_github.sh
```

---

# **📁 Directory Structure**

Typical structure:

```
imac-health-monitor/
 ├── imac_health_monitor.sh
 ├── update_from_github.sh
 ├── push_to_github.sh
 ├── .env                  # Airtable credentials
 ├── .env.example
 ├── README.md
 └── LaunchAgent plist (installed under ~/Library/LaunchAgents)
```

---

# **⚙️ Installation Instructions**

## **Step 1 — Clone the project**

```bash
git clone git@github.com:darrenchilton/imac-health-monitor.git
cd imac-health-monitor
```

(SSH recommended for auto-pulls.)

---

## **Step 2 — Create `.env` file**

Use `.env.example` as a guide:

```
AIRTABLE_API_KEY=your_key_here
AIRTABLE_BASE_ID=appXXXXXXXXXXXX
AIRTABLE_TABLE_NAME="System Health"
```

---

## **Step 3 — Make scripts executable**

```bash
chmod +x imac_health_monitor.sh
chmod +x update_from_github.sh
chmod +x push_to_github.sh
```

---

## **Step 4 — Set up the GitHub → iMac auto-updater (optional but recommended)**

Copy the provided `.plist` to:

```
~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

---

## **Step 5 — Schedule the health monitor via `launchd`**

(If you haven't already.)

Example plist:

```
~/Library/LaunchAgents/com.imac.healthmonitor.plist
```

This can run the monitor script every hour, 6 hours, etc.

---

# **🧪 Test Run**

You can test the script without sending data to Airtable by echoing the JSON payload:

```bash
DEBUG=1 ./imac_health_monitor.sh
```

Or fully run it:

```bash
./imac_health_monitor.sh
```

Check logs:

```
~/Library/Logs/imac_health_monitor.log
~/Library/Logs/imac_health_updater.log
~/Library/Logs/imac_health_updater.out
~/Library/Logs/imac_health_updater.err
```

---

# **🚧 Roadmap**

* Add self-test / diagnostics mode
* Add optional Slack or email alerts
* Add a simple local dashboard (HTML/MiniUI)
* Add deeper hardware-level checks (fans, voltages, etc.)

---

# **📄 License**

MIT (or whichever you choose — not currently specified)