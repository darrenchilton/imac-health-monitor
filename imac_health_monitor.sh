#!/bin/bash
###############################################################################
# iMac Health Monitor v3.3.0 - CRASH DETECTION EDITION
# Last Updated: 2025-12-07
#
# CHANGELOG v3.3.0 (Crash Detection Improvements):
# - NEW: Browser activity monitoring (Chrome, Safari, Firefox, etc.)
# - NEW: Watchdog panic detection (catches system unresponsive crashes)
# - NEW: Enhanced GPU health monitoring (10-min window, critical patterns)
# - NEW: External SSD health monitoring (Thunderbolt, APFS errors, I/O)
# - NEW: I/O stall detection (processes stuck in D state)
# - NEW: Reboot tracking (detects unexpected system restarts)
# - NEW: Pre-crash system state capture
# - IMPROVED: Kernel panic text includes watchdog panics
# - ADDED: 11 new Airtable fields for crash diagnostics
#
# PREVIOUS CHANGELOG v3.2.4f (reachability accuracy):
# - Port listening checks now use netstat (LaunchAgent-safe) instead of lsof.
# - Tailscale detection uses full binary path (aliases/PATH not loaded for agents).
# - screensharing_running also considers port 5900 listener as evidence of service.
# - sshd_running remains informational; ssh_port_listening is canonical.
###############################################################################

SECONDS=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# LOCK FILE MECHANISM - Prevent concurrent execution
###############################################################################
LOCK_FILE="$SCRIPT_DIR/.health_monitor.lock"
MAX_LOCK_AGE=1800  # 30 minutes - if lock is older, assume stale

if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    LOCK_TIME=$(stat -f "%m" "$LOCK_FILE" 2>/dev/null || stat -c "%Y" "$LOCK_FILE" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))

    if ps -p "$LOCK_PID" > /dev/null 2>&1; then
        echo "Another instance (PID $LOCK_PID) is already running. Exiting."
        exit 0
    elif [ "$LOCK_AGE" -lt "$MAX_LOCK_AGE" ]; then
        echo "Recent lock file exists but process not found. Waiting for stale lock to expire."
        exit 0
    else
        echo "Stale lock file detected (age: ${LOCK_AGE}s). Removing and continuing."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT INT TERM

###############################################################################
# ERROR THRESHOLDS - Based on statistical analysis of 281 samples (Nov 2025)
###############################################################################
ERROR_1H_WARNING=75635
ERROR_1H_CRITICAL=100684
ERROR_5M_WARNING=10872
ERROR_5M_CRITICAL=15081
CRITICAL_FAULT_WARNING=50
CRITICAL_FAULT_CRITICAL=100

###############################################################################
# Load .env
###############################################################################
ENV_PATH="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "ERROR: .env file not found at $ENV_PATH"
    exit 1
fi
set -a
source "$ENV_PATH"
set +a

# Backward compatibility: older installs used AIRTABLE_API_KEY
if [[ -z "${AIRTABLE_PAT:-}" && -n "${AIRTABLE_API_KEY:-}" ]]; then
    AIRTABLE_PAT="$AIRTABLE_API_KEY"
fi
# Clean hidden CR/LF
AIRTABLE_PAT=$(printf "%s" "$AIRTABLE_PAT" | tr -d '\r' | tr -d '\n')

AIRTABLE_TABLE_NAME="${AIRTABLE_TABLE_NAME:-System Health}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

safe_timeout() {
    local seconds="$1"; shift
    if have_cmd gtimeout; then gtimeout "${seconds}s" "$@"
    elif have_cmd timeout; then timeout "${seconds}s" "$@"
    else "$@"; fi
}

debug_log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$SCRIPT_DIR/debug.log"
}

to_int() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo "0"
}

echo "[$(date '+%H:%M:%S')] === SCRIPT START ===" >> "$SCRIPT_DIR/debug.log"

###############################################################################
# Hostname and macOS version
###############################################################################
debug_log "Getting hostname and macOS version"
HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname)
MACOS_VERSION=$(sw_vers -productVersion)

###############################################################################
# Boot Device Detection and SMART Status
###############################################################################
debug_log "Detecting boot device"
BOOT_DEVICE=$(diskutil info / | grep "Device Node:" | awk '{print $3}')
BOOT_DEVICE_BASE="${BOOT_DEVICE%s*}"

debug_log "Checking SMART status for $BOOT_DEVICE"
SMART_OUTPUT=$(diskutil info "$BOOT_DEVICE" 2>/dev/null | grep "SMART Status")
if [[ "$SMART_OUTPUT" == *"Verified"* ]]; then
    SMART_STATUS="Verified"
elif [[ "$SMART_OUTPUT" == *"Not Supported"* ]]; then
    SMART_STATUS="Not Supported"
else
    SMART_STATUS="Unknown"
fi

###############################################################################
# NEW: External SSD Health Monitoring
###############################################################################
check_external_ssd_health() {
    # Monitor the external Thunderbolt SSD for connection issues
    local ssd_health="Healthy"
    local ssd_issues=""
    
    # Check for Thunderbolt disconnections in last hour
    local tb_log=$(safe_timeout 8 log show --last 1h --predicate 'subsystem == "com.apple.iokit.iothunderboltfamily"' 2>/dev/null)
    
    local disconnect_count=$(echo "$tb_log" | grep -ic "disconnect\|detach\|remove")
    if [[ $disconnect_count -gt 0 ]]; then
        ssd_health="Warning"
        ssd_issues+="Thunderbolt disconnections: ${disconnect_count}; "
    fi
    
    # Check for APFS errors on boot disk
    local apfs_log=$(safe_timeout 8 log show --last 1h --predicate 'subsystem == "com.apple.filesystems.apfs"' 2>/dev/null)
    
    local apfs_error_count=$(echo "$apfs_log" | grep -Eic "error|fail|corrupt|invalid")
    if [[ $apfs_error_count -gt 10 ]]; then  # More than 10 errors is concerning
        ssd_health="Critical"
        ssd_issues+="APFS errors: ${apfs_error_count}; "
    fi
    
    # Check for I/O errors
    local io_error_count=$(echo "$apfs_log" | grep -Eic "I/O error|cannot construct")
    if [[ $io_error_count -gt 0 ]]; then
        ssd_health="Critical"
        ssd_issues+="I/O errors: ${io_error_count}; "
    fi
    
    ssd_issues=$(echo "$ssd_issues" | sed 's/; $//')
    [[ -z "$ssd_issues" ]] && ssd_issues="None"
    
    echo "$ssd_health|$ssd_issues"
}

