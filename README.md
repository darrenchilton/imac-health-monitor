# iMac Health Monitor - Technical Documentation

**Version:** 3.1.1  
**Last Updated:** 2025-11-22  
**Platform:** macOS Sonoma 15.7.2+  
**Target Hardware:** 2019 iMac 27" with external Thunderbolt 3 boot drive

---

## System Architecture

### Overview
Bash-based health monitoring system that collects system metrics every 20 minutes and transmits them to Airtable for centralized tracking and analysis. Optimized for iMacs running from external SSDs with automatic boot device detection. Version 3.1 adds user session tracking, application monitoring, and VMware correlation analysis capabilities with lock file protection to prevent concurrent execution.

### Components
```
/Users/slavicanikolic/Documents/imac-health-monitor/
├── imac_health_monitor.sh          # Main monitoring script (v3.1)
├── bin/
│   └── run_imac_health_monitor.sh  # LaunchAgent wrapper
├── .env                             # Environment configuration
├── .health_monitor.lock             # PID-based lock file (created during execution)
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
6. **Health Analysis** (threshold-based scoring with burst detection)
7. **JSON Payload Construction** (jq with 40+ fields)
8. **Airtable Transmission** (curl POST)
9. **Lock File Cleanup** (automatic via trap)
10. **Logging** (stdout/stderr to LaunchAgent logs)

---

## What's New in v3.1

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

### User Session Tracking (NEW in v3.1)

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

### VMware Monitoring (NEW in v3.1)

#### VMware Status
- **Detection**: Process-based via `pgrep -x "vmware-vmx"`
- **Values**: "Running" | "Not Running"
- **Purpose**: Quick binary indicator for correlation analysis

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

#### Legacy Software Flags (Detailed Explanations)
Provides detailed context for each flagged application:
```
VMware Fusion 12.2.4: Pre-13.x uses deprecated kernel extensions, 
known GPU conflicts with Sonoma, incompatible with Metal rendering 
pipeline. Running 2 VM(s) with legacy guest OSes. UPGRADE 
RECOMMENDED to VMware Fusion 13.5+
```

### Resource Usage (NEW in v3.1)

#### Resource Hogs
Identifies and reports processes consuming:
- **High CPU**: >80% CPU usage
- **High Memory**: >4GB RAM usage

**Format**: 
```
processname (PID): CPU X.X%, RAM Y.YGB, User: username
```

**Purpose**: Correlate resource usage with system instability

### System Logs (Error Analysis)

#### Collection Windows
- **1-hour window**: Total error context (max 5-minute timeout)
- **5-minute window**: Recent activity detection
- **2-minute window**: GPU freeze detection

#### Error Categories (per hour)
All error categories use two-stage filtering:
1. First filter: Identifies relevant subsystem
2. Second filter: Requires actual error keywords

```bash
error_kernel_1h          # Kernel-level errors
error_windowserver_1h    # Display server errors
error_spotlight_1h       # Spotlight/metadata errors
error_icloud_1h          # Cloud sync errors
error_disk_io_1h         # Disk I/O errors
error_network_1h         # Network/DNS errors
error_gpu_1h             # GPU/graphics errors
error_systemstats_1h     # System statistics errors
error_power_1h           # Power management errors
```

#### System Errors Field Format
```
Log Activity: <total> errors (<recent> recent, <critical> critical)
Example: Log Activity: 50662 errors (7781 recent, 1611 critical)
```

#### Top Errors
- Aggregates most frequent error messages
- Deduplicates and ranks by occurrence
- Returns top 3 patterns

### GPU Freeze Detection

#### Detection Patterns
```bash
- "GPU Reset"
- "GPU Hang"  
- "AMDRadeon"
- "AGC::"
- "WindowServer.*stalled"
- "WindowServer.*overload"
- "IOSurface"
- "Metal.*timeout"
- "timed out waiting for"
- "GPU Debug Info"
```

#### Fields
- **GPU Freeze Detected**: "Yes" | "No"
- **GPU Freeze Events**: Detailed event counts per pattern

### Crash Reports

#### Supported Types
- `.crash` - Legacy format (pre-macOS 12)
- `.ips` - Modern format (macOS 12+, Incident Problem Summary)
- `.panic` - Kernel panic reports
- `.diag` - Diagnostic reports

#### Fields
- **crash_count**: Total count across all types
- **top_crashes**: 3 most recent filenames (comma-separated)

### System Info

#### Memory Pressure
- **Source**: `memory_pressure` command
- **Metric**: System-wide memory free percentage
- **Format**: Percentage string (e.g., "93%")

#### Uptime
- **Source**: `uptime` command
- **Format**: Time duration string

#### Software Updates
- **Source**: `softwareupdate --list`
- **Timeout**: 15 seconds (prevents hanging)
- **Values**: "Up to Date" | "Unknown"

### Performance Metrics

#### Run Duration
- **Measurement**: Script execution time via `$SECONDS`
- **Type**: Integer (seconds)
- **Purpose**: Track monitoring overhead and detect slow runs
- **Typical**: 6-7 minutes (360-420 seconds)

#### Thermal Monitoring (IMPROVED in v3.1.1)
- **Detection Method**: Uses `pmset -g thermlog` for accurate thermal state (not log parsing)
- **thermal_throttles_1h**: Binary indicator (0 = not throttling, 1 = throttling detected)
- **Thermal Warning Active**: "Yes" or "No" - has macOS recorded a thermal warning?
- **CPU Speed Limit**: Percentage (100 = full speed, <100 = throttled)
- **Purpose**: Detect actual thermal management events, not log noise
- **Note**: v3.1 used log parsing which produced false positives (2-34 events/hour on idle systems). v3.1.1 uses actual thermal status for accuracy.

---

## Health Scoring Algorithm

### Health Score Levels
- **"Healthy"**: System operating normally
- **"Attention Needed"**: Elevated errors or hardware issues
- **"Critical"**: Available but not currently used

### Severity Levels
- **"Info"**: Normal operation
- **"Warning"**: Elevated activity, monitoring
- **"Critical"**: Hardware failure or sustained error storms

### Threshold Logic

```bash
if recent_5m > 50:
    severity = "Critical"
    health_score = "Attention Needed"
    
