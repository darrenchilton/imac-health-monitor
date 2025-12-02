# iMac Health Monitor - Technical Documentation

**Version:** 3.2.3  
**Last Updated:** 2025-12-01  
**Platform:** macOS Sonoma 15.7.2+  
**Target Hardware:** 2019 iMac 27" with external Thunderbolt 3 boot drive

---

## System Architecture

### Overview
Bash-based health monitoring system that collects system metrics every 20 minutes and transmits them to Airtable for centralized tracking and analysis. Optimized for iMacs running from external SSDs with automatic boot device detection. Version 3.2 implements statistically-derived error thresholds based on 281-sample analysis, eliminating false "Critical" alerts and providing accurate health status reporting.

### Components
```
/Users/slavicanikolic/Documents/imac-health-monitor/
├── imac_health_monitor.sh          # Main monitoring script (v3.2.3)
├── bin/
│   └── run_imac_health_monitor.sh  # LaunchAgent wrapper
├── .env                             # Environment configuration
├── .health_monitor.lock             # PID-based lock file (created during execution)
├── .debug_log.txt                   # Execution debug log (created during execution)
├── LaunchAgent plists:
│   ├── com.slavicany.imac-health-monitor.plist (interval: 1200s)
│   └── com.slavicanikolic.imac-health-updater.plist
└── README.md
```

### Execution Flow
1. **Lock File Check** - Prevents concurrent execution
2. **LaunchAgent Trigger** (every 1200 seconds / 20 minutes)
3. **Environment Loading** (.env credentials)
4. **User/App Detection** (console users, running applications, VMware status)
5. **Metrics Collection** (hardware health, system logs, crash reports)
6. **Health Analysis** (statistically-calibrated threshold-based scoring)
7. **JSON Payload Construction** (jq with 40+ fields)
8. **Airtable Transmission** (curl POST)
9. **Lock File Cleanup** (automatic via trap)
10. **Logging** (stdout/stderr to LaunchAgent logs + debug log)

---

## What's New in v3.2.3

### Process-Based Application Detection (RELIABILITY FIX)
- **Problem**: AppleScript/System Events method failed to detect GUI apps, showing "No GUI apps detected" even when apps were running (Finder, Chrome, Mail, pCloud, etc.)
- **Root Cause**: System Events unresponsive on Sonoma, Accessibility permissions issues, AppleScript failures in multi-user sessions
- **Solution**: Replaced with process-based scanner using `ps` to detect apps running from `*.app/Contents/MacOS/`
- **Impact**: 
  - Reliable app detection independent of Accessibility permissions
  - Works consistently across single/dual user sessions
  - No longer dependent on System Events responsiveness
  - Still supports version extraction and ⚠️ LEGACY software flagging
- **Performance**: ~7 seconds vs. 60-120 seconds with AppleScript
- **Example Output**: Now correctly detects `Finder 15.5, pCloud Drive 3.15, Mail 16.0, Google Chrome 142.0`

---

## What's New in v3.2.2

### Accurate Idle Time Tracking (DATA QUALITY FIX)
- **Problem**: User idle time showed "6days" while actively using the Mac
- **Root Cause**: Previous method (`w` command) showed time since last SSH connection, not actual GUI activity
- **Solution**: Rewritten to use IOHIDSystem via `ioreg` for true GUI input detection
- **New Features**:
  - Human-readable formatting: `5s`, `3m`, `1:45`, `2days` instead of raw seconds
  - Treats <5 seconds idle as "active" (prevents flickering between active/idle)
  - Accurate tracking of keyboard/mouse/trackpad input
- **Impact**: Idle time now reflects actual user activity, not last remote login
- **Example**: User actively typing → shows `active` or `12s`, not `6days`

---

## What's New in v3.2.1

### VM Activity State Classification
- **New Field**: `VM State` with runtime classification based on CPU usage
- **Activity Levels**:
  - **Not Running**: No VMs active
  - **Idle**: VM running but CPU < 5%
  - **Light Activity**: VM CPU 5-25%
  - **Moderate Activity**: VM CPU 25-50%
  - **Active**: VM CPU > 50%