debug_log "Checking external SSD health"
ssd_health_data=$(check_external_ssd_health)
ssd_status=$(echo "$ssd_health_data" | cut -d'|' -f1)
ssd_issues=$(echo "$ssd_health_data" | cut -d'|' -f2)

###############################################################################
# Kernel Panic Detection (last 24 hours)
###############################################################################
debug_log "Checking for kernel panic files"
kernel_panics=0
panic_files=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name "Kernel*.panic" -mtime -1 2>/dev/null)
if [ -n "$panic_files" ]; then
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            ((kernel_panics++))
        fi
    done <<< "$panic_files"
fi

###############################################################################
# NEW: Watchdog Panic Detection
###############################################################################
check_watchdog_panics() {
    # Check for watchdog-related panics in the last 24 hours
    local watchdog_count=0
    local watchdog_details=""
    
    # Check both .panic files and .json stackshot files
    local panic_dirs=("$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")
    
    for dir in "${panic_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            # Check .panic files
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if grep -q "watchdogd.*exited" "$file" 2>/dev/null; then
                    ((watchdog_count++))
                    local timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null)
                    watchdog_details+="Watchdog panic at ${timestamp}; "
                fi
            done < <(find "$dir" -name "Kernel*.panic" -mtime -1 2>/dev/null)
            
            # Check .json stackshot files (newer format)
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                if grep -q "watchdogd.*exited" "$file" 2>/dev/null; then
                    ((watchdog_count++))
                    local timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$file" 2>/dev/null)
                    watchdog_details+="Watchdog panic at ${timestamp}; "
                fi
            done < <(find "$dir" -name "*.json" -mtime -1 2>/dev/null | head -20)
        fi
    done
    
    echo "$watchdog_count|$watchdog_details"
}

debug_log "Checking for watchdog panics"
watchdog_data=$(check_watchdog_panics)
watchdog_count=$(echo "$watchdog_data" | cut -d'|' -f1)
watchdog_details=$(echo "$watchdog_data" | cut -d'|' -f2)

###############################################################################
# Time Machine age
###############################################################################
debug_log "Checking Time Machine backup age"
check_tm_age() {
    local path
    path=$(safe_timeout 5 tmutil latestbackup 2>/dev/null)
    [[ -z "$path" ]] && echo "-1" && return
    local ts
    ts=$(stat -f "%m" "$path" 2>/dev/null)
    [[ -z "$ts" ]] && echo "-1" && return
    local now
    now=$(date +%s)
    echo $(((now - ts) / 86400))
}
tm_age_days=$(check_tm_age)

###############################################################################
# Software update status
###############################################################################
debug_log "Checking for software updates"
software_updates=$(safe_timeout 15 softwareupdate --list 2>&1 | \
    grep -q "No new software available" && echo "Up to Date" || echo "Unknown")

###############################################################################
# Log collection (1h / 5m)
###############################################################################
cpu_speed_limit=100
fan_max_events_1h=0
debug_log "Starting log collection (1h window)"
safe_log() {
    local timeout_val=300
    local result
    result=$(safe_timeout "$timeout_val" log show --style syslog --last "$1" 2>/dev/null)
    if [[ $? -eq 124 ]]; then
        echo "LOG_TIMEOUT"
    else
        echo "$result"
    fi
}

LOG_1H=$(safe_log "1h")
LOG_5M=$(safe_log "5m")

if [[ "$LOG_1H" == "LOG_TIMEOUT" ]]; then
    errors_1h=0; critical_1h=0
    error_kernel_1h=0; error_windowserver_1h=0; error_spotlight_1h=0
    error_icloud_1h=0; error_disk_io_1h=0; error_network_1h=0
    error_gpu_1h=0; error_systemstats_1h=0; error_power_1h=0
    thermal_throttles_1h=0; thermal_warning_active="No"
    cpu_speed_limit=100; fan_max_events_1h=0
    top_errors="Log collection timed out"
else
    errors_1h=$(echo "$LOG_1H" | grep -i "error" | wc -l | tr -d ' ')
    critical_1h=$(echo "$LOG_1H" | grep -iE "<Fault>|<Critical>|\[critical\]|\[fatal\]" | wc -l | tr -d ' ')
    [[ "$critical_1h" -gt "$errors_1h" ]] && critical_1h=$errors_1h

    error_kernel_1h=$(echo "$LOG_1H" | grep -i "kernel" | grep -iE "error|fail|panic" | wc -l | tr -d ' ')
    error_windowserver_1h=$(echo "$LOG_1H" | grep -i "WindowServer" | grep -iE "error|fail|crash" | wc -l | tr -d ' ')
    error_spotlight_1h=$(echo "$LOG_1H" | grep -i "metadata\|spotlight" | grep -iE "error|fail" | wc -l | tr -d ' ')
    error_icloud_1h=$(echo "$LOG_1H" | grep -iE "icloud|CloudKit" | grep -iE "error|fail|timeout" | wc -l | tr -d ' ')
    error_disk_io_1h=$(echo "$LOG_1H" | grep -iE "I/O error|disk.*error|read.*fail|write.*fail" | wc -l | tr -d ' ')
    error_network_1h=$(echo "$LOG_1H" | grep -iE "network|dns|resolver" | grep -iE "error|fail|timeout|unreachable" | wc -l | tr -d ' ')
    error_gpu_1h=$(echo "$LOG_1H" | grep -iE "GPU|AMDRadeon|Metal" | grep -iE "error|fail|timeout|hang|reset" | wc -l | tr -d ' ')
    error_systemstats_1h=$(echo "$LOG_1H" | grep -i "systemstats" | grep -iE "error|fail" | wc -l | tr -d ' ')
    error_power_1h=$(echo "$LOG_1H" | grep -i "powerd" | grep -iE "error|fail|warning" | wc -l | tr -d ' ')

    thermal_throttles_1h=$(echo "$LOG_1H" | grep -iE "thermal.*throttl|throttl.*thermal|cpu.*throttl" | wc -l | tr -d ' ')
    thermal_warning_active="No"
    cpu_speed_limit=100
    fan_max_events_1h=$(echo "$LOG_1H" | grep -iE "fan.*max|fan.*speed.*high|fan.*rpm" | wc -l | tr -d ' ')

    top_errors=$(echo "$LOG_1H" \
        | grep -i "error" \
        | sed 's/.*error/error/i' \
        | sort | uniq -c | sort -nr | head -3 \
        | awk '{$1=""; print substr($0,2)}' \
        | paste -sd " | " -)
fi

if [[ "$LOG_5M" == "LOG_TIMEOUT" ]]; then
    recent_5m=0
else
    recent_5m=$(echo "$LOG_5M" | grep -i "error" | wc -l | tr -d ' ')
fi

