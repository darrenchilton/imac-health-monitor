# **iMac Health Monitor (v2.2)**

A lightweight health‑monitoring system for macOS (optimized for iMacs) that collects system diagnostics and pushes them to Airtable for centralized monitoring. Now includes **noise-filtered log analysis**, **improved System Error parsing**, and optional **log‑noise suppression** to prevent false alerts from normal macOS background activity.

---

## **📌 Features**

### **Monitors System Health**

| Category        | What Is Checked                        | Notes                                  |
| --------------- | -------------------------------------- | -------------------------------------- |
| SMART Status    | Boot disk SMART status                 | Works with external SSDs               |
| Kernel Panics   | **Last 24 hours**                      | Shows count + latest file              |
| System Logs     | Errors, recent activity & critical faults | Now noise-filtered to avoid false positives |
| Disk Usage      | Total / Used / % Used                  | Uses HOME volume                       |
| Memory Pressure | Active + wired memory usage            | Works without FDA                      |
| CPU Temperature | From sensors if available              | Supports Homebrew installs             |
| Time Machine    | Status + age of last backup            | Works with or without Full Disk Access |
| Uptime          | System uptime                          | Reliable and simple                    |
| Software Updates | macOS updates available               | Safe timeout prevents hangs            |

### **Calculates a Health Score**

* **Healthy**
* **Attention Needed**

Based on thresholds for:

* SMART status
* Kernel panics
* Disk usage
* CPU temperature
* **Noise‑filtered system log activity**
* Time Machine backup age

---

## **🆕 Noise‑Filtered Log Analysis (v2.2 Update)**

macOS produces large volumes of harmless background log messages. To prevent false alerts, the script now uses **noise‑tolerant thresholds**:

| Condition | RECENT_ERROR_COUNT (last 5 min) | Severity |
|----------|-------------------------------|----------|
| **Healthy** | 0 – 2000 | Within normal macOS noise |
| **Warning** | 2001 – 5000 | Elevated but not dangerous |
| **Critical** | > 5000 | Sustained error storm |

This dramatically reduces false “Attention Needed” results.

### **NOISE_FILTERING Toggle (.env)**

```
NOISE_FILTERING=1   # Default – ignore normal macOS noise
NOISE_FILTERING=0   # Legacy mode, more sensitive
```

---

## **📡 Data Sent to Airtable**

* Timestamp
* Hostname
* macOS version
* SMART Status
* Kernel Panics
* **System Errors (new structured format)**
* Drive Space
* Uptime
* Memory Pressure
* CPU Temperature
* Time Machine Status
* Software Updates
* Health Score
* Severity
* Reasons (noise‑aware)

### **New System Errors Format (v2.2)**

```
Log Activity: <errors_1h> errors (1h), <recent_5m> recent (5m), <critical_1h> critical (1h)
```

Example:
```
Log Activity: 38767 errors (1h), 1253 recent (5m), 2953 critical (1h)
```

This format is easier to parse and consistent across runs.

---

## **📊 Optional: Unified Error Object for Airtable**

You can create a single parsed JSON‑like field in Airtable using:

```
{"errors_1h":38767,"recent_5m":1253,"critical_1h":2953}
```

Suggested Airtable formula:

```
IF(
  {System Errors},
  "{" &
    "\"errors_1h\": " & VALUE(REGEX_EXTRACT({System Errors}, "Log Activity:\s*([0-9]+)")) & "," &
    "\"recent_5m\": " & VALUE(REGEX_EXTRACT({System Errors}, "([0-9]+)\s*recent")) & "," &
    "\"critical_1h\": " & VALUE(REGEX_EXTRACT({System Errors}, "([0-9]+)\s*critical")) &
  "}",
  ""
)
```

Great for trend analysis and dashboards.

---

## **🆕 Update System**

Two syncing workflows are supported:

### **1️⃣ GitHub → iMac (Automatic Updates)**
Automatically syncs changes from GitHub using `update_from_github.sh` and a `launchd` job.

Run:
```
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

### **2️⃣ iMac → GitHub (Manual Push)**
Push local modifications:
```
./push_to_github.sh "Your commit message"
```

---

## **📁 Directory Structure**
```
imac-health-monitor/
 ├── imac_health_monitor.sh
 ├── update_from_github.sh
 ├── push_to_github.sh
 ├── .env
 ├── README.md
 └── LaunchAgent plist files
```

---

## **⚙️ Installation Instructions**

### **Step 1 — Clone the project**
```
git clone git@github.com:darrenchilton/imac-health-monitor.git
cd imac-health-monitor
```

### **Step 2 — Create `.env`**
```
AIRTABLE_API_KEY=your_key
AIRTABLE_BASE_ID=appXXXXXXXXXXXX
AIRTABLE_TABLE_NAME="System Health"
NOISE_FILTERING=1
```

### **Step 3 — Make scripts executable**
```
chmod +x imac_health_monitor.sh
chmod +x update_from_github.sh
chmod +x push_to_github.sh
```

### **Step 4 — Install Auto‑Updater (Optional)**
```
cp com.slavicanikolic.imac-health-updater.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

### **Step 5 — Schedule Health Monitor via launchd**
Example plist:
```
~/Library/LaunchAgents/com.imac.healthmonitor.plist
```

---

## **🧪 Test Run**

Debug mode (prints payload to log):
```
DEBUG=1 ./imac_health_monitor.sh
```

Logs:
```
~/Library/Logs/imac_health_monitor.log
```

---

## **🛣 Roadmap**
* Trend analysis over time
* Weekly summaries
* Optional Slack/email alerts
* Local HTML dashboard
* Deeper hardware-level checks (fans, voltages)

---

## **📄 License**
MIT