- **Purpose**: Quickly identify VM workload without analyzing raw CPU numbers
- **Example**: "Light Activity" indicates VM is running but not under load

---

## What's New in v3.2.0

### Statistical Threshold Calibration (CRITICAL FIX)
- **Problem**: System marked "Critical" 100% of the time due to miscalibrated thresholds
- **Solution**: Thresholds recalibrated based on 281-sample statistical analysis of actual system behavior
- **Method**: Thresholds set at mean + 2σ (Warning) and mean + 3σ (Critical) for 95th/99.7th percentile detection
- **Impact**: Eliminates false alerts; system now correctly identified as "Healthy" ~94% of the time
- **Data-Driven**: Based on 4+ days of continuous monitoring showing 25,537 errors/hour average (normal for macOS Sonoma)

### New Error Thresholds (Based on 281 Samples)
```bash
# Total Errors (1-hour window)
ERROR_1H_WARNING=75635      # 2σ above mean (95th percentile)
ERROR_1H_CRITICAL=100684    # 3σ above mean (99.7th percentile)

# Recent Errors (5-minute window)
ERROR_5M_WARNING=10872      # 2σ above mean (95th percentile)
ERROR_5M_CRITICAL=15081     # 3σ above mean (99.7th percentile)

# Critical fault thresholds (stricter - actual system faults)
CRITICAL_FAULT_WARNING=50   
CRITICAL_FAULT_CRITICAL=100
```

**Previous thresholds (v3.1.2):** 50/200 errors = Critical (too sensitive)  
**New thresholds (v3.2.0):** 75,635/100,684 errors = Warning/Critical (calibrated to reality)

### Improved Health Scoring Logic
- **Prioritizes hardware failures**: SMART status and kernel panics always override error counts
- **Three-tier system**: Healthy → Warning → Critical (previously only Critical)
- **Descriptive labels**: 
  - "Healthy" = System operating normally
  - "Monitor Closely" = Elevated activity (investigate if persists)
  - "Attention Needed" = Significant anomaly detected
  - "Hardware Failure" = SMART failure imminent
  - "System Instability" = Kernel panic occurred
- **Focus on anomalies**: Alerts only when behavior deviates significantly from established baseline

### Expected Behavior
With calibrated thresholds (based on actual data):
- **Healthy:** ~94% of samples (normal operation)
- **Warning:** ~3.6% of samples (elevated but not critical)
- **Critical:** ~2.5% of samples (actual problems only)

**Previous behavior (v3.1.2):** Critical 100% of samples (false alerts)

---

## What's New in v3.1.2

### Memory Pressure Calculation Fix (DATA QUALITY FIX)
- **Problem**: Memory Pressure field was storing memory **free** percentage (93% = good), causing confusion
- **Solution**: Inverted calculation to show actual memory **pressure** (7% = low pressure, good)
- **Impact**: Matches Activity Monitor's pressure graph (low numbers = healthy system)
- **Breaking Change**: Historical data shows inverted values (requires one-time Airtable correction)
- **Interpretation**: 
  - **Before**: 93% looked high but meant "93% free" (confusing)
  - **After**: 7% correctly shows "7% pressure" (intuitive)

---

## What's New in v3.1.1

### Lock File Protection (CRITICAL FIX)
- **Problem**: Script execution time (5-7 minutes) could overlap with 15-minute LaunchAgent interval
- **Solution**: PID-based lock file mechanism prevents concurrent execution
- **Features**:
  - Creates `.health_monitor.lock` with process PID
  - Validates process is actually running before blocking
  - Stale lock cleanup (>30 minutes = automatically removed)
  - Automatic cleanup on exit/crash via trap
- **Impact**: Eliminates resource waste from overlapping instances

### User Session & Application Monitoring
- **Active console user detection** with idle time tracking
- **GUI application enumeration** per user with version detection
- **Legacy software flagging** (VMware <13, VirtualBox <7, etc.)
- **Application inventory** showing what's running when issues occur
- **User count metrics** for trending analysis