###############################################################################
# Crash reports
###############################################################################
debug_log "Checking for crash reports"
crash_files=$(ls -1t ~/Library/Logs/DiagnosticReports/*.{crash,ips,panic,diag} 2>/dev/null)
crash_count=$(echo "$crash_files" | grep -v '^$' | wc -l | tr -d ' ')
top_crashes=$(echo "$crash_files" | head -3 | sed 's/.*\///' | paste -sd "," -)

###############################################################################
# Drive space
###############################################################################
debug_log "Checking drive space"
drive_info=$(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2 {printf "Total: %s, Used: %s (%s), Available: %s", $2, $3, $5, $4}')
[[ -z "$drive_info" ]] && drive_info=$(df -h / | awk 'NR==2 {printf "Total: %s, Used: %s (%s), Available: %s", $2, $3, $5, $4}')

###############################################################################
# System info (uptime, memory, CPU temp)
###############################################################################
debug_log "Getting system info (uptime, memory, CPU temp)"
uptime_val=$(uptime | awk '{print $3,$4}' | sed 's/,$//')
memory_free=$(memory_pressure | grep "System-wide" | awk '{ print $5 }' | sed 's/%//')
memory_pressure="$((100 - memory_free))%"
cpu_temp=$(osx-cpu-temp 2>/dev/null || echo "N/A")

###############################################################################
# NEW: Reboot Detection
###############################################################################
detect_recent_reboot() {
    # Track uptime changes to detect unexpected reboots
    local uptime_file="$SCRIPT_DIR/.last_uptime"
    local current_uptime_seconds=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
    local boot_time=$(date -r "$current_uptime_seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    
    local reboot_detected="No"
    local reboot_info=""
    
    if [[ -f "$uptime_file" ]]; then
        local last_boot=$(cat "$uptime_file")
        if [[ "$last_boot" != "$current_uptime_seconds" ]]; then
            reboot_detected="Yes"
            reboot_info="System rebooted at ${boot_time} (previous boot: $(date -r "$last_boot" "+%Y-%m-%d %H:%M:%S" 2>/dev/null))"
        fi
    fi
    
    # Save current boot time for next check
    echo "$current_uptime_seconds" > "$uptime_file"
    
    echo "$reboot_detected|$reboot_info"
}

debug_log "Detecting recent reboots"
reboot_data=$(detect_recent_reboot)
reboot_detected=$(echo "$reboot_data" | cut -d'|' -f1)
reboot_info=$(echo "$reboot_data" | cut -d'|' -f2)

# Capture Previous Shutdown Cause (from unified logs, limited window)
previous_shutdown_cause_raw=$(safe_timeout 8 log show --last 1h \
    --predicate 'eventMessage CONTAINS "Previous shutdown cause"' \
    --style syslog 2>/dev/null | grep "Previous shutdown cause" | tail -1 | awk -F': ' '{print $NF}')

if [[ -z "$previous_shutdown_cause_raw" ]]; then
    previous_shutdown_cause="Unknown"
else
    previous_shutdown_cause="$previous_shutdown_cause_raw"
fi


# Update kernel panics text to include watchdog
total_crashes=$((kernel_panics + watchdog_count))
kernel_panics_text="No crashes in last 24 hours"
if [[ $total_crashes -gt 0 ]]; then
    kernel_panics_text="${kernel_panics} panic(s), ${watchdog_count} watchdog panic(s)"
    [[ -n "$watchdog_details" ]] && kernel_panics_text+=" - ${watchdog_details}"
fi

system_errors_text="Log Activity: ${errors_1h} errors (${recent_5m} recent, ${critical_1h} critical)"
tm_status="Configured; Latest: Unable to determine"
if [[ "$tm_age_days" -ne -1 && "$tm_age_days" -gt 0 ]]; then
    backup_date=$(date -v-"${tm_age_days}"d '+%Y-%m-%d' 2>/dev/null || date -d "${tm_age_days} days ago" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")
    tm_status="Configured; Latest: ${backup_date}"
elif [[ "$tm_age_days" -eq 0 ]]; then
    tm_status="Configured; Latest: $(date '+%Y-%m-%d')"
fi

###############################################################################
# NEW: Enhanced GPU Health Detection
###############################################################################
check_gpu_health() {
    # More comprehensive GPU health check
    local gpu_issues=""
    local gpu_status="Healthy"
    
    # Check for GPU resets/hangs in last 10 minutes (not just 2)
    local gpu_log=$(safe_timeout 10 log show --last 10m --predicate 'eventMessage CONTAINS[c] "gpu" OR eventMessage CONTAINS[c] "WindowServer" OR eventMessage CONTAINS[c] "AMD" OR eventMessage CONTAINS[c] "Radeon"' 2>/dev/null)
    
    # Critical GPU patterns
    local critical_patterns=(
        "GPU Reset"
        "GPU Hang" 
        "GPU timeout"
        "AMDRadeon.*error"
        "WindowServer.*timed out waiting"
        "Channel exception"
        "Metal.*timeout"
        "IOAccelerator.*timeout"
    )
    
    for pattern in "${critical_patterns[@]}"; do
        local count=$(echo "$gpu_log" | grep -Ec "$pattern")
        if [[ $count -gt 0 ]]; then
            gpu_status="Critical"
            gpu_issues+="${pattern}: ${count} events; "
        fi
    done
    
    # Warning-level GPU patterns
    local warning_patterns=(
        "IOSurface"
        "GPU Debug Info"
        "display.*error"
    )
    
    for pattern in "${warning_patterns[@]}"; do
        local count=$(echo "$gpu_log" | grep -Ec "$pattern")
        if [[ $count -gt 5 ]]; then  # Only warn if more than 5 occurrences
            [[ "$gpu_status" == "Healthy" ]] && gpu_status="Warning"
            gpu_issues+="${pattern}: ${count} events; "
        fi
    done
    
    gpu_issues=$(echo "$gpu_issues" | sed 's/; $//')
    [[ -z "$gpu_issues" ]] && gpu_issues="None"
    
    echo "$gpu_status|$gpu_issues"
}

debug_log "Checking for GPU freeze patterns (10-minute window)"
gpu_health_data=$(check_gpu_health)
gpu_status=$(echo "$gpu_health_data" | cut -d'|' -f1)
gpu_issues=$(echo "$gpu_health_data" | cut -d'|' -f2)

# Backwards compatibility with existing fields
gpu_freeze_detected="No"
[[ "$gpu_status" != "Healthy" ]] && gpu_freeze_detected="Yes"
gpu_freeze_events="$gpu_issues"

###############################################################################
# RTC Clock Drift Monitoring
###############################################################################
check_clock_drift() {
    debug_log "Checking RTC clock drift"
    local sntp_output
    local clock_offset_raw
    local clock_offset
    local clock_status
    local clock_details
    
    # Run sntp with timeout
    sntp_output=$(safe_timeout 10 sntp -d time.apple.com 2>&1 | tail -1)
    
    if [[ -z "$sntp_output" ]]; then
        echo "Unknown|0.000|Unable to contact time server"
        return
    fi
    
    # Extract offset (first number, e.g., "+0.057356")
    clock_offset_raw=$(echo "$sntp_output" | awk '{print $1}')
    clock_offset=$(echo "$clock_offset_raw" | tr -d '+')
    
    # Determine status based on offset magnitude (absolute value)
    local abs_offset
    abs_offset=$(awk "BEGIN {val=$clock_offset; if(val<0) val=-val; print val}")
    
    if (( $(awk "BEGIN {print ($abs_offset > 0.2)}") )); then
        clock_status="Critical"
        clock_details="Clock drift ${clock_offset_raw}s (>0.2s = significant drift, likely hardware issue)"
    elif (( $(awk "BEGIN {print ($abs_offset > 0.1)}") )); then
        clock_status="Warning"  
        clock_details="Clock drift ${clock_offset_raw}s (>0.1s = elevated drift)"
    else
        clock_status="Healthy"
        clock_details="Clock drift ${clock_offset_raw}s (normal range)"
    fi
    
    echo "$clock_status|$clock_offset|$clock_details"
}

debug_log "Checking RTC clock drift via NTP"
clock_drift_data=$(check_clock_drift)
clock_drift_status=$(echo "$clock_drift_data" | cut -d'|' -f1)
clock_offset_seconds=$(echo "$clock_drift_data" | cut -d'|' -f2)
clock_drift_details=$(echo "$clock_drift_data" | cut -d'|' -f3)

# Check for recent rateSf clamping errors in timed logs (1h for speed)
ratesf_errors=$(log show --predicate 'process == "timed" AND eventMessage CONTAINS "rateSf clamped"' --last 1h 2>/dev/null | grep -c "rateSf clamped" || echo "0")
if [[ "$ratesf_errors" -gt 0 ]]; then
    clock_drift_details+=" | ${ratesf_errors} rateSf clamp events in 1h"
    [[ "$clock_drift_status" == "Healthy" && "$ratesf_errors" -gt 5 ]] && clock_drift_status="Warning"
fi
###############################################################################
# User/Application Monitoring Functions
###############################################################################
get_active_users() {
    local user_list=""
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local user console idle
        user=$(echo "$line" | awk '{print $1}')
        console=$(echo "$line" | awk '{print $2}')
        idle=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i}')
        idle=$(echo "$idle" | sed 's/ $//')
        ((count++))
        user_list+="${user} (${console}, idle ${idle})"$'\n'
    done < <(w -h | grep console 2>/dev/null)
    echo "$count"
    echo "$user_list" | sed '/^$/d'
}

get_app_version() {
    local app_path="$1"
    local version=""
    if [[ -f "${app_path}/Contents/Info.plist" ]]; then
        version=$(defaults read "${app_path}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    fi
    echo "$version"
}

check_legacy_status() {
    local app_name="$1"
    local version="$2"
    case "$app_name" in
        "VMware Fusion")
            local major_version
            major_version=$(echo "$version" | cut -d'.' -f1)
            if [[ -n "$major_version" && "$major_version" -lt 13 ]]; then
                echo "⚠️ LEGACY"
            fi
            ;;
    esac
}

get_user_applications() {
    local total_apps=0
    local app_inventory=""
    local user_list
    user_list=$(who | grep console | awk '{print $1}' | sort -u)
    [[ -z "$user_list" ]] && echo "0" && echo "No console users" && return

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local user_cmds
        user_cmds=$(ps aux | awk -v u="$user" '$1 == u && $11 ~ /\.app\/Contents\/MacOS\// {print $11}' | sort -u)
        
        if [[ -z "$user_cmds" ]]; then
            app_inventory+="[${user}] No GUI apps detected"$'\n'
            continue
        fi

        local user_apps=""
        while IFS= read -r cmd_path; do
            [[ -z "$cmd_path" ]] && continue
            ((total_apps++))

            local app_bundle app_name app_path version legacy_flag
            app_bundle="${cmd_path%/Contents/MacOS/*}"
            app_name="${app_bundle##*/}"; app_name="${app_name%.app}"

            app_path=$(safe_timeout 5 mdfind "kMDItemKind == 'Application' && kMDItemFSName == '${app_name}.app'" 2>/dev/null | head -1)
            if [[ -n "$app_path" ]]; then
                version=$(get_app_version "$app_path")
                legacy_flag=$(check_legacy_status "$app_name" "$version")
                if [[ -n "$version" ]]; then user_apps+="${app_name} ${version}"
                else user_apps+="${app_name}"; fi
                [[ -n "$legacy_flag" ]] && user_apps+=" ${legacy_flag}"
                user_apps+=", "
            else
                user_apps+="${app_name}, "
            fi
        done <<< "$user_cmds"

        user_apps=$(echo "$user_apps" | sed 's/, $//')
        app_inventory+="[${user}] ${user_apps}"$'\n'
    done <<< "$user_list"

    echo "$total_apps"
    echo "$app_inventory" | sed '/^$/d'
}

