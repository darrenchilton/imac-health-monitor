# iMac Health Monitoring System

![Version](https://img.shields.io/badge/version-1.0.0-green)
![macOS](https://img.shields.io/badge/macOS-Sonoma%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 📚 Table of Contents
- [Overview](#-overview)
- [Airtable Field Reference](#-airtable-field-reference)
- [Security Model](#-security-model)
- [Quick Start](#-quick-start)
- [What Gets Monitored](#-what-gets-monitored)
- [Daily Usage](#-daily-usage)
- [Updating from GitHub](#-updating-from-github)
- [Repository Structure](#-repository-structure)
- [Health Indicators](#-health-indicators)
- [Configuration](#-configuration)
- [Troubleshooting](#-troubleshooting)
- [Additional Documentation](#-additional-documentation)
- [Use Case (Real-World Example)](#-use-case-real-world-example)
- [Advanced Features](#-advanced-features)
- [Security Best Practices](#-security-best-practices)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)
- [License](#-license)
- [Acknowledgments](#-acknowledgments)
- [Support](#-support)
- [Getting Started](#-getting-started)

---

## 🎯 Overview

Proactive health monitoring system for macOS that tracks system vitals and automatically sends daily reports to Airtable. Perfect for detecting early warning signs of hardware issues—before they become failures.

Created after experiencing kernel panics and a Fusion Drive failure, this tool serves as a real-world preventive monitoring solution.

---

## 📊 Airtable Field Reference

Below is a complete reference of the Airtable fields produced by the monitoring system.

### Primary Fields (Script-Generated)

| Field Name | Type | Description |
|-----------|------|-------------|
| Timestamp | Date/Time | When the script ran |
| Hostname | Text | Mac reporting data |
| macOS Version | Text | OS version |
| SMART Status | Single select | Verified / Failed / Not Available |
| Kernel Panics | Text | Summary of recent panics |
| System Errors | Text | “Errors: #, Critical: # (last 1h)” |
| Drive Space | Text | Full drive space metrics |
| Uptime | Text | Time since last reboot |
| Memory Pressure | Text | RAM % utilization |
| CPU Temperature | Text | Example: `53.4°C` |
| Time Machine | Text | Backup status summary |
| Health Score | Single select | Healthy / Attention Needed |
| Severity | Single select | Info / Warning / Critical |
| Reasons | Long text | Explanation for state |

### Derived Formula Fields

**Disk Used %**
```text
IF(
  {Drive Space},
  VALUE(REGEX_EXTRACT({Drive Space}, "\(([0-9]+)%\)")),
  BLANK()
)
```

**CPU Temp (°C)**
```text
IF(
  {CPU Temperature},
  VALUE(REGEX_EXTRACT({CPU Temperature}, "([0-9]+\.?[0-9]*)")),
  BLANK()
)
```

**Error Count**
```text
IF(
  {System Errors},
  VALUE(REGEX_EXTRACT({System Errors}, "Errors:\s*([0-9]+)")),
  0
)
```

**Critical Count**
```text
IF(
  {System Errors},
  VALUE(REGEX_EXTRACT({System Errors}, "Critical:\s*([0-9]+)")),
  0
)
```

**TM Age (days)**
```text
IF(
  REGEX_MATCH({Time Machine}, "Latest:"),
  DATETIME_DIFF(
    NOW(),
    DATETIME_PARSE(
      REGEX_EXTRACT({Time Machine}, "Latest:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})"),
      "YYYY-MM-DD"
    ),
    'days'
  ),
  BLANK()
)
```

---

## 🔒 Security Model

The system is designed so that **no sensitive data is ever committed to GitHub** and all credentials stay local to your Mac.

### Key Principles

#### 1. Credentials Stay Local
- Stored only in `.env` (gitignored)
- Safe from being pushed to GitHub
- Each Mac can use unique credentials

#### 2. Only Safe Files Are Versioned
Safe:
- `.sh` scripts  
- Markdown docs  
- `.env.example`  
- `.gitignore`

Not stored:
- `.env`  
- Logs  
- System files  
- Any sensitive data

#### 3. Runs Locally with Minimal Surface Area
- Uses macOS built-in utilities (diskutil, log, tmutil)  
- No external dependencies except Airtable  
- No telemetry, background daemons, or remote code execution

#### 4. Safe Updates
`git pull` never touches `.env`.  
If configuration changes, simply rerun:

```bash
./setup.sh
```

---

## 🚀 Quick Start

### 1. Install Homebrew & Dependencies
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install osx-cpu-temp
```

### 2. Grant Full Disk Access (Recommended)
System Settings → Privacy & Security → Full Disk Access  
Add:
- Terminal  
- `/bin/bash`

### 3. Clone the Repository
```bash
cd ~/Documents
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor
```

### 4. Set Up Airtable
Get:
- API Token (via https://airtable.com/create/tokens)
- Base ID (via https://airtable.com/api)

### 5. Run Setup
```bash
chmod +x setup.sh
./setup.sh
```

### 6. Verify It’s Working
```bash
launchctl list | grep imac-health
tail -20 ~/Library/Logs/imac_health_monitor.log
```

---

## 📊 What Gets Monitored

| Metric | Details | Why It Matters |
|--------|---------|----------------|
| SMART Status | Boot drive health | Detect early drive failure |
| Kernel Panics | Last 24 hours | Stability issues
| System Errors | Last 1 hour | Recurring problems |
| Drive Space | Disk usage % | Prevent full disk crash |
| Memory Pressure | RAM usage | Performance indicator |
| CPU Temperature | via osx-cpu-temp | Thermal risk detection |
| System Uptime | Time since boot | Stability metric |
| Time Machine | Last backup | Data protection |
| Health Score | Combined evaluation | Quick overview |

---

## 💻 Daily Usage

### Run Manually
```bash
./imac_health_monitor.sh
```

### View Logs
```bash
tail -50 ~/Library/Logs/imac_health_monitor.log
```

### Check Scheduled Task
```bash
launchctl list | grep healthmonitor
```

### Restart Automated Monitoring
```bash
launchctl unload ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
launchctl load ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

---

## 📄 Updating from GitHub

```bash
cd ~/Documents/imac-health-monitor
git pull
```

If updated settings:
```bash
./setup.sh
```

---

## 📁 Repository Structure

```
imac-health-monitor/
├── README.md
├── GITHUB_SETUP.md
├── SETUP_GUIDE.md
├── QUICK_REFERENCE.md
├── GETTING_STARTED.md
├── imac_health_monitor.sh
├── setup.sh
├── test_airtable_connection.sh
├── .env.example
├── .gitignore
└── .env  (ignored)
```

---

## 🏥 Health Indicators

### Healthy
- SMART: Verified  
- Disk < 80%  
- Low error counts  
- Backups recent  

### Attention Needed
- Disk 80–90%  
- Elevated error counts  
- Memory pressure > 80%  

### Critical
- SMART failed  
- Kernel panics  
- Disk > 90%  
- Critical error spikes  

---

## 🔧 Configuration

### Change Schedule
Edit:
```bash
nano ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

### Update Credentials
```bash
nano .env
./setup.sh
```

---

## 🛠 Troubleshooting

### Health Check Not Running
```bash
launchctl list | grep healthmonitor
cat ~/Library/Logs/imac_health_monitor_stderr.log
```

### CPU Temp Not Showing
```bash
brew install osx-cpu-temp
osx-cpu-temp
```

### Airtable Issues
```bash
./test_airtable_connection.sh
./imac_health_monitor.sh
```

---

## 📚 Additional Documentation

- [GITHUB_SETUP.md](./GITHUB_SETUP.md)
- [SETUP_GUIDE.md](./SETUP_GUIDE.md)
- [QUICK_REFERENCE.md](./QUICK_REFERENCE.md)
- [GETTING_STARTED.md](./GETTING_STARTED.md)

---

## 🎯 Use Case (Real-World Example)

A 2019 iMac suffered a Fusion Drive failure without warning.  
This system now provides:

- SMART drive checks  
- Kernel panic detection  
- Uptime + thermal data  
- Time Machine verification  
- Historical trends for diagnosis  

---

## 🚀 Advanced Features

### Multi-Mac Monitoring
```bash
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor
./setup.sh
```

### Airtable Automations
Examples:
- Email alert when Health Score = Attention Needed  
- Slack notifications

### Dashboards
- Temperature trends  
- Disk usage graphs  
- Backup age charts  

---

## 🔐 Security Best Practices

### Safe to Commit
- `.sh`  
- `.md`  
- `.env.example`

### Never Commit
- `.env`  
- `.DS_Store`  
- Logs  

If a key leaks:
```bash
git rm --cached .env
git commit -m "Remove .env"
git push
```
Rotate your Airtable token immediately.

---

## 📈 Roadmap

- Disk I/O performance  
- GPU temperature  
- Laptop battery health  
- SMS/email notifications  
- Web dashboard  

---

## 🤝 Contributing
```bash
git checkout -b feature/MyFeature
git commit -m "Add MyFeature"
git push origin feature/MyFeature
```
Open a pull request anytime.

---

## 📄 License
MIT License

---

## 🙏 Acknowledgments
- macOS native tools  
- Airtable  
- [osx-cpu-temp](https://github.com/lavoiesl/osx-cpu-temp)

---

## 📞 Support
- GitHub Issues  
- Repository Documentation  
- Airtable Support  

---

## 🎉 Getting Started

1. [Install dependencies](#1-install-homebrew-and-dependencies)
2. [Grant Full Disk Access](#2-grant-full-disk-access-recommended)
3. [Clone the repo](#3-clone-the-repository)
4. [Set up Airtable](#4-set-up-airtable-5-minutes)
5. [Run setup](#5-run-setup)
6. [Verify it's working](#6-verify-its-working)

Your Mac will thank you! 🖥️💚