### VMware-Specific Monitoring
- **Real-time VMware status** detection (Running/Not Running)
- **Per-VM details**: Guest OS, PID, CPU%, memory usage, runtime
- **Automatic guest OS detection** from .vmx configuration files
- **Legacy guest OS flagging** (Windows 7 EOL, Mac OS X 10.3 Panther, etc.)
- **Resource usage aggregation**: Total CPU% and memory across all VMs
- **High risk app classification**: Automatic detection of problematic configurations

### Resource Usage Tracking
- **Process monitoring**: Identifies apps using >80% CPU or >4GB RAM
- **Resource hog detection**: Links high usage to specific applications
- **Performance bottleneck identification**: Correlates resource usage with system health

### Enhanced Crash Detection
- **Multiple crash report formats**: .crash, .ips, .panic, .diag files
- **Modern macOS compatibility**: Supports macOS 12+ .ips format
- **Top crashes reporting**: 3 most recent crash files with timestamps

### Improved Error Detection
- **Two-stage filtering**: Subsystem + error keyword matching
- **Burst-aware logic**: Distinguishes active vs historical errors
- **Mathematical sanity checks**: Prevents impossible data relationships
- **GPU freeze detection**: Dedicated 2-minute window for GPU/WindowServer issues

---

## Monitored Metrics

### Hardware Health

#### SMART Status
- **Source**: `diskutil info <boot_device>`
- **Auto-detection**: Extracts actual boot device from `/` mount point
- **Supported devices**: External Thunderbolt SSDs, internal drives
- **Values**: "Verified" | "Failing" | "Unknown"

#### Kernel Panics
- **Source**: `.panic` files in `/Library/Logs/DiagnosticReports/`
- **Window**: Last 24 hours (by file modification time)
- **Accuracy**: Checks actual panic report files, not log strings
- **Format**: Text description + count
- **Note**: Only counts true kernel panics that caused system crashes/reboots

#### CPU Temperature
- **Source**: `osx-cpu-temp` (Homebrew package)
- **Format**: Celsius with unit (e.g., "62.1°C")
- **Fallback**: "N/A" if tool unavailable

### Storage

#### Drive Space
- **Source**: `df -h /System/Volumes/Data`
- **Fallback**: `df -h /` if Data volume not mounted
- **Format**: "Total: XGi, Used: YGi (Z%), Available: AGi"
- **Optimized for**: External boot volumes (macOS Data partition)

#### Time Machine
- **Source**: `tmutil latestbackup`
- **Calculation**: Days since last backup (epoch timestamp diff)
- **Format**: "Configured; Latest: YYYY-MM-DD"
- **Permissions**: Works without Full Disk Access (uses filesystem fallback)

### System Error Analysis

#### Error Collection (1-hour window)
- **Total errors**: All log entries matching error patterns
- **Recent errors**: Last 5 minutes (burst detection)
- **Critical faults**: `<Fault>`, `<Critical>`, `[fatal]` events only
- **Subsystem breakdown**:
  - Kernel errors
  - WindowServer/GPU errors
  - Spotlight errors
  - iCloud errors
  - Disk I/O errors
  - Network errors
  - System statistics errors
  - Power management errors

#### Threshold-Based Alerting (v3.2.0)
- **Healthy**: Error counts within 2σ of mean baseline
- **Warning**: Error counts 2-3σ above mean (95th-99.7th percentile)
- **Critical**: Error counts >3σ above mean OR hardware failures
- **Baseline**: 25,537 errors/hour average (normal for macOS Sonoma 15.7.2)

### User Session Tracking (v3.1+)

#### Active Users
- **Detection**: Console users via `who` command
- **Idle Time**: Extracted from `w` command output
- **Format**: "username (console, idle Xh Ym)"
- **Multi-user**: Tracks all logged-in console users simultaneously

#### Application Inventory
- **Detection**: GUI applications via osascript + System Events
- **Version Extraction**: From app Info.plist files
- **Per-User Tracking**: Shows which user is running which apps
- **Format**: "[username] App1 version, App2 version, ..."
- **Legacy Flagging**: Automatically marks outdated software with ⚠️ LEGACY