###############################################################################
# NEW: Browser Activity Monitoring
###############################################################################
get_browser_activity() {
    # Detect which browsers are running and their resource usage
    local browser_data=""
    local browsers=("Google Chrome" "Safari" "Firefox" "Microsoft Edge" "Brave Browser")
    
    for browser in "${browsers[@]}"; do
        # Check if browser process exists
        local pids=$(pgrep -f "${browser}.app/Contents/MacOS" 2>/dev/null)
        if [[ -n "$pids" ]]; then
            local total_cpu=0
            local total_mem=0
            local process_count=0
            
            while IFS= read -r pid; do
                [[ -z "$pid" ]] && continue
                ((process_count++))
                
                local ps_line=$(ps -p "$pid" -o %cpu=,rss= 2>/dev/null)
                local cpu=$(echo "$ps_line" | awk '{print $1}')
                local mem_kb=$(echo "$ps_line" | awk '{print $2}')
                
                total_cpu=$(awk "BEGIN {printf \"%.1f\", $total_cpu + $cpu}")
                total_mem=$(awk "BEGIN {printf \"%.2f\", $total_mem + $mem_kb/1024/1024}")
            done <<< "$pids"
            
            if [[ $process_count -gt 0 ]]; then
                browser_data+="${browser}: ${process_count} processes, CPU ${total_cpu}%, RAM ${total_mem}GB"$'\n'
            fi
        fi
    done
    
    [[ -z "$browser_data" ]] && echo "No browsers running" || echo "$browser_data" | sed '/^$/d'
}