elif recent_5m > 20:
    severity = "Warning"
    health_score = "Attention Needed"
    
elif errors_1h > 200 AND recent_5m < 10:
    severity = "Info"
    health_score = "Healthy"
    # Historical errors but currently resolved
    
elif critical_1h > 10:
    severity = "Warning"
    health_score = "Attention Needed"
    
else:
    severity = "Info"
    health_score = "Healthy"
```

### Hardware Override Rules
```bash
# SMART failure always critical
if smart_status != "Verified" AND smart_status != "Unknown":
    severity = "Critical"
    health_score = "Attention Needed"

# Kernel panic always critical
if kernel_panics > 0:
    severity = "Critical"
    health_score = "Attention Needed"

# Stale backups warning
if tm_age_days > 7:
    severity = "Warning"
    health_score = "Attention Needed"
```

---

## Airtable Schema Requirements

### Table: "System Health"

#### Required Fields - Core Monitoring

**Text Fields (singleLineText):**
- Hostname
- macOS Version
- SMART Status
- Uptime
- Memory Pressure
- CPU Temperature

**Long Text Fields (multilineText):**
- Kernel Panics
- System Errors
- Drive Space
- Time Machine
- Software Updates
- Reasons
- top_errors
- top_crashes
- GPU Freeze Events
- Raw JSON

**Date/Time Fields:**
- Timestamp (dateTime, ISO 8601 format)

**Single Select Fields:**
- Severity: Options = ["Info", "Warning", "Critical"]
- Health Score: Options = ["Healthy", "Attention Needed", "Critical"]
- GPU Freeze Detected: Options = ["Yes", "No"]

**Number Fields (Core):**
- Run Duration (seconds) - precision: 0
- error_kernel_1h - precision: 1
- error_windowserver_1h - precision: 1
- error_spotlight_1h - precision: 1
- error_icloud_1h - precision: 1
- error_disk_io_1h - precision: 1
- error_network_1h - precision: 1
- error_gpu_1h - precision: 1
- error_systemstats_1h - precision: 1
- error_power_1h - precision: 1
- crash_count - precision: 1
- thermal_throttles_1h - precision: 1 (Note: v3.1.1+ uses binary 0/1, not event count)
- fan_max_events_1h - precision: 1

#### Required Fields - User/App Monitoring (v3.1)

**Long Text Fields (multilineText):**
- Active Users
- Application Inventory
- VM Activity
- Resource Hogs
- Legacy Software Flags

**Single Select Fields:**
- VMware Status: Options = ["Not Running", "Running"]
- High Risk Apps: Options = ["None", "VMware Legacy", "Multiple Legacy", "Critical Risk"]

**Number Fields (User/App):**
- user_count - precision: 0 (integer)
- total_gui_apps - precision: 0 (integer)
- vm_count - precision: 0 (integer)
- vmware_cpu_percent - precision: 1 (decimal)
- vmware_memory_gb - precision: 2 (decimals)

#### Required Fields - Thermal Monitoring (v3.1.1)

**Single Select Fields:**
- Thermal Warning Active: Options = ["No", "Yes"]
  - Description: Whether macOS has recorded a thermal warning level

**Number Fields (Thermal):**
- CPU Speed Limit - precision: 0 (integer)
  - Description: CPU speed as percentage (100 = full speed, <100 = throttled)

#### Formula Fields (Auto-calculated)
These are READ-ONLY and calculated from base data:
- Name (concatenates hostname, health score, timestamp)
- CPU Temperature (°F) - converts from Celsius
- Date - extracts date from timestamp
- Disk Used % - extracts percentage from Drive Space
- CPU Temp (°C) - extracts numeric value from CPU Temperature
- Error Count - extracts total from System Errors
- Recent Error Count (5 min) - extracts recent from System Errors
- TM Age (days) - calculates age from Time Machine
- Critical Fault Count (1h) - extracts critical from System Errors
- Error Object - JSON structure from System Errors

---

## Installation & Configuration

### Prerequisites
```bash
# Required
brew install jq              # JSON processing
brew install coreutils       # GNU timeout (optional)
brew install osx-cpu-temp    # CPU temperature monitoring