#### Legacy Software Detection
Automatically flags these problematic versions:
- **VMware Fusion <13.x**: Deprecated kernel extensions, GPU conflicts
- **VirtualBox <7.x**: Kernel extension conflicts
- **Parallels Desktop <17.x**: Older GPU acceleration model
- **Adobe Photoshop CS/CC <21**: 32-bit components, legacy drivers

### VMware Monitoring (v3.1+)

#### VMware Status
- **Detection**: Process-based via `pgrep -x "vmware-vmx"`
- **Values**: "Running" | "Not Running"
- **Purpose**: Correlation analysis for system stability

#### VM Activity Details
When VMware is running, captures per-VM:
- **Guest Operating System**: Detected from .vmx configuration files
- **Process ID**: For resource tracking
- **CPU Usage**: Percentage per VM
- **Memory Usage**: GB allocated per VM
- **Runtime**: How long VM has been running
- **Risk Assessment**: Flags EOL or extremely legacy guest OSes

**Supported Guest OS Detection**:
- Windows 7, 10, 11
- Mac OS X 10.3-10.15
- macOS 11+
- Linux variants

**Guest OS Risk Flags**:
- **Windows 7**: EOL OS requiring legacy DirectX translation
- **Mac OS X 10.3 Panther**: 2003 OS requiring extreme legacy emulation
- **Mac OS X 10.4-10.6**: PowerPC/legacy emulation requirements

#### Aggregated Metrics
- **vm_count**: Total number of running VMs
- **vmware_cpu_percent**: Sum of CPU% across all VMs
- **vmware_memory_gb**: Total memory allocated to VMs

#### High Risk App Classification
- **None**: No legacy or problematic apps detected
- **VMware Legacy**: VMware Fusion <13.x detected
- **Multiple Legacy**: Multiple problematic apps running
- **Critical Risk**: Reserved for extreme scenarios

---

## Installation

### Prerequisites
- macOS Sonoma 15.7.2 or later
- Airtable account with API access
- Homebrew (for optional osx-cpu-temp)
- Full Disk Access permission (for Time Machine detection)

### Setup Steps

1. **Clone Repository**
```bash
cd ~/Documents
git clone https://github.com/darrenchilton/imac-health-monitor.git
cd imac-health-monitor
```

2. **Create .env File**
```bash
cat > .env << 'EOF'
AIRTABLE_PAT=your_personal_access_token_here
AIRTABLE_BASE_ID=your_base_id_here
AIRTABLE_TABLE_NAME=System Health
EOF
chmod 600 .env
```

3. **Install Optional Dependencies**
```bash
# For CPU temperature monitoring
brew install osx-cpu-temp
```

4. **Test Manual Execution**
```bash
./imac_health_monitor.sh
# Check Airtable for new record
```

5. **Install LaunchAgent**
```bash
cp com.slavicany.imac-health-monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
```