check_vmware_status() {
    if pgrep -x "vmware-vmx" >/dev/null 2>&1; then echo "Running"
    else echo "Not Running"; fi
}

get_vm_details() {
    local vm_activity=""
    local vm_count=0
    local total_cpu=0
    local total_mem=0
    local vmware_pids
    vmware_pids=$(pgrep -x "vmware-vmx" 2>/dev/null)

    if [[ -z "$vmware_pids" ]]; then
        echo "0|0|0"; echo "No VMs running"; return
    fi

    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        ((vm_count++))

        local ps_line vm_user cpu_pct mem_kb mem_gb runtime cmd
        ps_line=$(ps -p "$pid" -o user=,pid=,%cpu=,rss=,etime=,command= 2>/dev/null)
        vm_user=$(echo "$ps_line" | awk '{print $1}')
        cpu_pct=$(echo "$ps_line" | awk '{print $3}')
        mem_kb=$(echo "$ps_line" | awk '{print $4}')
        mem_gb=$(awk "BEGIN {printf \"%.2f\", $mem_kb/1024/1024}")
        runtime=$(echo "$ps_line" | awk '{print $5}')
        cmd=$(echo "$ps_line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i}')

        local guest_os="Unknown"
        if [[ "$cmd" =~ \.vmwarevm ]]; then
            local vm_path
            vm_path=$(echo "$cmd" | grep -o '[^"]*\.vmwarevm/[^"]*\.vmx' | head -1)
            if [[ -n "$vm_path" && -f "$vm_path" ]]; then
                guest_os=$(grep "guestOS" "$vm_path" 2>/dev/null | cut -d'"' -f2)
                case "$guest_os" in
                    *"win7"*) guest_os="Windows 7" ;;
                    *"win10"*) guest_os="Windows 10" ;;
                    *"darwin"*|*"macos"*)
                        if [[ "$guest_os" =~ "10.3" ]]; then guest_os="Mac OS X 10.3 Panther"
                        elif [[ "$guest_os" =~ "10." ]]; then guest_os="Mac OS X ${guest_os##*10.}"
                        else guest_os="macOS"; fi ;;
                esac
            fi
        fi

        local guest_risk=""
        case "$guest_os" in
            *"Windows 7"*) guest_risk=" ⚠️ EOL OS - legacy DirectX translation" ;;
            *"10.3"*) guest_risk=" ⚠️ Guest OS from 2003 - extreme legacy emulation" ;;
            *"10.4"*|*"10.5"*|*"10.6"*) guest_risk=" ⚠️ PowerPC/legacy emulation" ;;
        esac

        vm_activity+="VM ${vm_count} [${vm_user}]: ${guest_os}"$'\n'
        vm_activity+="  PID ${pid}, CPU ${cpu_pct}%, RAM ${mem_gb}GB, Runtime ${runtime}"
        [[ -n "$guest_risk" ]] && vm_activity+=$'\n'"  ${guest_risk}"
        vm_activity+=$'\n\n'

        total_cpu=$(awk "BEGIN {printf \"%.1f\", $total_cpu + $cpu_pct}")
        total_mem=$(awk "BEGIN {printf \"%.2f\", $total_mem + $mem_gb}")
    done <<< "$vmware_pids"

    echo "${vm_count}|${total_cpu}|${total_mem}"
    echo "$vm_activity" | sed '/^$/d'
}

determine_high_risk() {
    local vmware_status="$1"
    local app_inventory="$2"

    if [[ "$vmware_status" == "Running" ]]; then
        if echo "$app_inventory" | grep -q "VMware Fusion.*LEGACY"; then
            echo "VMware Legacy"; return
        fi
    fi

    local legacy_count
    legacy_count=$(echo "$app_inventory" | grep -c "LEGACY" 2>/dev/null)
    legacy_count=${legacy_count:-0}
    if [[ "$legacy_count" -gt 1 ]]; then echo "Multiple Legacy"
    elif [[ "$legacy_count" -eq 1 ]]; then echo "VMware Legacy"
    else echo "None"; fi
}

get_resource_hogs() {
    local hogs=""
    local high_cpu high_mem
    high_cpu=$(ps aux | awk '$3 > 80.0 {printf "%s (%s): CPU %.1f%%, RAM %.2fGB, User: %s\n", $11, $2, $3, $6/1024/1024, $1}' 2>/dev/null)
    high_mem=$(ps aux | awk '$6/1024/1024 > 4.0 {printf "%s (%s): CPU %.1f%%, RAM %.2fGB, User: %s\n", $11, $2, $3, $6/1024/1024, $1}' 2>/dev/null)
    [[ -n "$high_cpu" ]] && hogs+="$high_cpu"$'\n'
    [[ -n "$high_mem" ]] && hogs+="$high_mem"$'\n'
    [[ -z "$hogs" ]] && echo "No resource hogs detected" || echo "$hogs" | sed '/^$/d' | sort -u
}

###############################################################################
# NEW: I/O Stall Detection
###############################################################################
check_io_stalls() {
    # Detect processes stuck in uninterruptible sleep (D state)
    local stalled_processes=""
    local stall_count=0
    
    # Get processes in D state (uninterruptible sleep)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((stall_count++))
        
        local pid=$(echo "$line" | awk '{print $2}')
        local cmd=$(echo "$line" | awk '{print $11}')
        local user=$(echo "$line" | awk '{print $1}')
        
        stalled_processes+="${cmd} (PID ${pid}, User: ${user}); "
    done < <(ps aux | awk '$8 ~ /D/ {print $0}')
    
    echo "$stall_count|$stalled_processes"
}

