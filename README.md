# iMac Health Monitor - Technical Documentation
**Version:** 3.2.4  

**Last Updated:** 2025-12-06  

**Platform:** macOS Sonoma 15.7.2+

**Target Hardware:** 2019 iMac 27" with external Thunderbolt 3 boot drive

---

## System Architecture

### Overview
Bash-based health monitoring system that collects system metrics every 20 minutes and transmits them to Airtable for centralized tracking and analysis. Optimized for iMacs running from external SSDs with automatic boot device detection. Version 3.2 implements statistically-derived error thresholds based on 281-sample analysis, eliminating false "Critical" alerts and providing accurate health status reporting.

### Components
```
/Users/slavicanikolic/Documents/imac-health-monitor/
├── imac_health_monitor.sh          # Main monitoring script (v3.2.4)
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
6. **Health Analysis** (statistically-calibrated threshold-based scoring)
7. **JSON Payload Construction** (jq with 40+ fields)
8. **Airtable Transmission** (curl POST)
9. **Lock File Cleanup** (automatic via trap)
10. **Logging** (stdout/stderr to LaunchAgent logs)

---

## What's New in v3.2.4

### Reachability & Remote Access Diagnostics

- **NEW:** Live reachability checks for remote access:
  - `sshd_running` / `ssh_port_listening`
  - `screensharing_running` / `vnc_port_listening`
  - `tailscale_cli_present` / `tailscale_peer_reachable`
- **NEW:** `remote_access_artifacts` and `remote_access_artifacts_count` fields:
  - Detect AnyDesk / Splashtop processes, apps, preferences, LaunchAgents/Daemons.
  - Make it easy to see if remote access tools exist even when they are not actively running.
- **Purpose:** Correlate “can’t reach the iMac” events with actual SSH / Screen Sharing / Tailscale state and residual remote access tooling.

### Unclassified Error Attribution (Evening Spike Forensics)

- **NEW:** `unclassified_top_errors` field:
  - Shows the **top 1–3 error patterns** from the last hour that are **not** attributed to:
    - kernel, WindowServer/GPU, Spotlight, iCloud/CloudKit, disk I/O, network, systemstats, or powerd.
- **Why:** Evening 7–10 PM error spikes showed `Error Count` far larger than the sum of tracked `error_*_1h` buckets.
- **Impact:** Makes it possible to see which macOS daemons/frameworks are responsible for the “mystery” 60–95% of error volume during spikes, without changing any thresholds or scoring logic.


## What's New in v3.2.3

### System Modifications Log (DOCUMENTATION ENHANCEMENT)
- **Added**: New "System Modifications Log" section to track all debugging actions and configuration changes
- **Purpose**: Document troubleshooting investigations, root cause analysis, and system changes over time
- **Format**: Structured entries with Issue → Investigation → Changes → Evidence → Testing protocol
- **First Entry**: Messages.app wake freeze investigation (2025-12-02)
  - Identified CoreAudio resume operations blocking WindowServer during wake from sleep
  - Disabled Messages notification sounds to prevent audio stream resume during wake
  - Added comprehensive testing protocol with diagnostic commands

### Messages Wake Freeze Fix
- **Problem**: GUI freezing after wake from sleep (Terminal still functional = WindowServer hang)
- **Root Cause**: Messages.app attempting CoreAudio audio stream resume during wake
- **Solution**: Disabled Messages notification sounds (Settings → General → "Play sound effects")
- **Context**: Known macOS Sonoma bug with external Thunderbolt 3 boot drives
- **Status**: Testing in progress (requires 5-10+ successful wake cycles for verification)

### Documentation Improvements
- Added detailed testing protocol for wake freeze troubleshooting
- Added diagnostic log commands for future debugging
- Updated version to 3.2.3 and last updated date to 2025-12-02
- Improved header formatting for readability in both markdown and plain text

### Spotlight / PDF Indexing Storm Freeze
- **Problem**: System became unresponsive again around ~08:30 AM; SSH and Screen Sharing unreachable; forced shutdown required.
- **Evidence**:
  - Health Monitor runs continued through **08:07 AM**, then a **~4.5 hour gap** until **12:37 PM** (post-reboot), matching the unresponsive window.
  - Pre-freeze metrics showed a dominant Spotlight spike:
    - **07:20 AM baseline**: Error Count ~45,171/hr; Recent 5-min ~2,248; **error_spotlight_1h ~138**.
    - **07:43 AM spike**: Error Count ~81,884/hr; Recent 5-min ~4,061; **error_spotlight_1h ~3,401**; Critical Fault Count 1; no thermal throttles.
    - **08:07 AM sustained**: Error Count ~78,168/hr; Recent 5-min ~7,967; **error_spotlight_1h ~3,430**; Critical Fault Count 1; no thermal throttles.
- **Root Cause (most likely)**: Spotlight/QuickLook PDF indexing storm (mds/mdworker/CGPDFService), likely triggered by large PDF caches (TurboTax formsets and other Library caches), starving system resources.
- **Change Implemented**:
  - Disabled Spotlight indexing on Data volume:
    ```bash
    sudo mdutil -i off /System/Volumes/Data
    sudo mdutil -s /System/Volumes/Data
    ```
  - **Decision**: Leave indexing **OFF indefinitely** since Spotlight search is not used on this machine.
- **Testing Plan**: Run with indexing disabled for several days. If freezes stop, keep indexing off permanently. If freezes persist, investigate secondary causes (GPU/WindowServer resets, network stack deadlocks, external SSD I/O stalls).

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


**Reachability / Remote Access (v3.2.4):**
- sshd_running (Single line text; Yes/No)
- ssh_port_listening (Single line text; Yes/No)
- screensharing_running (Single line text; Yes/No)
- vnc_port_listening (Single line text; Yes/No)
- tailscale_cli_present (Single line text; Yes/No)
- tailscale_peer_reachable (Single line text; Yes/No/Unknown)
- remote_access_artifacts (Long text)
- remote_access_artifacts_count (Number)
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
    <string>/Users/slavicanikolic/Library/Logs/imac-health-monitor.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/slavicanikolic/Library/Logs/imac-health-monitor.err.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

---

## Troubleshooting

### Common Issues

#### Script Always Shows "Critical"
**Cause**: Old thresholds (pre-v3.2.0) not calibrated for macOS Sonoma  
**Solution**: Upgrade to v3.2.0 with statistically-derived thresholds

#### LaunchAgent Not Running
```bash
# Check if loaded
launchctl list | grep imac-health