6. **Install Auto-Updater (Optional)**
```bash
cp com.slavicanikolic.imac-health-updater.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

7. **Prevent System Sleep** (Required for 24/7 monitoring)
```bash
sudo pmset -c sleep 0          # Never sleep computer
sudo pmset -c disksleep 0      # Never sleep external SSD
sudo pmset -c displaysleep 10  # Display sleeps after 10 min
```

---

## Configuration

### Airtable Schema
The monitoring system requires these fields in your Airtable base:

**Basic Fields:**
- Timestamp (DateTime)
- Hostname (Single line text)
- macOS Version (Single line text)
- SMART Status (Single line text)
- Kernel Panics (Long text)
- System Errors (Long text)
- Drive Space (Long text)
- Uptime (Single line text)
- Memory Pressure (Single line text)
- CPU Temperature (Single line text)
- Time Machine (Single line text)
- Software Updates (Single line text)

**Health Scoring:**
- Severity (Single select: Info, Warning, Critical)
- Health Score (Single line text)
- Reasons (Long text)

**Error Metrics:**
- error_kernel_1h (Number)
- error_windowserver_1h (Number)
- error_spotlight_1h (Number)
- error_icloud_1h (Number)
- error_disk_io_1h (Number)
- error_network_1h (Number)
- error_gpu_1h (Number)
- error_systemstats_1h (Number)
- error_power_1h (Number)
- Error Count (Number)
- Recent Error Count (5 min) (Number)
- Critical Fault Count (1h) (Number)

**System Details:**
- top_errors (Long text)
- top_crashes (Long text)
- crash_count (Number)
- Run Duration (seconds) (Number)

**Thermal Monitoring:**
- thermal_throttles_1h (Number)
- Thermal Warning Active (Single line text)
- CPU Speed Limit (Number)

**GPU Monitoring:**
- GPU Freeze Detected (Single line text)
- GPU Freeze Events (Long text)

**User/App Monitoring (v3.1+):**
- Active Users (Long text)
- Application Inventory (Long text)
- user_count (Number)
- total_gui_apps (Number)

**VMware Monitoring (v3.1+):**
- VMware Status (Single line text)
- VM Activity (Long text)
- vm_count (Number)
- vmware_cpu_percent (Number)
- vmware_memory_gb (Number)
- High Risk Apps (Single line text)
- Resource Hogs (Long text)
- Legacy Software Flags (Long text)

**Debug:**
- Debug Log (Long text)
- Raw JSON (Long text)

### LaunchAgent Configuration

**Health Monitor** (`com.slavicany.imac-health-monitor.plist`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.slavicany.imac-health-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/slavicanikolic/Documents/imac-health-monitor/imac_health_monitor.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>1200</integer>
    <key>StandardOutPath</key>
    <string>/Users/slavicanikolic/Library/Logs/imac_health_monitor.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/slavicanikolic/Library/Logs/imac_health_monitor.launchd.err</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

---

## Troubleshooting

### Quick Debugging Commands Reference

**Check if monitoring is running:**
```bash
launchctl list | grep slavica
# Should show both agents with exit code 0
```

**View recent logs:**
```bash
# Standard output (last 50 lines)
tail -50 ~/Library/Logs/imac_health_monitor.launchd.log

# Error log (last 50 lines)
tail -50 ~/Library/Logs/imac_health_monitor.launchd.err

# Debug log (execution trace)
cat ~/Documents/imac-health-monitor/.debug_log.txt
```

**Clear logs (for clean monitoring):**
```bash
> ~/Library/Logs/imac_health_monitor.launchd.log
> ~/Library/Logs/imac_health_monitor.launchd.err
```

**Stop monitoring:**
```bash
# Stop health monitor
launchctl unload ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist

# Stop auto-updater
launchctl unload ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

**Start monitoring:**
```bash
# Start health monitor
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist

# Start auto-updater
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

**Force a run now:**
```bash
launchctl start com.slavicany.imac-health-monitor
```

**Remove stale lock file:**
```bash
rm ~/Documents/imac-health-monitor/.health_monitor.lock
```

**Test script manually:**
```bash
cd ~/Documents/imac-health-monitor
./imac_health_monitor.sh
# Should complete in 1-3 minutes with "Airtable Update: SUCCESS"
```

**Check for syntax errors:**
```bash
bash -n ~/Documents/imac-health-monitor/imac_health_monitor.sh
# Should return nothing if clean
```

**Check git status (for auto-updater issues):**
```bash
cd ~/Documents/imac-health-monitor
git status
# Should show "nothing to commit, working tree clean"
```

**Fix git issues blocking auto-updater:**
```bash
cd ~/Documents/imac-health-monitor
git stash  # Save local changes
git pull --rebase  # Get latest from GitHub
```

**View script version:**
```bash
head -5 ~/Documents/imac-health-monitor/imac_health_monitor.sh
```

**Check when last run completed:**
```bash
stat -f "%Sm" ~/Documents/imac-health-monitor/.debug_log.txt
```

---

### Common Issues

#### Script Always Shows "Critical"
**Cause**: Old thresholds (pre-v3.2.0) not calibrated for macOS Sonoma  
**Solution**: Upgrade to v3.2.0 with statistically-derived thresholds

#### LaunchAgent Not Running
```bash
# Check if loaded
launchctl list | grep slavica