generate_legacy_flags() {
    local app_inventory="$1"
    local vm_activity="$2"
    local flags=""
    if echo "$app_inventory" | grep -q "VMware Fusion.*LEGACY"; then
        local vmware_version
        vmware_version=$(echo "$app_inventory" | grep "VMware Fusion" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
        flags+="VMware Fusion ${vmware_version}: Pre-13.x uses deprecated kernel extensions, known GPU conflicts with Sonoma, incompatible with Metal rendering pipeline."
        if echo "$vm_activity" | grep -q "⚠️"; then
            local legacy_vms
            legacy_vms=$(echo "$vm_activity" | grep -c "⚠️" 2>/dev/null || echo "0")
            flags+=" Running ${legacy_vms} VM(s) with legacy guest OSes."
        fi
        flags+=" UPGRADE RECOMMENDED to VMware Fusion 13.5+"$'\n'
    fi
    [[ -z "$flags" ]] && echo "No legacy software detected" || echo "$flags" | sed '/^$/d'
}

debug_log "START: User/app monitoring"
user_count_raw=$(get_active_users)
user_count=$(echo "$user_count_raw" | head -1)
active_users=$(echo "$user_count_raw" | tail -n +2)
[[ -z "$active_users" ]] && active_users="No console users"
[[ -z "$user_count" ]] && user_count=0

app_data=$(get_user_applications)
total_gui_apps=$(echo "$app_data" | head -1)
application_inventory=$(echo "$app_data" | tail -n +2)
[[ -z "$application_inventory" ]] && application_inventory="No applications detected"
[[ -z "$total_gui_apps" ]] && total_gui_apps=0

browser_activity=$(get_browser_activity)
[[ -z "$browser_activity" ]] && browser_activity="No browsers running"

vmware_status=$(check_vmware_status)
[[ -z "$vmware_status" ]] && vmware_status="Not Running"

vm_data=$(get_vm_details)
vm_metrics=$(echo "$vm_data" | head -1)
vm_activity=$(echo "$vm_data" | tail -n +2)
vm_count=$(echo "$vm_metrics" | cut -d'|' -f1)
vmware_cpu_percent=$(echo "$vm_metrics" | cut -d'|' -f2)
vmware_memory_gb=$(echo "$vm_metrics" | cut -d'|' -f3)

if [[ "$vmware_status" == "Running" ]]; then
    cpu_raw="${vmware_cpu_percent:-0}"
    cpu_int=$(to_int "${cpu_raw%%.*}")
    if [[ "$cpu_int" -eq 0 ]]; then vm_state="Idle"
    elif [[ "$cpu_int" -lt 1 ]]; then vm_state="Light Activity"
    elif [[ "$cpu_int" -lt 10 ]]; then vm_state="Moderate Activity"
    else vm_state="Active"; fi
else
    vm_state="Not Running"
fi

[[ -z "$vm_activity" ]] && vm_activity="No VMs running"
[[ -z "$vm_count" ]] && vm_count=0
[[ -z "$vmware_cpu_percent" ]] && vmware_cpu_percent=0
[[ -z "$vmware_memory_gb" ]] && vmware_memory_gb=0

high_risk_apps=$(determine_high_risk "$vmware_status" "$application_inventory")
[[ -z "$high_risk_apps" ]] && high_risk_apps="None"

resource_hogs=$(get_resource_hogs)
[[ -z "$resource_hogs" ]] && resource_hogs="No resource hogs detected"

io_stall_data=$(check_io_stalls)
io_stall_count=$(echo "$io_stall_data" | cut -d'|' -f1)
io_stall_details=$(echo "$io_stall_data" | cut -d'|' -f2)

legacy_software_flags=$(generate_legacy_flags "$application_inventory" "$vm_activity")
[[ -z "$legacy_software_flags" ]] && legacy_software_flags="No legacy software detected"
debug_log "END: User/app monitoring"

###############################################################################
# Reachability / Remote Access Diagnostics
###############################################################################
debug_log "START: Reachability/remote access checks"

sshd_running="No"
pgrep -x "sshd" >/dev/null 2>&1 && sshd_running="Yes"

ssh_port_listening="No"
if netstat -anv -p tcp 2>/dev/null | grep -qE '\.22[[:space:]].*LISTEN'; then
    ssh_port_listening="Yes"
fi

screensharing_running="No"
pgrep -x "screensharingd" >/dev/null 2>&1 && screensharing_running="Yes"
pgrep -x "screensha" >/dev/null 2>&1 && screensharing_running="Yes"

vnc_port_listening="No"
if netstat -anv -p tcp 2>/dev/null | grep -qE '\.5900[[:space:]].*LISTEN'; then
    vnc_port_listening="Yes"
fi

if [[ "$vnc_port_listening" == "Yes" ]]; then
    screensharing_running="Yes"
fi

TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
tailscale_cli_present="No"
tailscale_peer_reachable="Unknown"
if [[ -x "$TS_BIN" ]]; then
    tailscale_cli_present="Yes"
    if "$TS_BIN" status 2>/dev/null | grep -qiE "snimac.*active"; then
        tailscale_peer_reachable="Yes"
    else
        tailscale_peer_reachable="No"
    fi
fi

remote_access_patterns=(
    "anydesk" "teamviewer" "chrome remote desktop" "remotedesktop"
    "splashtop" "logmein" "screenconnect" "connectwise"
    "realvnc" "vnc" "todesk" "rustdesk"
)

remote_access_artifacts_count=0
remote_access_artifacts="None"

scan_remote_artifacts() {
    local hits=""
    local paths=(
        "/Applications"
        "/Library/LaunchAgents"
        "/Library/LaunchDaemons"
        "$HOME/Library/Application Support"
    )
    
    for path in "${paths[@]}"; do
        [[ ! -d "$path" ]] && continue
        for pattern in "${remote_access_patterns[@]}"; do
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                hits+="${match},"
                ((remote_access_artifacts_count++))
            done < <(find "$path" -maxdepth 3 -iname "*${pattern}*" 2>/dev/null)
        done
    done
    
    if [[ $remote_access_artifacts_count -gt 0 ]]; then
        remote_access_artifacts=$(echo "$hits" | sed 's/,$//' | tr ',' '\n' | sort -u | paste -sd "," -)
    fi
}

scan_remote_artifacts
debug_log "END: Reachability/remote access checks"

###############################################################################
# Health Score and Severity
###############################################################################
health_score=100
severity="Info"
reasons=""

if [[ "$SMART_STATUS" != "Verified" && "$SMART_STATUS" != "Not Supported" ]]; then
    health_score=$((health_score - 40))
    severity="Critical"
    reasons+="SMART status not verified; "
fi

if [[ $total_crashes -gt 0 ]]; then
    health_score=$((health_score - 50))
    severity="Critical"
    reasons+="${total_crashes} crash(es) detected; "
fi

if [[ "$errors_1h" -ge "$ERROR_1H_CRITICAL" ]]; then
    health_score=$((health_score - 30))
    severity="Critical"
    reasons+="Critical error rate; "
elif [[ "$errors_1h" -ge "$ERROR_1H_WARNING" ]]; then
    health_score=$((health_score - 15))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="Elevated error activity; "
fi

if [[ "$critical_1h" -ge "$CRITICAL_FAULT_CRITICAL" ]]; then
    health_score=$((health_score - 20))
    severity="Critical"
    reasons+="High critical fault count; "
elif [[ "$critical_1h" -ge "$CRITICAL_FAULT_WARNING" ]]; then
    health_score=$((health_score - 10))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="Elevated critical faults; "
fi

if [[ "$gpu_freeze_detected" == "Yes" ]]; then
    health_score=$((health_score - 25))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="GPU freeze detected; "
fi

if [[ "$ssd_status" == "Critical" ]]; then
    health_score=$((health_score - 35))
    severity="Critical"
    reasons+="External SSD critical issues; "
elif [[ "$ssd_status" == "Warning" ]]; then
    health_score=$((health_score - 15))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="External SSD warnings; "
fi

if [[ "$gpu_status" == "Critical" ]]; then
    health_score=$((health_score - 30))
    severity="Critical"
    reasons+="GPU critical issues; "
elif [[ "$gpu_status" == "Warning" ]]; then
    health_score=$((health_score - 15))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="GPU warnings; "
fi

if [[ "$clock_drift_status" == "Critical" ]]; then
    health_score=$((health_score - 25))
    severity="Critical"
    reasons+="Critical clock drift (>0.2s); "
elif [[ "$clock_drift_status" == "Warning" ]]; then
    health_score=$((health_score - 15))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="Elevated clock drift; "
fi

if [[ "$io_stall_count" -gt 0 ]]; then
    health_score=$((health_score - 20))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="${io_stall_count} I/O stalls detected; "
fi

if [[ "$reboot_detected" == "Yes" ]]; then
    health_score=$((health_score - 10))
    [[ "$severity" == "Info" ]] && severity="Warning"
    reasons+="Recent reboot detected; "
fi

[[ "$health_score" -lt 0 ]] && health_score=0
reasons=$(echo "$reasons" | sed 's/; $//')
[[ -z "$reasons" ]] && reasons="System operating normally"

if [[ "$health_score" -ge 80 ]]; then
    health_status="Healthy"
    [[ "$severity" == "Info" ]] && severity="Info"
elif [[ "$health_score" -ge 60 ]]; then
    health_status="Monitor Closely"
    [[ "$severity" == "Info" ]] && severity="Warning"
elif [[ "$health_score" -ge 40 ]]; then
    health_status="Attention Needed"
    severity="Warning"
else
    health_status="Critical"
    severity="Critical"
fi

record_name="${health_status}-${severity}-$(date '+%b %d, %Y %I:%M %p')"

###############################################################################
# Derived Fields
###############################################################################
disk_used_pct=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
cpu_temp_c=$(echo "$cpu_temp" | sed 's/°C//')
cpu_temp_f=$(awk "BEGIN {printf \"%.1f\", ($cpu_temp_c * 9 / 5) + 32}" 2>/dev/null || echo "#ERROR!")
timestamp=$(date '+%m/%d/%Y %I:%M%p')
timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
date_only=$(date '+%Y-%m-%d')
hour_of_day=$(date '+%-H')
is_evening=$(if [[ "$hour_of_day" -ge 19 && "$hour_of_day" -lt 22 ]]; then echo "Yes"; else echo "No"; fi)
runtime_secs=$SECONDS
runtime_mins=$((runtime_secs / 60))
runtime_secs_remain=$((runtime_secs % 60))
runtime="${runtime_mins}:$(printf '%02d' $runtime_secs_remain)"

###############################################################################
# JSON Payload Construction
###############################################################################
ERROR_OBJECT=$(cat <<EOF
{"errors_1h": $errors_1h,"recent_5m": $recent_5m,"critical_1h": $critical_1h}
EOF
)
debug_log "Starting JSON payload build with jq"
jq_payload=$(jq -n \
    --arg name "$record_name" \
    --arg timestamp "$timestamp_iso" \
    --arg runtime "$runtime" \
    --arg runtime_secs "$runtime_secs" \
    --arg hostname "$HOSTNAME" \
    --arg macos "$MACOS_VERSION" \
    --arg smart "$SMART_STATUS" \
    --arg panics "$kernel_panics_text" \
    --arg drive "$drive_info" \
    --arg uptime "$uptime_val" \
    --arg mem "$memory_pressure" \
    --arg cpu_temp "$cpu_temp" \
    --arg tm "$tm_status" \
    --arg severity "$severity" \
    --arg health "$health_status" \
    --arg score "$health_score" \
    --arg reasons "$reasons" \
    --arg cpu_temp_f "$cpu_temp_f" \
    --arg date "$date_only" \
    --arg disk_pct "$disk_used_pct" \
    --arg cpu_temp_c "$cpu_temp_c" \
    --arg error_count "$errors_1h" \
    --arg recent_count "$recent_5m" \
    --arg critical_count "$critical_1h" \
    --arg tm_age "$tm_age_days" \
    --arg sw_updates "$software_updates" \
    --arg error_obj "$ERROR_OBJECT" \
    --arg top_errors "$top_errors" \
    --arg top_crashes "$top_crashes" \
    --arg error_kernel "$error_kernel_1h" \
    --arg error_ws "$error_windowserver_1h" \
    --arg error_diskio "$error_disk_io_1h" \
    --arg error_net "$error_network_1h" \
    --arg error_gpu "$error_gpu_1h" \
    --arg error_sysstats "$error_systemstats_1h" \
    --arg error_power "$error_power_1h" \
    --arg crash_count "$crash_count" \
    --arg thermal "$thermal_throttles_1h" \
    --arg fan_max "$fan_max_events_1h" \
    --arg gpu_freeze "$gpu_freeze_detected" \
    --arg gpu_events "$gpu_freeze_events" \
    --arg active_users "$active_users" \
    --arg notes "" \
    --arg system_errors "$system_errors_text" \
    --arg error_spotlight "$error_spotlight_1h" \
    --arg error_icloud "$error_icloud_1h" \
    --arg app_inv "$application_inventory" \
    --arg vmware_status "$vmware_status" \
    --arg vm_state "$vm_state" \
    --arg vm_activity "$vm_activity" \
    --arg high_risk "$high_risk_apps" \
    --arg resource_hogs "$resource_hogs" \
    --arg legacy_flags "$legacy_software_flags" \
    --arg debug_log "$(tail -50 "$SCRIPT_DIR/debug.log" | paste -sd '\n' -)" \
    --arg vmware_mem "$vmware_memory_gb" \
    --arg vm_count "$vm_count" \
    --arg user_count "$user_count" \
    --arg total_apps "$total_gui_apps" \
    --arg vmware_cpu "$vmware_cpu_percent" \
    --arg thermal_warn "$thermal_warning_active" \
    --arg cpu_limit "$cpu_speed_limit" \
    --arg hour "$hour_of_day" \
    --arg evening "$is_evening" \
    --arg sshd "$sshd_running" \
    --arg ssh_port "$ssh_port_listening" \
    --arg screenshare "$screensharing_running" \
    --arg vnc_port "$vnc_port_listening" \
    --arg ts_cli "$tailscale_cli_present" \
    --arg ts_peer "$tailscale_peer_reachable" \
    --arg remote_artifacts "$remote_access_artifacts" \
    --arg remote_count "$remote_access_artifacts_count" \
    --arg browser_activity "$browser_activity" \
    --arg watchdog_count "$watchdog_count" \
    --arg watchdog_details "$watchdog_details" \
    --arg gpu_status "$gpu_status" \
    --arg gpu_issues "$gpu_issues" \
    --arg ssd_status "$ssd_status" \
    --arg ssd_issues "$ssd_issues" \
    --arg io_stalls "$io_stall_count" \
    --arg io_details "$io_stall_details" \
    --arg reboot "$reboot_detected" \
    --arg reboot_info "$reboot_info" \
    --arg previous_shutdown_cause "$previous_shutdown_cause" \
    --arg clock_status "$clock_drift_status" \
    --arg clock_offset "$clock_offset_seconds" \
    --arg clock_details "$clock_drift_details" \
    '{
        "fields": {
            "Hostname": $hostname,
            "Run Duration (seconds)": ($runtime_secs | tonumber),
            "macOS Version": $macos,
            "SMART Status": $smart,
            "Kernel Panics": $panics,
            "Drive Space": $drive,
            "Uptime": $uptime,
            "Memory Pressure": $mem,
            "CPU Temperature": $cpu_temp,
            "Time Machine": $tm,
            "Severity": $severity,
            "Health Score": $health,
            "Reasons": $reasons,
            "Timestamp": $timestamp,
            "Software Updates": $sw_updates,
            "top_errors": $top_errors,
            "top_crashes": $top_crashes,
            "error_kernel_1h": ($error_kernel | tonumber),
            "error_windowserver_1h": ($error_ws | tonumber),
            "error_disk_io_1h": ($error_diskio | tonumber),
            "error_network_1h": ($error_net | tonumber),
            "error_gpu_1h": ($error_gpu | tonumber),
            "error_systemstats_1h": ($error_sysstats | tonumber),
            "error_power_1h": ($error_power | tonumber),
            "crash_count": ($crash_count | tonumber),
            "thermal_throttles_1h": ($thermal | tonumber),
            "fan_max_events_1h": ($fan_max | tonumber),
            "GPU Freeze Detected": $gpu_freeze,
            "GPU Freeze Events": $gpu_events,
            "Active Users": $active_users,
            "Notes": $notes,
            "System Errors": $system_errors,
            "error_spotlight_1h": ($error_spotlight | tonumber),
            "error_icloud_1h": ($error_icloud | tonumber),
            "Application Inventory": $app_inv,
            "VMware Status": $vmware_status,
            "VM State": $vm_state,
            "VM Activity": $vm_activity,
            "High Risk Apps": $high_risk,
            "Resource Hogs": $resource_hogs,
            "Legacy Software Flags": $legacy_flags,
            "Debug Log": $debug_log,
            "vmware_memory_gb": ($vmware_mem | tonumber),
            "vm_count": ($vm_count | tonumber),
            "user_count": ($user_count | tonumber),
            "total_gui_apps": ($total_apps | tonumber),
            "vmware_cpu_percent": ($vmware_cpu | tonumber),
            "Thermal Warning Active": $thermal_warn,
            "CPU Speed Limit": ($cpu_limit | tonumber),
            "sshd_running": $sshd,
            "ssh_port_listening": $ssh_port,
            "screensharing_running": $screenshare,
            "vnc_port_listening": $vnc_port,
            "tailscale_cli_present": $ts_cli,
            "tailscale_peer_reachable": $ts_peer,
            "remote_access_artifacts": $remote_artifacts,
            "remote_access_artifacts_count": ($remote_count | tonumber),
            "Browser Activity": $browser_activity,
            "Watchdog Panics (24h)": ($watchdog_count | tonumber),
            "Watchdog Details": $watchdog_details,
            "GPU Status": $gpu_status,
            "GPU Issues (Detailed)": $gpu_issues,
            "External SSD Status": $ssd_status,
            "SSD Issues": $ssd_issues,
            "I/O Stalls": ($io_stalls | tonumber),
            "I/O Stall Details": $io_details,
            "Reboot Detected": $reboot,
            "Reboot Info": $reboot_info,
            "Previous Shutdown Cause": $previous_shutdown_cause,
            "Clock Drift Status": $clock_status,
            "Clock Offset (seconds)": ($clock_offset | tonumber),
            "Clock Drift Details": $clock_details
        }
    }')
debug_log "Finished JSON payload build with jq"
###############################################################################
# Upload to Airtable
###############################################################################
###############################################################################
# Upload to Airtable
###############################################################################
debug_log "Starting Airtable upload"

echo "DEBUG: jq_payload length = ${#jq_payload}"
echo "DEBUG: First 500 chars:"
echo "${jq_payload:0:500}"
echo "---"
echo "DEBUG: About to curl..."
echo "AIRTABLE_PAT: ${AIRTABLE_PAT:0:20}..."
echo "AIRTABLE_BASE_ID: $AIRTABLE_BASE_ID"
echo "AIRTABLE_TABLE_NAME: $AIRTABLE_TABLE_NAME"
echo "URL: https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}"

RESPONSE=$(curl -sS --connect-timeout 10 --max-time 30 -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/System%20Health" \
    -H "Authorization: Bearer ${AIRTABLE_PAT}" \
    -H "Content-Type: application/json" \
    --data "$jq_payload")

CURL_EXIT=$?
debug_log "Curl to Airtable finished with exit code $CURL_EXIT"

if [ "$CURL_EXIT" -ne 0 ]; then
    echo "curl failed with exit code $CURL_EXIT (likely network/DNS/TLS issue talking to Airtable)"
    debug_log "Curl failed with exit code $CURL_EXIT; aborting before HTTP parse"
    exit 1
fi

HTTP_BODY=$(echo "$RESPONSE" | sed -e 's/HTTP_STATUS\:.*//g')
HTTP_STATUS=$(echo "$RESPONSE" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')

debug_log "Airtable HTTP status: $HTTP_STATUS"
debug_log "Airtable response (truncated 500 chars): $(echo "$HTTP_BODY" | head -c 500)"

if [ "$HTTP_STATUS" -eq 200 ]; then
    RECORD_ID=$(echo "$HTTP_BODY" | jq -r '.id // "unknown"')
    echo "Record created successfully: $RECORD_ID"
    debug_log "Airtable record created successfully: $RECORD_ID"
else
    echo "Upload failed with status $HTTP_STATUS"
    echo "Response: $HTTP_BODY"
    debug_log "Airtable upload failed with status $HTTP_STATUS"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Script completed in ${runtime}" >> "$SCRIPT_DIR/debug.log"