# Check for errors
cat ~/Library/Logs/imac-health-monitor.err.log

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

### v3.2.4 (2025-12-06) 🛰 Reachability & Unclassified Error Attribution

- **NEW:** Reachability / remote access diagnostics:
  - `sshd_running`, `ssh_port_listening`
  - `screensharing_running`, `vnc_port_listening`
  - `tailscale_cli_present`, `tailscale_peer_reachable`
- **NEW:** Remote access residue detection:
  - `remote_access_artifacts`, `remote_access_artifacts_count`
  - Flags AnyDesk / Splashtop processes, apps, prefs, LaunchAgents/Daemons.
- **NEW:** `unclassified_top_errors`:
  - Summarizes the dominant error messages that do **not** match existing subsystem buckets.
  - Explains the large gap between overall `Error Count` and tracked `error_*_1h` metrics, especially in evening spikes.
- **IMPROVED:** Evening and morning investigations:
  - Can now tell whether high error volume is due to kernel/GPU/Spotlight/iCloud, or other macOS background daemons.
- **NOTE:** No change to health thresholds or scoring logic; this is pure observability/diagnostics.


v3.2.3 (2025-12-01) — GUI App Detection Rewrite

CHANGED: Replaced AppleScript/System Events–based GUI app detection with a fast, reliable ps scan of processes inside *.app/Contents/MacOS/*.

FIXED: Eliminates false "No GUI apps detected" for active sessions (e.g., Finder, Chrome, Mail, pCloud).

FIXED: Removes dependence on Accessibility permissions, System Events timeouts, and AppleScript instability on macOS Sonoma.

IMPROVED: Application Inventory now consistently captures real running GUI apps for each console user.

IMPROVED: Maintains version lookup + ⚠️ LEGACY flag detection using existing logic.

### v3.2.3 (2025-12-02) 📖 DOCUMENTATION UPDATE
- **NEW**: Added "System Modifications Log" section for tracking troubleshooting and system changes
- **DOCUMENTED**: Messages.app wake freeze investigation and fix (CoreAudio/notification sounds issue)
- **ADDED**: Comprehensive testing protocol for wake freeze troubleshooting
- **ADDED**: Diagnostic log commands for future debugging (Messages, WindowServer, CoreAudio)
- **IMPROVED**: Header formatting for better readability in both markdown and plain text
- **UPDATED**: Documentation version and last updated date

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

## System Modifications Log

## System Modifications Log

This section tracks all debugging actions and configuration changes made to the system during troubleshooting. Each entry documents what happened, what was investigated, and what changes were implemented.

### 2025-12-06: iCloud Sync Spike Isolation Test

**Issue Being Investigated:**
- Persistent elevated error counts during **7–10 PM** and **8–10 AM** windows.
- Spotlight indexing has been disabled and remains low, so Spotlight is ruled out as the primary driver.
- Evidence increasingly pointed to **iCloud / CloudKit background sync** as a major contributor to morning and evening bursts.

**Change Implemented:**
- **Date:** 2025-12-06 07:00 EST  
- **Action:** Disabled iCloud services on this Mac (iCloud Drive, iCloud Photos, and related sync services where possible).  
- **Purpose:** Determine whether eliminating CloudKit delta sync jobs significantly reduces morning/evening error spikes.

**Evidence Prior to Change:**
- Evening `error_icloud_1h` frequently elevated.
- `Error Count` and `Recent Error Count (5 min)` elevated even with **no active user**, indicating scheduled background activity.
- CloudKit-style structured logging errors present in `top_errors` during many evening runs.

**Testing Plan:**
- Collect several days of monitoring data with iCloud disabled or minimized.
- Compare **before vs after** at the cutoff time **2025-12-06 07:00 EST**:
  - `error_icloud_1h`
  - `Error Count` (7–10 PM window)
  - `Recent Error Count (5 min)`
  - GPU/WindowServer and network error deltas
- If evening spikes collapse, treat iCloud/CloudKit as primary cause and consider a clean re-onboarding.
- If spikes remain high, focus on other subsystems (GPU redraw cycles, remote-access agents, pCloud Drive, or other “unclassified” daemons).

---

### 2025-12-04: Recurring Freeze Correlated with Spotlight/PDF Indexing Storm

**Issue Reported:**
- System became unresponsive again around **08:30 AM**.
- SSH and Screen Sharing were unreachable; local GUI input frozen.
- Forced shutdown required to recover.

**Investigation:**
- Health Monitor runs continued through **08:07 AM**, then a **~4.5 hour gap** until **12:37 PM** (post-reboot), matching the unresponsive window.
- Pre-freeze metrics showed a dominant Spotlight spike:
  - **07:20 AM baseline:** Error Count ~45,171/hr; Recent 5-min ~2,248; **error_spotlight_1h ~138**; Critical Fault Count 0; thermal_throttles_1h 0.
  - **07:43 AM spike:** Error Count ~81,884/hr; Recent 5-min ~4,061; **error_spotlight_1h ~3,401**; Critical Fault Count 1; thermal_throttles_1h 0.
  - **08:07 AM sustained:** Error Count ~78,168/hr; Recent 5-min ~7,967; **error_spotlight_1h ~3,430**; Critical Fault Count 1; thermal_throttles_1h 0.
- GPU and thermal metrics did not show a comparable step-change during the spike window.

**Conclusion:**
- Most consistent with a **Spotlight/QuickLook PDF indexing storm** (`mds`, `mdworker`, `CGPDFService`), likely triggered by large PDF caches (TurboTax formsets and other Library caches), starving system resources and wedging remote/GUI services.

**Changes Implemented:**
- Disabled Spotlight indexing on the **Data volume**:
  ```bash
  sudo mdutil -i off /System/Volumes/Data
  sudo mdutil -s /System/Volumes/Data
Decision: leave indexing OFF indefinitely since Spotlight search is not used on this machine.

Testing / Monitoring Plan:

Run indexing-off for several days and confirm no further unresponsive events.

If freezes persist with indexing off, investigate secondary causes (GPU/WindowServer resets, network stack deadlocks, external SSD I/O stalls).

2025-12-03: Remote Access Outage / PDF Render Storm
Issue Reported:

Remote SSH and Screen Sharing suddenly stopped working, even though Tailscale showed the iMac online.

SSH error from remote host: kex_exchange_identification: read: Connection reset by peer.

Screen Sharing/VNC also failed.

Investigation:

Verified tailnet reachability: tailscale ping snimac and ICMP ping OK; tailscale status showed direct path.

TCP ports open: nc -vz <tailscale-ip> 22 and 5900 succeeded.

ssh -vvv showed reset before server banner, indicating server-side/service wedge (not key/cipher mismatch).

Local machine GUI was unresponsive; required force quit to regain access.

Activity Monitor captured multiple CGPDFService workers each ~25% CPU: transient CoreGraphics PDF render storm with no user present (likely Spotlight/QuickLook background thumbnailing).

Spotlight index was rebuilt to clear potential PDF preview/index corruption.

Found residual AnyDesk LaunchDaemons in disabled folders; removed completely.

Conclusion:

Root cause most consistent with a background PDF preview/render storm starving WindowServer and remote services.

Changes Implemented:

Upgraded health monitor to v3.2.4 with:

Reachability diagnostics (SSH/Screen Sharing/Tailscale).

Remote-access residue scan (AnyDesk/Splashtop presence).

Documented troubleshooting notes and AnyDesk removal steps.

2025-12-02: Messages.app Wake Freeze Investigation
Issue Reported:

Time: ~2:35–2:45 PM EST.

Symptom: GUI completely frozen after wake from sleep; Terminal still functional.

User action: Forced restart at ~2:54 PM.

Investigation:

Analyzed system logs from 2:35–2:45 PM.

Identified WindowServer hang (not normal sleep behavior).

Found Messages.app (PID 5893) crashed during wake at 2:42:52 PM.

Root cause: CoreAudio HALC_IOContext_ResumeIO operations blocked WindowServer.

Contributing factor: External Thunderbolt 3 boot drive + notification sounds during wake (known macOS Sonoma interaction).

System Changes Implemented:

Date: 2025-12-02

Component: Messages.app

Change: Disabled notification sounds.

Method: Messages → Settings (⌘,) → General → Unchecked “Play sound effects”.

Rationale: Prevent CoreAudio resume operations during system wake that cause WindowServer hangs.

Testing Status: In progress – requires multiple sleep/wake cycles for confirmation.

Expected Result: System should wake from sleep without freezing.

Testing Protocol (Summary):

Temporarily enable short sleep intervals via pmset or use pmset sleepnow for manual tests.

Run:

Quick wake tests (10–30 seconds of sleep).

Medium (5–10 minutes).

Overnight sleep.

Signs it’s fixed:

Display and GUI respond immediately.

No forced restarts required.

If freeze recurs, capture Messages/WindowServer/CoreAudio logs immediately for further analysis.
## Future Enhancements

### Planned
- [ ] Network connectivity checks (ping, DNS resolution)
- [ ] Fan speed monitoring (if sensors available)
- [ ] Battery health (for MacBooks)
- [ ] Docker container health (if Docker installed)
- [ ] WiFi signal strength and quality
- [ ] Automatic Airtable schema validation

- [ ] Spotlight storm early-warning metrics (mds/mdworker/CGPDFService CPU% or process counts)
- [ ] Run-gap detector ("time since last successful run") to flag probable hangs
- [ ] Spotlight-only top error extraction for identifying indexing trigger

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
- ✅ Messages.app wake freeze investigation (v3.2.3 - CoreAudio/notification sounds issue)

**Key Learnings:**
- macOS Sonoma generates 25K+ log entries/hour under normal operation (not errors)
- Statistical analysis (281 samples) is superior to guesswork for threshold calibration
- Mean + 2σ/3σ methodology effectively identifies true anomalies
- VMware Fusion 12.2.4 stable on macOS Sonoma with legacy guest OSes
- System health monitoring requires calibration to actual system behavior
- External Thunderbolt 3 boot drives + Messages notification sounds can cause wake freezes

---

**Maintainer:** Darren Chilton  
**Hardware:** 2019 iMac 27" (Sonoma 15.7.2, external Thunderbolt SSD)  
**Last Verified:** 2025-12-02  
**Script Version:** 3.2.3  
**Script Lines:** 840+  
**Analysis:** 281 samples, 99%+ statistical confidence