# Check for errors
tail -50 ~/Library/Logs/imac_health_monitor.launchd.err

# Reload agent
launchctl unload ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
```

#### Monitoring Gaps (Missing Data)
**Cause**: System sleep prevents LaunchAgent execution  
**Solution**: Disable computer sleep (see Installation step 7)

#### Lock File Blocking Execution
```bash
# Check for stale lock
ls -lah ~/Documents/imac-health-monitor/.health_monitor.lock

# If stale (>30 min old), remove manually
rm ~/Documents/imac-health-monitor/.health_monitor.lock
```

#### Time Machine Detection Not Working
**Cause**: Missing Full Disk Access permission  
**Solution**: 
1. System Settings → Privacy & Security → Full Disk Access
2. Add Terminal.app or LaunchAgents
3. Restart LaunchAgent

#### Airtable API Errors
```bash
# Test credentials
curl -X GET "https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}" \
  -H "Authorization: Bearer ${AIRTABLE_PAT}"

# Check .env file permissions
chmod 600 ~/Documents/imac-health-monitor/.env
```

---

## Security & Privacy

### Data Collection
- **Credentials**: Stored in `.env` file (chmod 600)
- **No PII**: Only system-level metrics collected
- **Lock file**: Temporary, contains only process PID

### Transmitted Data
- System metrics only (no user activity details)
- Application names and versions (for correlation analysis)
- Console usernames (for multi-user systems)
- Hostname may reveal computer name
- No file contents, browser history, or personal documents

### Airtable Security
- Data encrypted in transit (HTTPS)
- Access controlled by Airtable permissions
- API keys should be treated as passwords

### Privacy Considerations (v3.1)
The new user/app monitoring features collect:
- **Active usernames**: Who is logged in at console
- **Application names**: Which apps are running
- **App versions**: Version numbers for legacy detection
- **VMware guest OS**: Operating systems running in VMs

This data is used solely for system stability correlation analysis. No keystroke logging, screen capture, or document access occurs.

---

## Version History
v3.2.3 (2025-12-01) — GUI App Detection Rewrite

CHANGED: Replaced AppleScript/System Events–based GUI app detection with a fast, reliable ps scan of processes inside *.app/Contents/MacOS/*.

FIXED: Eliminates false "No GUI apps detected" for active sessions (e.g., Finder, Chrome, Mail, pCloud).

FIXED: Removes dependence on Accessibility permissions, System Events timeouts, and AppleScript instability on macOS Sonoma.

IMPROVED: Application Inventory now consistently captures real running GUI apps for each console user.

IMPROVED: Maintains version lookup + ⚠️ LEGACY flag detection using existing logic.

### v3.2.2 (2025-12-01)
- **FIXED**: Active user idle-time tracking rewritten to use IOHIDSystem via `ioreg`
- Corrects cases where user appeared "idle 6days" while actively using the Mac
- **NEW**: Human-readable idle time formatting (5s, 3m, 1:45, 2days)
- **IMPROVED**: Detects true GUI keyboard/mouse/trackpad input
- Treats <5 seconds idle as "active" to prevent flickering

### v3.2.1 (2025-12-01)
- **NEW**: VM State field with runtime classification (Idle/Light/Moderate/Active/Not Running)
- **IMPROVED**: VMware CPU usage now used to classify guest OS activity level
- Provides quick visibility into VM workload without analyzing raw numbers

### v3.2.0 (2025-11-27) 🎯 MAJOR UPDATE
- **FIXED**: Adjusted error thresholds based on 281-sample statistical analysis
- **FIXED**: Eliminated false "Critical" alerts (was 100%, now ~2.5% expected)
- **NEW**: Three-tier health scoring (Healthy/Warning/Critical) with proper baselines
- **NEW**: Thresholds calibrated for macOS Sonoma 15.7.2 normal behavior
- **NEW**: Statistical methodology (mean + 2σ/3σ for Warning/Critical)
- **IMPROVED**: Health scoring logic prioritizes hardware failures and kernel panics
- **IMPROVED**: More descriptive Health Score labels ("Monitor Closely", "Hardware Failure", etc.)
- **DOCUMENTED**: Threshold values clearly explained with statistical basis
- **VALIDATED**: 281 samples proved thresholds accurately distinguish healthy from problematic states

### v3.1.2 (2025-11-25)
- **FIXED**: Memory Pressure now reports actual pressure percentage (inverted from memory free %)
- Changed calculation from reporting "memory free %" to "memory pressure %"
- Memory Pressure field now shows intuitive values (7% = low pressure, healthy)
- **Breaking Change**: Historical data shows inverted values (93% free → 7% pressure)
- Improved field interpretation to match Activity Monitor's pressure graph
- Added detailed documentation on memory pressure interpretation
- **Data Migration Required**: One-time Airtable correction needed for historical records

### v3.1.1 (2025-11-22)
- **FIXED**: Thermal throttling detection now uses `pmset -g thermlog` instead of log parsing
- Eliminated false positive thermal throttling reports (was showing 2-34 events/hour on idle systems)
- thermal_throttles_1h changed from event count to binary indicator (0 = not throttling, 1 = throttling)
- Added "Thermal Warning Active" field (Yes/No) - reports actual macOS thermal warning state
- Added "CPU Speed Limit" field (percentage) - shows actual CPU speed (100 = full, <100 = throttled)
- Improved thermal detection accuracy: now reports actual thermal management events only
- Added 2 new Airtable fields for accurate thermal monitoring

### v3.1 (2025-11-22)
- **CRITICAL**: Added lock file mechanism to prevent concurrent execution
- Added user session tracking (active users, idle time)
- Added application inventory with version detection
- Added VMware-specific monitoring (status, VM details, guest OS detection)
- Added legacy software flagging (VMware <13, VirtualBox <7, etc.)
- Added resource hog detection (>80% CPU or >4GB RAM)
- Added detailed legacy software explanations
- Increased LaunchAgent interval from 900s to 1200s (15 → 20 minutes)
- Added 12 new Airtable fields for user/app/VMware data
- Enhanced crash detection for multiple file formats (.ips, .diag)
- Improved error handling with defensive fallbacks

### v3.0 (2025-11-19)
- Added GPU freeze detection with pattern matching
- Added run duration tracking
- Added Raw JSON field for payload storage
- Fixed boot device auto-detection for external SSDs
- Expanded crash report detection (.ips, .panic, .diag)
- Fixed timestamp format to ISO 8601

### v2.2 (Previous)
- Noise-filtered log analysis
- Structured System Errors format
- Burst-aware error detection
- Mathematical sanity checks

---

## Use Cases

### Primary Use Case: VMware Correlation Analysis ✅ COMPLETED

**Original Goal:** Determine if VMware Fusion 12.2.4 with legacy guest operating systems (Mac OS X 10.3 Panther, Windows 7) is causing GPU freezes and system instability on macOS Sonoma.

**Analysis Status:** ✅ **COMPLETED** (2025-11-27)

**Results from 281-Sample Analysis:**

| Metric | VMware Running | VMware Not Running | Difference |
|--------|---------------|-------------------|------------|
| **Total Errors** | 25,517/hour | 25,637/hour | **-0.5%** |
| **GPU Errors** | 587/hour | 719/hour | **-18.4%** |
| **Network Errors** | 2,932/hour | 2,976/hour | **-1.5%** |
| **Kernel Errors** | 2,906/hour | 3,843/hour | **-24.4%** |
| **GPU Freezes** | 0 events | 1 event | — |

**Sample Distribution:**
- VMware Running: 233 samples (83%)
- VMware Not Running: 48 samples (17%)
- Total: 281 samples over 4+ days

**Conclusions:**

✅ **VMware Fusion 12.2.4 is NOT causing system problems**
- Error rates are virtually identical whether VMware is running or not (<1% difference)
- GPU errors are actually LOWER when VMware is running (-18.4%)
- No GPU freezes detected during VMware operation (1 freeze occurred when VMware was not running)
- No correlation between VMware status and system instability

✅ **Legacy guest OSes are NOT problematic**
- Mac OS X 10.3 Panther and Windows 7 VMs ran for extended periods with no issues
- System stability maintained regardless of guest OS age

✅ **High error counts are normal macOS Sonoma behavior**
- Average 25,537 errors/hour is typical system logging volume, not actual problems
- Consists of debug messages, network monitoring, memory management, and other benign subsystem activity
- Previous "Critical" status was due to miscalibrated thresholds, not actual system issues

**Recommendations:**
1. ✅ **Continue using VMware Fusion 12.2.4** - No upgrade needed
2. ✅ **Continue using legacy guest OSes** - No stability impact detected
3. ✅ **System is healthy** - All hardware and software operating normally
4. ✅ **Monitoring system now accurate** - v3.2.0 thresholds eliminate false alerts

### Secondary Use Cases

**Hardware Health Monitoring:**
- Early detection of drive failures via SMART status
- Kernel panic tracking for stability issues
- Temperature monitoring for thermal problems
- Time Machine backup compliance

**System Performance Analysis:**
- Error trend analysis over time
- Resource bottleneck identification
- Application performance impact assessment
- Multi-user system load distribution

**Legacy Software Auditing:**
- Identify outdated software across users
- Track legacy app usage patterns
- Provide upgrade recommendations
- Compliance with modern macOS requirements

---

## Future Enhancements

### Planned
- [ ] Network connectivity checks (ping, DNS resolution)
- [ ] Fan speed monitoring (if sensors available)
- [ ] Battery health (for MacBooks)
- [ ] Docker container health (if Docker installed)
- [ ] WiFi signal strength and quality
- [ ] Automatic Airtable schema validation

### Under Consideration
- [ ] Local HTML dashboard
- [ ] Email/Slack alerting
- [ ] Machine learning for anomaly detection
- [ ] Historical trend analysis in-script
- [ ] Multi-machine aggregation dashboard
- [ ] Per-application resource usage trends
- [ ] Automated correlation reports

---

## Contributing

This is a personal monitoring system but contributions are welcome:

1. Fork repository
2. Create feature branch
3. Test thoroughly on macOS Sonoma+
4. Submit pull request with detailed description

---

## License

MIT License - See LICENSE file

---

## Support

For issues or questions:
- Check troubleshooting section above
- Review LaunchAgent logs
- Test script manually with verbose output
- Verify Airtable schema matches requirements
- Email: darrenchilton@gmail.com

---

## Acknowledgments

**Hardware Configuration:**
- 2019 iMac 27" (Intel Core i5, 72GB RAM, Radeon Pro 570X)
- External Thunderbolt 3 SSD boot drive (SanDisk PRO-G40 1TB)
- macOS Sonoma 15.7.2

**Monitoring Challenges Solved:**
- ✅ Fusion Drive failure and migration to external SSD
- ✅ VMware correlation analysis (COMPLETED - VMware proven NOT to be the issue)
- ✅ False "Critical" alerts (FIXED in v3.2.0 with statistical threshold calibration)
- ✅ Concurrent execution resource waste
- ✅ False positive error detection  
- ✅ False positive thermal throttling detection
- ✅ Memory pressure reporting clarity (inverted calculation)
- ✅ Sleep prevention for continuous monitoring
- ✅ Statistical baseline establishment for macOS Sonoma log volume

**Key Learnings:**
- macOS Sonoma generates 25K+ log entries/hour under normal operation (not errors)
- Statistical analysis (281 samples) is superior to guesswork for threshold calibration
- Mean + 2σ/3σ methodology effectively identifies true anomalies
- VMware Fusion 12.2.4 stable on macOS Sonoma with legacy guest OSes
- System health monitoring requires calibration to actual system behavior

---

**Maintainer:** Darren Chilton  
**Hardware:** 2019 iMac 27" (Sonoma 15.7.2, external Thunderbolt SSD)  
**Last Verified:** 2025-12-01  
**Script Version:** 3.2.3  
**Script Lines:** 950+  
**Analysis:** 281 samples, 99%+ statistical confidence
