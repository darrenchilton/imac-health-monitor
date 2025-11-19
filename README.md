# iMac Health Monitor - Technical Documentation

**Version:** 3.0  
**Last Updated:** 2025-11-19  
**Platform:** macOS Sonoma 15.7.2+  
**Target Hardware:** 2019 iMac 27" with external Thunderbolt 3 boot drive

---

## System Architecture

### Overview
Bash-based health monitoring system that collects system metrics every 15 minutes and transmits them to Airtable for centralized tracking and analysis. Optimized for iMacs running from external SSDs with automatic boot device detection.

### Components
```
/Users/slavicanikolic/Documents/imac-health-monitor/
├── imac_health_monitor.sh          # Main monitoring script
├── bin/
│   └── run_imac_health_monitor.sh  # LaunchAgent wrapper
├── .env                             # Environment configuration
├── LaunchAgent plists:
│   ├── com.slavicany.imac-health-monitor.plist
│   └── com.slavicanikolic.imac-health-updater.plist
└── README.md
```

### Execution Flow
1. **LaunchAgent Trigger** (every 900 seconds)
2. **Environment Loading** (.env credentials)
3. **Metrics Collection** (parallel where possible)
4. **Health Analysis** (threshold-based scoring)
5. **JSON Payload Construction** (jq)
6. **Airtable Transmission** (curl POST)
7. **Logging** (stdout/stderr to LaunchAgent logs)

---

## Monitored Metrics

### Hardware Health

#### SMART Status
- **Source**: `diskutil info <boot_device>`
- **Auto-detection**: Extracts actual boot device from `/` mount point
- **Supported devices**: External Thunderbolt SSDs, internal drives
- **Values**: "Verified" | "Failing" | "Unknown"

#### Kernel Panics
- **Source**: `log show --predicate 'eventMessage CONTAINS "panic(cpu"'`
- **Window**: Last 24 hours
- **Accuracy**: Filters for actual kernel panics vs. generic panic strings
- **Format**: Text description + count

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

### System Logs (Error Analysis)

#### Collection Windows
- **1-hour window**: Total error context
- **5-minute window**: Recent activity detection
- **2-minute window**: GPU freeze detection

#### Error Categories (per hour)
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

### GPU Freeze Detection (NEW in v3.0)

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

### Performance Metrics (NEW in v3.0)

#### Run Duration
- **Measurement**: Script execution time via `$SECONDS`
- **Type**: Integer (seconds)
- **Purpose**: Track monitoring overhead and detect slow runs

---

## Health Scoring Algorithm

### Health Score Levels
- **"Healthy"**: System operating normally
- **Attention Needed"**: Elevated errors or hardware issues
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

#### Required Fields

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
- GPU Freeze Detected: Can be text field with values ["Yes", "No"]

**Number Fields (precision: 0 or 1):**
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
- thermal_throttles_1h - precision: 1
- fan_max_events_1h - precision: 1

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

    <key>StartInterval</key>
    <integer>900</integer>  <!-- 15 minutes -->

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

### Wrong Drive Being Monitored

**Symptom:** Drive space shows incorrect data

**Cause:** Boot device auto-detection failed

**Manual override:**
```bash
# Check actual boot device
diskutil info / | grep "Device Node"

# Update script if needed (line ~36)
boot_device="disk2"  # Force specific device
```

### Missing Crash Reports

**Symptom:** `top_crashes` always empty

**Check for crash files:**
```bash
ls -la ~/Library/Logs/DiagnosticReports/
```

Modern macOS uses `.ips` files, not `.crash` files. The script now checks both.

---

## Performance Characteristics

### Execution Time
- **Typical**: 5-6 minutes (300-360 seconds)
- **Breakdown**:
  - Log collection (1h + 5m + 2m windows): ~4-5 minutes
  - GPU freeze detection (2-minute log scan): ~30-60 seconds
  - SMART status check: ~5 seconds
  - Other metrics collection: ~10-20 seconds
  - Airtable transmission: ~1-2 seconds
- **Factors**: Log volume, system load, network latency
- **Monitored via**: Run Duration field (in seconds)

**Note**: The 5-6 minute execution time is primarily due to macOS log collection operations which can be slow when processing large log volumes (40,000+ errors/hour). This is expected behavior and does not impact system responsiveness.

### System Impact
- **CPU**: Negligible (<1% average)
- **Memory**: ~30MB during execution
- **Network**: Single HTTPS POST (~5-10KB payload)
- **Disk I/O**: Read-only log access

### Scalability
- **Logs**: Handles 40,000+ errors/hour without degradation
- **Airtable**: No rate limiting issues at 15-minute intervals
- **Storage**: Log data not persisted locally

---

## Data Retention & Privacy

### Local Storage
- **Logs**: LaunchAgent logs rotate automatically by macOS
- **Credentials**: Stored in `.env` file (chmod 600)
- **No PII**: Only system-level metrics collected

### Transmitted Data
- System metrics only (no user activity)
- Hostname may reveal computer name
- No file contents, browser history, or user data

### Airtable Security
- Data encrypted in transit (HTTPS)
- Access controlled by Airtable permissions
- API keys should be treated as passwords

---

## Version History

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

---

**Maintainer:** Darren Chilton  
**Hardware:** 2019 iMac 27" (Sonoma 15.7.2, external Thunderbolt SSD)  
**Last Verified:** 2025-11-19