# Permissions
# No Full Disk Access required for basic operation
# Grant to Terminal for enhanced Time Machine monitoring
```

### Initial Setup

1. **Clone Repository**
```bash
git clone <repository-url>
cd /Users/slavicanikolic/Documents/imac-health-monitor
chmod +x imac_health_monitor.sh
```

2. **Create .env File**
```bash
cat > .env << 'EOF'
AIRTABLE_API_KEY=patXXXXXXXXXXXXXX
AIRTABLE_BASE_ID=appXXXXXXXXXXXX
AIRTABLE_TABLE_NAME="System Health"
EOF

chmod 600 .env  # Secure credentials
```

3. **Create Wrapper Script**
```bash
mkdir -p bin
cat > bin/run_imac_health_monitor.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
./imac_health_monitor.sh
exit 0
EOF
chmod +x bin/run_imac_health_monitor.sh
```

4. **Test Manually**
```bash
/Users/slavicanikolic/Documents/imac-health-monitor/imac_health_monitor.sh
# Should output: "Airtable Update: SUCCESS"
# Takes 6-7 minutes to complete
```

### LaunchAgent Configuration

**File:** `~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.slavicany.imac-health-monitor</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/slavicanikolic/Documents/imac-health-monitor/bin/run_imac_health_monitor.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/slavicanikolic/Documents/imac-health-monitor</string>

    <!-- v3.1: Increased from 900 to 1200 seconds (20 minutes) -->
    <!-- Prevents overlap with 6-7 minute execution time -->
    <key>StartInterval</key>
    <integer>1200</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/slavicanikolic/Library/Logs/imac_health_monitor.launchd.log</string>
    
    <key>StandardErrorPath</key>
    <string>/Users/slavicanikolic/Library/Logs/imac_health_monitor.launchd.err</string>

    <key>Disabled</key>
    <false/>
</dict>
</plist>
```

**Load LaunchAgent:**
```bash
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
launchctl start com.slavicany.imac-health-monitor
```

**Verify:**
```bash
launchctl list | grep slavica
# Should show exit code 0, not 128
```

---

## Auto-Updater (Optional)

Automatically syncs script changes from GitHub repository.

**File:** `~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist`

**Behavior:**
- Runs `git pull --rebase` periodically
- Fails gracefully if local changes exist
- Requires clean git state to succeed

**Management:**
```bash
# Disable during active development
launchctl unload ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist

# Re-enable after pushing changes
launchctl load ~/Library/LaunchAgents/com.slavicanikolic.imac-health-updater.plist
```

---

## Troubleshooting

### Concurrent Execution Issues (v3.1)

**Symptom:** Multiple script instances running simultaneously

**Check:**
```bash
ps aux | grep imac_health_monitor | grep -v grep
# Should show only ONE instance or ZERO instances
```

**Cause:** Race condition or LaunchAgent interval too short

**Resolution:**
```bash
# Kill all instances
pkill -f "imac_health_monitor.sh"

# Remove stuck lock file
rm -f ~/Documents/imac-health-monitor/.health_monitor.lock

# Verify LaunchAgent interval is 1200 seconds
grep -A 2 "StartInterval" ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
# Should show: <integer>1200</integer>

# Reload LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
```

### Lock File Not Working

**Symptom:** Multiple instances despite lock file code

**Check lock file:**
```bash
ls -la ~/Documents/imac-health-monitor/.health_monitor.lock
cat ~/Documents/imac-health-monitor/.health_monitor.lock  # Should show a PID
```

**Verify lock code:**
```bash
head -40 ~/Documents/imac-health-monitor/imac_health_monitor.sh | grep "LOCK FILE"
# Should show: "# LOCK FILE MECHANISM - Prevent concurrent execution"
```

**Manual test:**
```bash
cd ~/Documents/imac-health-monitor
./imac_health_monitor.sh &
sleep 2
./imac_health_monitor.sh  # Should print: "Another instance already running"
```

### LaunchAgent Not Running (Exit Code 128)

**Check error log:**
```bash
tail -50 ~/Library/Logs/imac_health_monitor.launchd.err
```

**Common causes:**
1. Wrapper script doesn't exist or isn't executable
2. Git repository has uncommitted changes (blocks auto-updater)
3. Script path in plist is incorrect
4. Missing jq binary

**Resolution:**
```bash
# Ensure wrapper exists
ls -la /Users/slavicanikolic/Documents/imac-health-monitor/bin/run_imac_health_monitor.sh

# Commit any changes
cd /Users/slavicanikolic/Documents/imac-health-monitor
git add .
git commit -m "Update"

# Reload LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
launchctl load ~/Library/LaunchAgents/com.slavicany.imac-health-monitor.plist
```

### Airtable Update Failed

**Check field types:**
- All text fields must use `--arg` in jq
- All number fields must use `--argjson` in jq
- Single select fields must exactly match option names

**Verify with schema fetch:**
```bash
curl "https://api.airtable.com/v0/meta/bases/${AIRTABLE_BASE_ID}/tables" \
  -H "Authorization: Bearer ${AIRTABLE_API_KEY}" | jq '.'
```

**Common issues:**
- Field name typo or case mismatch
- Single select value not in options list
- Number field receiving text data
- Missing required fields

### Wrong Drive Being Monitored

**Symptom:** Drive space shows incorrect data

**Cause:** Boot device auto-detection failed

**Manual override:**
```bash
# Check actual boot device
diskutil info / | grep "Device Node"

