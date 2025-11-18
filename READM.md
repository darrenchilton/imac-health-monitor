# iMac Health Monitoring System

**Automated system health monitoring with Airtable tracking - Version controlled on GitHub, runs locally on your Mac**

[![macOS](https://img.shields.io/badge/macOS-Sonoma%2B-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

---

## 🎯 Overview

Proactive health monitoring system for macOS that tracks your system's vital signs and sends daily reports to Airtable. Perfect for catching hardware issues before they become critical failures.

**Born from necessity:** After experiencing a kernel panic and Fusion Drive failure, this system was created to provide early warning of potential problems.

### Key Features

- ✅ **SMART status monitoring** - Track your external boot drive health
- ✅ **Kernel panic detection** - Alert on system crashes (last 7 days)
- ✅ **System error tracking** - Monitor log errors and critical events
- ✅ **Drive space monitoring** - Prevent full disk issues
- ✅ **Memory pressure tracking** - Performance indicators
- ✅ **CPU temperature** - Real-time thermal monitoring (with osx-cpu-temp)
- ✅ **Time Machine verification** - Backup status checks
- ✅ **Historical tracking** - All data stored in Airtable with timestamps
- ✅ **Automated scheduling** - Daily/hourly checks via launchd
- ✅ **Health scoring** - Quick status overview

---

## 🔒 Security Model

- **Scripts**: Version controlled on GitHub (no sensitive data)
- **Credentials**: Stored locally in `.env` file (gitignored, never committed)
- **Updates**: `git pull` to get script updates, credentials stay safe on your Mac
- **Flexibility**: Each Mac can have its own `.env` with unique credentials

---

## 🚀 Quick Start

### Prerequisites

- macOS Sonoma or later (should work on earlier versions)
- Airtable account (free tier works great)
- Homebrew (optional, for CPU temperature monitoring)

### 1. Clone the Repository

```bash
cd ~/Documents  # or wherever you want to keep it
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor
```

### 2. Set Up Airtable (5 minutes)

1. Go to [airtable.com](https://airtable.com) and sign in (or create free account)
2. Create a new base called **"iMac System Health"**
3. Rename the default table to **"System Health"**
4. Get your credentials:
   - **API Token**: Go to https://airtable.com/create/tokens
     - Create new token with scopes: `data.records:read`, `data.records:write`, `schema.bases:read`
     - Add your "iMac System Health" base to the token's access list
   - **Base ID**: Go to https://airtable.com/api, click your base, find the ID in the URL (starts with `app`)

### 3. Run Setup

```bash
chmod +x setup.sh
./setup.sh
```

The interactive setup will:
- Create your local `.env` file with Airtable credentials (gitignored)
- Test your Airtable connection
- Run a test health check
- Configure automated scheduling (daily, twice daily, or every 6 hours)
- Load the launch agent for automatic execution

### 4. Verify It's Working

```bash
# Check your Airtable base for new health record
# View logs
tail -20 ~/Library/Logs/imac_health_monitor.log

# Verify scheduled job is loaded
launchctl list | grep healthmonitor
```

---

## 📊 What Gets Monitored

| Metric | Details | Why It Matters |
|--------|---------|----------------|
| **SMART Status** | External boot drive health | Early warning of drive failure |
| **Kernel Panics** | Crash detection (7 days) | System stability tracking |
| **System Errors** | Log analysis (1 hour) | Identify recurring issues |
| **Drive Space** | Usage percentage | Prevent full disk crashes |
| **Memory Pressure** | RAM usage percentage | Performance indicator |
| **CPU Temperature** | Thermal monitoring | Catch overheating issues |
| **System Uptime** | Time since boot | Stability metric |
| **Time Machine** | Last backup timestamp | Data protection verification |
| **Health Score** | Overall assessment | Quick status overview |

---

## 🌡️ CPU Temperature Monitoring (Optional Enhancement)

For real CPU temperature readings instead of placeholder text:

```bash
# Install Homebrew if needed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install osx-cpu-temp
brew install osx-cpu-temp

# Update the script's get_cpu_temp() function to use osx-cpu-temp
# The function should call: osx-cpu-temp
```

After installation, the script will automatically report actual CPU temperatures to Airtable.

---

## 💻 Daily Usage

### Run Health Check Manually

```bash
./imac_health_monitor.sh
```

### View Recent Logs

```bash
tail -50 ~/Library/Logs/imac_health_monitor.log
```

### Check Scheduled Job Status

```bash
launchctl list | grep healthmonitor
```

### Restart Automated Monitoring

```bash
launchctl unload ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
launchctl load ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

---

## 🔄 Updating from GitHub

When updates are pushed to the repository:

```bash
cd ~/Documents/imac-health-monitor  # your repo location
git pull
```

Your local `.env` file with credentials is preserved. If configuration requirements change, re-run:

```bash
./setup.sh
```

---

## 📁 Repository Structure

```
imac-health-monitor/
├── README.md                      # This file
├── GITHUB_SETUP.md                # Detailed GitHub setup guide
├── SETUP_GUIDE.md                 # Comprehensive setup documentation
├── QUICK_REFERENCE.md             # Command cheat sheet
├── GETTING_STARTED.md             # Quick start guide
├── imac_health_monitor.sh         # Main monitoring script
├── setup.sh                       # Interactive setup wizard
├── test_airtable_connection.sh    # Connection tester
├── .env.example                   # Credential template
├── .gitignore                     # Protects sensitive files
└── .env                           # YOUR credentials (gitignored, you create this)
```

---

## 🏥 Health Indicators

### ✅ Healthy System
- SMART Status: "Verified"
- Kernel Panics: "No kernel panics in last 7 days"
- System Errors: Low counts (< 50 errors/hour)
- Drive Space: < 80% used
- Health Score: "Healthy"

### ⚠️ Attention Needed
- Drive Space: 80-90% full
- Elevated error counts: > 100 errors/hour
- High memory pressure: > 80% consistently
- Health Score: "Attention Needed"

### 🚨 Critical Issues
- SMART Status: "Failed" or changed from "Verified"
- New kernel panic detected
- Drive Space: > 90% full
- High critical error rate: > 50 critical errors/hour

---

## 🔧 Configuration

### Change Monitoring Schedule

Edit your launch agent:

```bash
nano ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

**Options:**

**Daily at 9 AM:**
```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
</dict>
```

**Twice daily (9 AM and 9 PM):**
```xml
<key>StartCalendarInterval</key>
<array>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
    </dict>
    <dict>
        <key>Hour</key>
        <integer>21</integer>
    </dict>
</array>
```

**Every 6 hours:**
```xml
<key>StartInterval</key>
<integer>21600</integer>
```

After editing, reload:
```bash
launchctl unload ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
launchctl load ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

### Update Airtable Credentials

```bash
nano .env  # Edit credentials directly
# Or re-run setup
./setup.sh
```

---

## 🐛 Troubleshooting

### Health Check Not Running Automatically

```bash
# Check if loaded
launchctl list | grep healthmonitor

# View error log
cat ~/Library/Logs/imac_health_monitor_stderr.log

# Reload launch agent
launchctl unload ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
launchctl load ~/Library/LaunchAgents/com.user.imac.healthmonitor.plist
```

### Data Not Appearing in Airtable

```bash
# Verify credentials
cat .env

# Test Airtable connection
./test_airtable_connection.sh

# Run manually to see errors
./imac_health_monitor.sh

# Check detailed logs
tail -100 ~/Library/Logs/imac_health_monitor.log
```

### Permission Errors

```bash
# Make scripts executable
chmod +x imac_health_monitor.sh setup.sh test_airtable_connection.sh
```

### After `git pull`, Something Broke

Your credentials are safe! Just reconfigure:

```bash
./setup.sh
```

---

## 📚 Additional Documentation

- **[GITHUB_SETUP.md](./GITHUB_SETUP.md)** - Complete guide to setting up your GitHub repo
- **[SETUP_GUIDE.md](./SETUP_GUIDE.md)** - Detailed setup and configuration
- **[QUICK_REFERENCE.md](./QUICK_REFERENCE.md)** - Command reference and tips
- **[GETTING_STARTED.md](./GETTING_STARTED.md)** - Quick 3-step workflow

---

## 🎯 Use Case: Real-World Example

**The Problem:**
- 2019 iMac experienced kernel panic
- Internal Fusion Drive failed catastrophically
- No warning before complete boot failure
- System had to be recovered from Time Machine to external SSD

**The Solution:**
This monitoring system now provides:
- Daily SMART status checks on the external boot SSD
- Kernel panic detection and tracking
- Drive space monitoring to prevent full disk issues
- Historical data for troubleshooting patterns
- Peace of mind through proactive monitoring

**Current Setup:**
- iMac19,1 (2019) with 72GB RAM
- Boot drive: SanDisk PRO-G40 1TB Thunderbolt 3 SSD
- Monitoring: Daily health checks to Airtable
- Result: Early warning system for hardware issues

---

## 🚀 Advanced Features

### Multiple Mac Monitoring

Monitor multiple Macs with the same Airtable base:

```bash
# On each Mac, clone and setup
git clone https://github.com/YOUR_USERNAME/imac-health-monitor.git
cd imac-health-monitor
./setup.sh  # Each Mac gets its own .env
```

Each Mac reports to the same Airtable base with its unique hostname, allowing centralized monitoring.

### Airtable Automations

Set up alerts in Airtable:
1. Go to "Automations" in your base
2. Trigger: "When Health Score = 'Attention Needed'"
3. Action: "Send email" or "Send to Slack"
4. Get notified immediately when issues are detected

### Custom Dashboards

Connect Airtable to:
- **Airtable Interfaces** - Build custom dashboards
- **Google Data Studio** - Create charts and graphs
- **Zapier** - Advanced integrations
- **iOS Shortcuts** - Quick access from phone

---

## 🔐 Security Best Practices

### What's Safe to Commit (and is in repo)
- ✅ All `.sh` scripts
- ✅ All `.md` documentation  
- ✅ `.env.example` (template only, no real credentials)
- ✅ `.gitignore` configuration

### What's Never Committed (gitignored)
- ❌ `.env` (your actual Airtable API credentials)
- ❌ `*.log` files (log output)
- ❌ `.DS_Store` (macOS system files)
- ❌ Any files with sensitive data

### If You Accidentally Commit Credentials

```bash
# Remove from repo but keep locally
git rm --cached .env
git commit -m "Remove .env from repository"
git push

# CRITICAL: Immediately rotate your Airtable API token
# Go to https://airtable.com/create/tokens and create new token
```

---

## 📈 Roadmap

Potential future enhancements:
- [ ] Network connectivity monitoring
- [ ] Disk I/O performance tracking
- [ ] Application-specific monitoring
- [ ] Email/SMS alert integration
- [ ] Web dashboard interface
- [ ] Battery health monitoring (for laptops)
- [ ] GPU temperature tracking

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📝 License

This project is licensed under the MIT License - feel free to use and modify as needed.

---

## 🙏 Acknowledgments

- Built with macOS native tools (diskutil, log, tmutil, vm_stat)
- Airtable for flexible data storage and visualization
- [osx-cpu-temp](https://github.com/lavoiesl/osx-cpu-temp) for CPU temperature monitoring

---

## 📞 Support

- **Issues**: Open an issue on GitHub
- **Documentation**: Check the docs in the repository
- **Airtable Help**: https://support.airtable.com/

---

## 🎉 Getting Started

Ready to set up your monitoring system?

1. **[Clone the repo](#1-clone-the-repository)**
2. **[Set up Airtable](#2-set-up-airtable-5-minutes)**
3. **[Run setup](#3-run-setup)**
4. **[Verify it's working](#4-verify-its-working)**

Your Mac will thank you for the proactive care! 🖥️💚