# Update script if needed (line ~67)
boot_device="disk2"  # Force specific device
```

### Missing Crash Reports

**Symptom:** `top_crashes` always empty

**Check for crash files:**
```bash
ls -la ~/Library/Logs/DiagnosticReports/
```

Modern macOS uses `.ips` files, not `.crash` files. The script now checks both.

### User/App Monitoring Not Working (v3.1)

**Symptom:** New fields empty in Airtable

**Check fields exist:**
```bash
# Verify Airtable has all 12 new fields
# See Airtable Schema section above
```

**Test app detection:**
```bash
cd ~/Documents/imac-health-monitor
osascript -e 'tell application "System Events" to get name of every process whose background only is false'
# Should list your running GUI apps
```

**Test VMware detection:**
```bash
pgrep -x "vmware-vmx"
# Should return PID if VMware running, empty if not
```

**Check script has new functions:**
```bash
grep -n "get_active_users" ~/Documents/imac-health-monitor/imac_health_monitor.sh
# Should show line number where function exists
```

---

## Performance Characteristics

### Execution Time
- **Typical**: 6-7 minutes (360-420 seconds)
- **Breakdown**:
  - Log collection (1h + 5m + 2m windows): ~4-5 minutes
  - GPU freeze detection (2-minute log scan): ~30-60 seconds
  - User/app enumeration: ~15-30 seconds
  - SMART status check: ~5 seconds
  - Other metrics collection: ~10-20 seconds
  - Airtable transmission: ~1-2 seconds
- **Factors**: Log volume, system load, network latency, number of running apps
- **Monitored via**: Run Duration field (in seconds)

**Note**: The 6-7 minute execution time is primarily due to macOS log collection operations which can be slow when processing large log volumes (40,000+ errors/hour). This is expected behavior and does not impact system responsiveness.

### System Impact
- **CPU**: Negligible (<1% average, brief spikes during collection)
- **Memory**: ~50-100MB during execution
- **Network**: Single HTTPS POST (~10-15KB payload)
- **Disk I/O**: Read-only log access

### Scalability
- **Logs**: Handles 100,000+ errors/hour without degradation
- **Airtable**: No rate limiting issues at 20-minute intervals
- **Storage**: Log data not persisted locally
- **Users**: Supports multiple simultaneous console users
- **Applications**: No limit on number of running apps tracked

### Resource Usage Improvements (v3.1)
**Before (v3.0 with concurrent execution bug):**
- Multiple instances: 3-4 simultaneously
- RAM usage: 1.6GB+ total
- CPU usage: 9%+ sustained

**After (v3.1 with lock file protection):**
- Single instance only
- RAM usage: 50-100MB
- CPU usage: <2% average
- No resource waste from overlapping instances

---

## Data Retention & Privacy

### Local Storage
- **Logs**: LaunchAgent logs rotate automatically by macOS
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

### Primary Use Case: VMware Correlation Analysis (ONGOING)
The v3.1 monitoring additions enable analysis of whether VMware Fusion 12.2.4 with legacy guest operating systems (Mac OS X 10.3 Panther, Windows 7) is causing GPU freezes and system instability on macOS Sonoma.

**Current Status: Data Collection Phase**
- **Goal**: Collect 2-3 weeks of data with regular VMware usage
- **Progress**: Insufficient data collected so far (VMware running in <10% of samples)
- **Needed**: More samples with VMware actively running VMs to establish correlation
- **Timeline**: Continue monitoring before drawing conclusions

**Analysis Workflow:**
1. **Collect Data** (2-3 weeks): System automatically records VMware status, running VMs, and GPU errors every 20 minutes
2. **Minimum Sample Size**: Need at least 30-50 samples with VMware running VMs for statistical significance
3. **Create Airtable Views**: Filter by VMware Status = "Running" vs "Not Running"
4. **Compare Metrics**: Analyze error_gpu_1h, GPU Freeze Detected, and Health Score
5. **Identify Correlation**: Determine if GPU issues correlate with VMware usage
6. **Make Decision**: Upgrade to VMware 13.5+, migrate to UTM, or investigate other causes

**Expected Insights (After Sufficient Data Collection):**
- GPU error rate with VMware running vs. not running
- Which specific VMs (Mac 10.3 vs Windows 7) cause more problems
- Resource usage patterns when VMs are active  
- Whether migration to modern virtualization is justified

**Note:** Early data (22 samples with only 2 VMware running) is insufficient to draw conclusions. System shows high error rates (19,000+/hour) regardless of VMware status, but this may be due to lack of VMware usage in samples. Continue data collection during periods of active VM usage.

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
- Fusion Drive failure and migration to external SSD
- GPU freeze correlation with legacy virtualization software (ongoing data collection)
- Concurrent execution resource waste
- False positive error detection  
- False positive thermal throttling detection
- Legacy guest OS stability issues

---

**Maintainer:** Darren Chilton  
**Hardware:** 2019 iMac 27" (Sonoma 15.7.2, external Thunderbolt SSD)  
**Last Verified:** 2025-11-22  
**Script Version:** 3.1.1  
**Script Lines:** 770+
