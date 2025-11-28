#!/bin/bash
###############################################################################
# iMac Health Monitor v3.2.4
# Last Updated: 2025-11-28
# 
# CHANGELOG v3.2.4:
# - NEW: Screen Sharing diagnostics with PROPER timeout protection
# - FIXED: All log show commands now use safe_timeout to prevent hanging
# - NEW: Captures screensharingd and AnyDesk connection failures (20min window)
# - NEW: Airtable field "Screen_Sharing_Status" for remote troubleshooting
# - IMPROVED: Graceful degradation if screen sharing logs timeout
###############################################################################
SECONDS=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# LOCK FILE MECHANISM - Prevent concurrent execution
###############################################################################
LOCK_FILE="$SCRIPT_DIR/.health_monitor.lock"
MAX_LOCK_AGE=1800  # 30 minutes - if lock is older, assume stale

# Check for existing lock
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    LOCK_TIME=$(stat -f "%m" "$LOCK_FILE" 2>/dev/null || stat -c "%Y" "$LOCK_FILE" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))
    
    # Check if the process is actually running
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

# Create lock file with our PID
echo $$ > "$LOCK_FILE"

# Ensure lock file is removed on exit
trap "rm -f '$LOCK_FILE'" EXIT INT TERM

###############################################################################
# ERROR THRESHOLDS
###############################################################################
ERROR_1H_WARNING=75635
ERROR_1H_CRITICAL=100684
ERROR_5M_WARNING=10872
ERROR_5M_CRITICAL=15081
CRITICAL_FAULT_WARNING=50
CRITICAL_FAULT_CRITICAL=100

# Load .env
ENV_PATH="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "ERROR: .env file not found at $ENV_PATH"
    exit 1
fi

set -a
source "$ENV_PATH"
set +a

AIRTABLE_TABLE_NAME="${AIRTABLE_TABLE_NAME:-System Health}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

safe_timeout() {
    local seconds="$1"; shift
    if have_cmd gtimeout; then gtimeout "${seconds}s" "$@"
    elif have_cmd timeout; then timeout "${seconds}s" "$@"
    else "$@"; fi
}

###############################################################################
# DEBUG LOGGING
###############################################################################
DEBUG_LOG="$SCRIPT_DIR/.debug_log.txt"
debug_log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$DEBUG_LOG"
}

> "$DEBUG_LOG"
debug_log "=== SCRIPT START ==="

timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
debug_log "Getting hostname and macOS version"
hostname=$(hostname)
macos_version=$(sw_vers -productVersion)

debug_log "Detecting boot device"
boot_device=$(diskutil info / 2>/dev/null | awk '/Device Node:/ {print $3}' | sed 's/s[0-9]*$//')
[[ -z "$boot_device" ]] && boot_device="disk0"

debug_log "Checking SMART status for $boot_device"
smart_status=$(safe_timeout 5 diskutil info "$boot_device" 2>/dev/null | awk -F': *' '/SMART Status/ {print $2}' | xargs)
[[ -z "$smart_status" ]] && smart_status="Unknown"

###############################################################################
# KERNEL PANIC DETECTION
###############################################################################
debug_log "Checking for kernel panic files"
panic_files=$(ls -1 /Library/Logs/DiagnosticReports/*.panic 2>/dev/null)
kernel_panics=0

if [[ -n "$panic_files" ]]; then
    cutoff_time=$(date -v-24H +%s 2>/dev/null || date -d "24 hours ago" +%s)
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        file_time=$(stat -f "%m" "$file" 2>/dev/null || stat -c "%Y" "$file" 2>/dev/null)
        if [[ -n "$file_time" && "$file_time" -ge "$cutoff_time" ]]; then
            ((kernel_panics++))
        fi
    done <<< "$panic_files"
fi

debug_log "Checking Time Machine backup age"
check_tm_age() {
    local path=$(safe_timeout 5 tmutil latestbackup 2>/dev/null)
    [[ -z "$path" ]] && echo "-1" && return
    local ts=$(stat -f "%m" "$path" 2>/dev/null)
    [[ -z "$ts" ]] && echo "-1" && return
    local now=$(date +%s)
    echo $(( (now - ts) / 86400 ))
}
tm_age_days=$(check_tm_age)

debug_log "Checking for software updates"
software_updates=$(safe_timeout 15 softwareupdate --list 2>&1 | \
    grep -q "No new software available" && echo "Up to Date" || echo "Unknown")

###############################################################################
# LOG COLLECTION
###############################################################################
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

debug_log "Collecting 1-hour log window"
LOG_1H=$(safe_log "1h")
debug_log "Finished 1-hour log collection"

debug_log "Collecting 5-minute log window"
LOG_5M=$(safe_log "5m")
debug_log "Finished 5-minute log collection"

if [[ "$LOG_1H" == "LOG_TIMEOUT" ]]; then
    echo "WARNING: 1-hour log collection timed out"
    errors_1h=0
    critical_1h=0
    error_kernel_1h=0
    error_windowserver_1h=0
    error_spotlight_1h=0
    error_icloud_1h=0
    error_disk_io_1h=0
    error_network_1h=0
    error_gpu_1h=0
    error_systemstats_1h=0
    error_power_1h=0
    thermal_throttles_1h=0
    thermal_warning_active="No"
    cpu_speed_limit=100
    fan_max_events_1h=0
    top_errors="Log collection timed out"
else
    errors_1h=$(echo "$LOG_1H" | grep -i "error" | wc -l | tr -d ' ')
    
    subsystem_patterns="kernel|WindowServer|mds|bird|com\.apple\.diskutil|com\.apple\.NetworkService|GPU|systemstats|powerd"
    error_patterns="error|fail|warn|denied|timeout|corrupt|invalid"
    
    critical_1h=$(echo "$LOG_1H" | grep -iE "($subsystem_patterns)" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    
    error_kernel_1h=$(echo "$LOG_1H" | grep -i "kernel" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_windowserver_1h=$(echo "$LOG_1H" | grep -i "WindowServer" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_spotlight_1h=$(echo "$LOG_1H" | grep -i "mds\|spotlight" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_icloud_1h=$(echo "$LOG_1H" | grep -i "bird\|cloudd\|icloud" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_disk_io_1h=$(echo "$LOG_1H" | grep -iE "disk|apfs|hfs|storage|fsck|mount" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_network_1h=$(echo "$LOG_1H" | grep -iE "network|wifi|ethernet|dns|tcp|udp" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_gpu_1h=$(echo "$LOG_1H" | grep -iE "GPU|graphics|metal|display" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_systemstats_1h=$(echo "$LOG_1H" | grep -i "systemstats" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    error_power_1h=$(echo "$LOG_1H" | grep -iE "power|battery|thermal|fan" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
    
    thermal_throttles_1h=$(echo "$LOG_1H" | grep -i "thermal" | grep -i "throttl" | wc -l | tr -d ' ')
    thermal_warning_active=$(echo "$LOG_1H" | grep -i "thermal" | grep -i "warning\|critical" | tail -1 | grep -q "thermal" && echo "Yes" || echo "No")
    
    cpu_speed_limit_raw=$(pmset -g thermlog 2>/dev/null | grep "CPU_Speed_Limit" | tail -1 | awk '{print $3}')
    cpu_speed_limit=${cpu_speed_limit_raw:-100}
    
    fan_max_events_1h=$(echo "$LOG_1H" | grep -i "fan" | grep -i "max\|full" | wc -l | tr -d ' ')
    
    top_errors=$(echo "$LOG_1H" | grep -iE "($subsystem_patterns)" | grep -iE "($error_patterns)" | \
        awk '{for(i=1;i<=NF;i++) if($i ~ /kernel|WindowServer|mds|bird|diskutil|NetworkService|GPU|systemstats|powerd/) {print $i; break}}' | \
        sort | uniq -c | sort -rn | head -5 | awk '{printf "%s(%d) ", $2, $1}')
    [[ -z "$top_errors" ]] && top_errors="None"
fi

if [[ "$LOG_5M" == "LOG_TIMEOUT" ]]; then
    errors_5m=0
    critical_5m=0
else
    errors_5m=$(echo "$LOG_5M" | grep -i "error" | wc -l | tr -d ' ')
    critical_5m=$(echo "$LOG_5M" | grep -iE "($subsystem_patterns)" | grep -iE "($error_patterns)" | wc -l | tr -d ' ')
fi

crash_count=$(ls -1 /Library/Logs/DiagnosticReports/*.crash 2>/dev/null | wc -l | tr -d ' ')
top_crashes=$(ls -1t /Library/Logs/DiagnosticReports/*.crash 2>/dev/null | head -5 | xargs -n1 basename 2>/dev/null | sed 's/\.crash$//' | tr '\n' ',' | sed 's/,$//')
[[ -z "$top_crashes" ]] && top_crashes="None"

gpu_freeze_events=$(echo "$LOG_1H" | grep -i "GPU" | grep -i "hang\|freeze\|timeout" | wc -l | tr -d ' ')
gpu_freeze_detected=$([[ "$gpu_freeze_events" -gt 0 ]] && echo "Yes" || echo "No")

kernel_panics_text="$kernel_panics in last 24h"

if [[ "$errors_1h" -ge "$ERROR_1H_CRITICAL" ]] || [[ "$critical_1h" -ge "$CRITICAL_FAULT_CRITICAL" ]]; then
    severity="Critical"
elif [[ "$errors_1h" -ge "$ERROR_1H_WARNING" ]] || [[ "$critical_1h" -ge "$CRITICAL_FAULT_WARNING" ]]; then
    severity="Warning"
else
    severity="Normal"
fi

if [[ "$errors_5m" -ge "$ERROR_5M_CRITICAL" ]] || [[ "$critical_5m" -ge "$CRITICAL_FAULT_CRITICAL" ]]; then
    active_burst="Yes (Critical - $errors_5m errors in 5m)"
    if [[ "$severity" == "Normal" ]]; then
        severity="Warning"
    fi
elif [[ "$errors_5m" -ge "$ERROR_5M_WARNING" ]] || [[ "$critical_5m" -ge "$CRITICAL_FAULT_WARNING" ]]; then
    active_burst="Yes (Warning - $errors_5m errors in 5m)"
    if [[ "$severity" == "Normal" ]]; then
        severity="Warning"
    fi
else
    active_burst="No"
fi

system_errors_text="Total: ${errors_1h}/hour (${critical_1h} critical faults), Recent: ${errors_5m}/5min, Active burst: ${active_burst}"

health_score=100
reasons=""

if [[ "$kernel_panics" -gt 0 ]]; then
    health_score=$((health_score - 50))
    reasons="${reasons}Kernel panics detected; "
fi

if [[ "$smart_status" != "Verified" ]] && [[ "$smart_status" != "Not Supported" ]]; then
    health_score=$((health_score - 40))
    reasons="${reasons}SMART status not verified; "
fi

if [[ "$errors_1h" -ge "$ERROR_1H_CRITICAL" ]] || [[ "$critical_1h" -ge "$CRITICAL_FAULT_CRITICAL" ]]; then
    health_score=$((health_score - 30))
    reasons="${reasons}Critical error rate; "
elif [[ "$errors_1h" -ge "$ERROR_1H_WARNING" ]] || [[ "$critical_1h" -ge "$CRITICAL_FAULT_WARNING" ]]; then
    health_score=$((health_score - 15))
    reasons="${reasons}Elevated error rate; "
fi

if [[ "$errors_5m" -ge "$ERROR_5M_CRITICAL" ]]; then
    health_score=$((health_score - 20))
    reasons="${reasons}Active critical error burst; "
elif [[ "$errors_5m" -ge "$ERROR_5M_WARNING" ]]; then
    health_score=$((health_score - 10))
    reasons="${reasons}Active error burst; "
fi

if [[ "$tm_age_days" -ge 7 ]]; then
    health_score=$((health_score - 10))
    reasons="${reasons}Time Machine backup overdue; "
fi

if [[ "$thermal_throttles_1h" -gt 10 ]]; then
    health_score=$((health_score - 15))
    reasons="${reasons}Thermal throttling detected; "
fi

if [[ "$gpu_freeze_events" -gt 0 ]]; then
    health_score=$((health_score - 20))
    reasons="${reasons}GPU freeze/hang events; "
fi

[[ -z "$reasons" ]] && reasons="System operating normally"

if [[ "$health_score" -ge 80 ]]; then
    health_score_label="Healthy ($health_score/100)"
elif [[ "$health_score" -ge 50 ]]; then
    health_score_label="Warning ($health_score/100)"
else
    health_score_label="Critical ($health_score/100)"
fi

uptime_seconds=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
current_time=$(date +%s)
uptime_val=$((current_time - uptime_seconds))
uptime_days=$((uptime_val / 86400))
uptime_val="$uptime_days days"

memory_pressure=$(memory_pressure 2>&1 | grep "System-wide memory" | head -1 || echo "Unknown")

if have_cmd osx-cpu-temp; then
    cpu_temp_raw=$(osx-cpu-temp -c 2>/dev/null)
    if [[ -n "$cpu_temp_raw" ]]; then
        cpu_temp="${cpu_temp_raw}°C"
    else
        cpu_temp="Unavailable"
    fi
else
    cpu_temp="osx-cpu-temp not installed"
fi

boot_drive_free=$(df -h / | tail -1 | awk '{print $4}')
boot_drive_pct=$(df -h / | tail -1 | awk '{print $5}')
drive_info="Boot: $boot_drive_free free ($boot_drive_pct used)"

if [[ "$tm_age_days" -eq -1 ]]; then
    tm_status="Never backed up or unavailable"
elif [[ "$tm_age_days" -eq 0 ]]; then
    tm_status="Backed up today"
elif [[ "$tm_age_days" -eq 1 ]]; then
    tm_status="Backed up yesterday"
else
    tm_status="Last backup: $tm_age_days days ago"
fi

###############################################################################
# SCREEN SHARING DIAGNOSTICS - WITH PROPER TIMEOUT PROTECTION
###############################################################################
debug_log "START: Screen sharing diagnostics"

get_screen_sharing_status() {
    local output=""
    
    # Check screensharingd service
    output+="=== Screen Sharing Service ===\n"
    local ss_running=$(launchctl list 2>/dev/null | grep -i "screensharing" | head -1)
    if [[ -n "$ss_running" ]]; then
        output+="Service: Running\n"
    else
        output+="Service: Not Running\n"
    fi
    
    # Check AnyDesk process
    output+="\n=== AnyDesk Status ===\n"
    local anydesk_running=$(ps aux 2>/dev/null | grep -i "[A]nyDesk" | head -1)
    if [[ -n "$anydesk_running" ]]; then
        output+="AnyDesk: Running\n"
    else
        output+="AnyDesk: Not Running\n"
    fi
    
    # CRITICAL: Check for connection failures with TIMEOUT protection
    output+="\n=== Recent Connection Failures (20m) ===\n"
    
    # Use safe_timeout with 30 second limit
    local log_output
    log_output=$(safe_timeout 30 log show --predicate 'process == "screensharingd" OR processImagePath CONTAINS "AnyDesk"' \
        --last 20m --style compact 2>/dev/null)
    
    local timeout_exit=$?
    
    if [[ $timeout_exit -eq 124 ]]; then
        output+="⚠️ Log query timed out (took >30s)\n"
        output+="Cannot determine failure count\n"
    elif [[ -z "$log_output" ]]; then
        output+="✓ No logs available or no failures\n"
    else
        local failures_20m=$(echo "$log_output" | grep -iE "failed|error|unable|timeout|denied|disconnect" | wc -l | tr -d ' ')
        
        if [[ "$failures_20m" -gt 0 ]]; then
            output+="⚠️ Connection failures detected: $failures_20m events\n"
            
            # Get sample of recent failures (last 3 to keep it brief)
            local sample_failures=$(echo "$log_output" | \
                grep -iE "failed|error|unable|timeout|denied|disconnect" | \
                tail -3 | \
                awk '{$1=$2=$3=""; print substr($0,4)}' | \
                sed 's/^/  • /')
            
            if [[ -n "$sample_failures" ]]; then
                output+="\nRecent errors:\n$sample_failures\n"
            fi
        else
            output+="✓ No connection failures in last 20 minutes\n"
        fi
    fi
    
    # Check active connections (with quick timeout)
    output+="\n=== Active Connections ===\n"
    local active_conns=$(safe_timeout 5 lsof -i -n -P 2>/dev/null | grep -iE "(screensharing|vnc|anydesk)" | wc -l | tr -d ' ')
    
    if [[ "$active_conns" -gt 0 ]]; then
        output+="Active connections: $active_conns\n"
        local conn_details=$(safe_timeout 5 lsof -i -n -P 2>/dev/null | grep -iE "(screensharing|vnc|anydesk)" | \
            awk '{printf "  • %s: %s -> %s\n", $1, $8, $9}' | head -3)
        [[ -n "$conn_details" ]] && output+="$conn_details\n"
    else
        output+="No active connections\n"
    fi
    
    echo -e "$output"
}

screen_sharing_status=$(get_screen_sharing_status)
debug_log "END: Screen sharing diagnostics complete"

###############################################################################
# USER/APPLICATION MONITORING (keeping existing v3.2.2 code)
###############################################################################
debug_log "START: User/app monitoring"

get_active_users() {
    local idle_time_ns=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}')
    local idle_seconds=${idle_time_ns%.*}
    
    local formatted_idle=""
    if [[ "$idle_seconds" -lt 5 ]]; then
        formatted_idle="active"
    elif [[ "$idle_seconds" -lt 60 ]]; then
        formatted_idle="${idle_seconds}s"
    elif [[ "$idle_seconds" -lt 3600 ]]; then
        local mins=$((idle_seconds / 60))
        formatted_idle="${mins}m"
    elif [[ "$idle_seconds" -lt 86400 ]]; then
        local hours=$((idle_seconds / 3600))
        local mins=$(((idle_seconds % 3600) / 60))
        if [[ "$mins" -gt 0 ]]; then
            formatted_idle="${hours}:$(printf "%02d" $mins)"
        else
            formatted_idle="${hours}h"
        fi
    else
        local days=$((idle_seconds / 86400))
        formatted_idle="${days}days"
    fi
    
    local console_user=$(stat -f "%Su" /dev/console 2>/dev/null)
    [[ -z "$console_user" ]] && console_user="root"
    
    echo "1"
    echo "User: $console_user (idle: $formatted_idle)"
}

get_user_applications() {
    local app_list=$(osascript -e 'tell application "System Events" to get name of every process whose background only is false' 2>/dev/null | sed 's/, /\n/g')
    local app_count=$(echo "$app_list" | grep -v "^$" | wc -l | tr -d ' ')
    echo "$app_count"
    echo "$app_list" | tr '\n' ',' | sed 's/,$//'
}

check_vmware_status() {
    if pgrep -x "vmware-vmx" >/dev/null 2>&1; then
        echo "Running"
    else
        echo "Not Running"
    fi
}

get_vm_details() {
    local vmrun_path="/Applications/VMware Fusion.app/Contents/Library/vmrun"
    if [[ ! -f "$vmrun_path" ]]; then
        echo "0|0|0"
        echo "VMware Fusion not found"
        return
    fi
    
    local vm_list=$("$vmrun_path" list 2>/dev/null | tail -n +2)
    local vm_count=$(echo "$vm_list" | grep -v "^$" | wc -l | tr -d ' ')
    
    if [[ "$vm_count" -eq 0 ]]; then
        echo "0|0.0|0.0"
        echo "No VMs running"
        return
    fi
    
    local total_cpu=0
    local total_mem=0
    local vm_details=""
    
    while IFS= read -r vmx_path; do
        [[ -z "$vmx_path" ]] && continue
        local vm_name=$(basename "$vmx_path" .vmx)
        
        local vm_pid=$(pgrep -f "$vmx_path" | head -1)
        if [[ -n "$vm_pid" ]]; then
            local cpu_usage=$(ps -p "$vm_pid" -o %cpu= 2>/dev/null | tr -d ' ')
            local mem_mb=$(ps -p "$vm_pid" -o rss= 2>/dev/null | awk '{print int($1/1024)}')
            local mem_gb=$(echo "scale=1; $mem_mb / 1024" | bc 2>/dev/null)
            
            [[ -z "$cpu_usage" ]] && cpu_usage="0.0"
            [[ -z "$mem_gb" ]] && mem_gb="0.0"
            
            total_cpu=$(echo "$total_cpu + $cpu_usage" | bc 2>/dev/null)
            total_mem=$(echo "$total_mem + $mem_gb" | bc 2>/dev/null)
            
            vm_details="${vm_details}${vm_name} (CPU: ${cpu_usage}%, RAM: ${mem_gb}GB), "
        fi
    done <<< "$vm_list"
    
    vm_details=$(echo "$vm_details" | sed 's/, $//')
    
    echo "${vm_count}|${total_cpu}|${total_mem}"
    echo "$vm_details"
}

determine_high_risk() {
    local vmware_status="$1"
    local app_inventory="$2"
    
    local risks=""
    
    if [[ "$vmware_status" == "Running" ]]; then
        risks="VMware Fusion running legacy VMs, "
    fi
    
    if echo "$app_inventory" | grep -qi "adobe\|microsoft office"; then
        risks="${risks}Legacy Adobe/Office apps, "
    fi
    
    [[ -z "$risks" ]] && risks="None"
    echo "$risks" | sed 's/, $//'
}

get_resource_hogs() {
    local hogs=$(ps aux | sort -rk 3 | head -6 | tail -5 | awk '{printf "%s(%.1f%% CPU, %.1fGB RAM), ", $11, $3, $6/1048576}')
    echo "$hogs" | sed 's/, $//'
}

generate_legacy_flags() {
    local apps="$1"
    local vms="$2"
    local flags=""
    
    if echo "$vms" | grep -qi "panther\|tiger\|leopard\|snow leopard"; then
        flags="Legacy Mac OS X VMs detected, "
    fi
    
    if echo "$vms" | grep -qi "windows 7\|windows xp"; then
        flags="${flags}Legacy Windows VMs detected, "
    fi
    
    [[ -z "$flags" ]] && flags="No legacy software detected"
    echo "$flags" | sed 's/, $//'
}

debug_log "  - Getting active users"
user_count_raw=$(get_active_users)
debug_log "  - Finished getting active users"

user_count=$(echo "$user_count_raw" | head -1)
active_users=$(echo "$user_count_raw" | tail -n +2)
[[ -z "$active_users" ]] && active_users="No console users"
[[ -z "$user_count" ]] && user_count=0

debug_log "  - Getting user applications"
app_data=$(get_user_applications)
debug_log "  - Finished getting user applications"

total_gui_apps=$(echo "$app_data" | head -1)
application_inventory=$(echo "$app_data" | tail -n +2)
[[ -z "$application_inventory" ]] && application_inventory="No applications detected"
[[ -z "$total_gui_apps" ]] && total_gui_apps=0

debug_log "  - Checking VMware status"
vmware_status=$(check_vmware_status)
debug_log "  - Finished VMware status check"
[[ -z "$vmware_status" ]] && vmware_status="Not Running"

debug_log "  - Getting VM details"
vm_data=$(get_vm_details)
debug_log "  - Finished getting VM details"
vm_metrics=$(echo "$vm_data" | head -1)
vm_activity=$(echo "$vm_data" | tail -n +2)
vm_count=$(echo "$vm_metrics" | cut -d'|' -f1)
vmware_cpu_percent=$(echo "$vm_metrics" | cut -d'|' -f2)

if [[ "$vmware_status" == "Running" ]]; then
    cpu_int=$(echo "$vmware_cpu_percent" | cut -d. -f1)
    
    if [[ "$vmware_cpu_percent" == "0.0" ]]; then
        vm_state="Idle"
    elif [[ "$cpu_int" -lt 1 ]]; then
        vm_state="Light Activity"
    elif [[ "$cpu_int" -lt 10 ]]; then
        vm_state="Moderate Activity"
    else
        vm_state="Active"
    fi
else
    vm_state="Not Running"
fi

vmware_memory_gb=$(echo "$vm_metrics" | cut -d'|' -f3)
[[ -z "$vm_activity" ]] && vm_activity="No VMs running"
[[ -z "$vm_count" ]] && vm_count=0
[[ -z "$vmware_cpu_percent" ]] && vmware_cpu_percent=0
[[ -z "$vmware_memory_gb" ]] && vmware_memory_gb=0

high_risk_apps=$(determine_high_risk "$vmware_status" "$application_inventory")
[[ -z "$high_risk_apps" ]] && high_risk_apps="None"

debug_log "  - Getting resource hogs"
resource_hogs=$(get_resource_hogs)
debug_log "  - Finished getting resource hogs"
[[ -z "$resource_hogs" ]] && resource_hogs="No resource hogs detected"

debug_log "  - Generating legacy software flags"
legacy_software_flags=$(generate_legacy_flags "$application_inventory" "$vm_activity")
[[ -z "$legacy_software_flags" ]] && legacy_software_flags="No legacy software detected"
debug_log "END: User/app monitoring complete"

run_duration_seconds=$SECONDS

DEBUG_LOG_CONTENT=$(cat "$DEBUG_LOG" 2>/dev/null || echo "Debug log unavailable")

###############################################################################
# Build JSON payload with screen sharing status
###############################################################################
debug_log "Building JSON payload"
JSON_PAYLOAD=$(jq -n \
  --arg ts "$timestamp" \
  --arg host "$hostname" \
  --arg ver "$macos_version" \
  --arg smart "$smart_status" \
  --arg kp "$kernel_panics_text" \
  --arg sys_err "$system_errors_text" \
  --arg disk "$drive_info" \
  --arg up "$uptime_val" \
  --arg mem "$memory_pressure" \
  --arg cpu "$cpu_temp" \
  --arg tm "$tm_status" \
  --arg swu "$software_updates" \
  --arg severity "$severity" \
  --arg health "$health_score_label" \
  --arg reasons "$reasons" \
  --arg te "$top_errors" \
  --arg tc "$top_crashes" \
  --arg gpu_freeze "$gpu_freeze_detected" \
  --arg gpu_events "$gpu_freeze_events" \
  --arg active_users "$active_users" \
  --arg app_inv "$application_inventory" \
  --arg vmware_stat "$vmware_status" \
  --arg vm_state "$vm_state" \
  --arg vm_act "$vm_activity" \
  --arg high_risk "$high_risk_apps" \
  --arg res_hogs "$resource_hogs" \
  --arg legacy_flags "$legacy_software_flags" \
  --arg debug_log "$DEBUG_LOG_CONTENT" \
  --arg thermal_warn "$thermal_warning_active" \
  --arg screen_sharing "$screen_sharing_status" \
  --argjson run_duration "$run_duration_seconds" \
  --argjson ek "$error_kernel_1h" \
  --argjson ew "$error_windowserver_1h" \
  --argjson es "$error_spotlight_1h" \
  --argjson ei "$error_icloud_1h" \
  --argjson ed "$error_disk_io_1h" \
  --argjson en "$error_network_1h" \
  --argjson eg "$error_gpu_1h" \
  --argjson est "$error_systemstats_1h" \
  --argjson ep "$error_power_1h" \
  --argjson cc "$crash_count" \
  --argjson tt "$thermal_throttles_1h" \
  --argjson fm "$fan_max_events_1h" \
  --argjson cpu_speed "$cpu_speed_limit" \
  --argjson user_cnt "$user_count" \
  --argjson app_cnt "$total_gui_apps" \
  --argjson vm_cnt "$vm_count" \
  --argjson vmw_cpu "$vmware_cpu_percent" \
  --argjson vmw_mem "$vmware_memory_gb" \
  '{fields: {
      "Run Duration (seconds)": $run_duration,
      "Timestamp": $ts,
      "Hostname": $host,
      "macOS Version": $ver,
      "SMART Status": $smart,
      "Kernel Panics": $kp,
      "System Errors": $sys_err,
      "Drive Space": $disk,
      "Uptime": $up,
      "Memory Pressure": $mem,
      "CPU Temperature": $cpu,
      "Time Machine": $tm,
      "Software Updates": $swu,
      "Severity": $severity,
      "Health Score": $health,
      "Reasons": $reasons,
      "top_errors": $te,
      "top_crashes": $tc,
      "error_kernel_1h": $ek,
      "error_windowserver_1h": $ew,
      "error_spotlight_1h": $es,
      "error_icloud_1h": $ei,
      "error_disk_io_1h": $ed,
      "error_network_1h": $en,
      "error_gpu_1h": $eg,
      "error_systemstats_1h": $est,
      "error_power_1h": $ep,
      "crash_count": $cc,
      "thermal_throttles_1h": $tt,
      "Thermal Warning Active": $thermal_warn,
      "CPU Speed Limit": $cpu_speed,
      "GPU Freeze Detected": $gpu_freeze,
      "GPU Freeze Events": $gpu_events,
      "fan_max_events_1h": $fm,
      "Active Users": $active_users,
      "Application Inventory": $app_inv,
      "VMware Status": $vmware_stat,
      "VM State": $vm_state,
      "VM Activity": $vm_act,
      "High Risk Apps": $high_risk,
      "Resource Hogs": $res_hogs,
      "Legacy Software Flags": $legacy_flags,
      "Debug Log": $debug_log,
      "Screen Sharing Status": $screen_sharing,
      "user_count": $user_cnt,
      "total_gui_apps": $app_cnt,
      "vm_count": $vm_cnt,
      "vmware_cpu_percent": $vmw_cpu,
      "vmware_memory_gb": $vmw_mem
  }}')

FINAL_PAYLOAD=$(jq -n \
  --argjson main "$JSON_PAYLOAD" \
  --arg raw "$JSON_PAYLOAD" \
  '{fields: ($main.fields + {"Raw JSON": $raw})}')

debug_log "Finished JSON construction, sending to Airtable"
TABLE_ENCODED=$(echo "$AIRTABLE_TABLE_NAME" | sed 's/ /%20/g')

RESPONSE=$(curl -s -X POST \
  "https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$TABLE_ENCODED" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$FINAL_PAYLOAD")

if echo "$RESPONSE" | grep -q '"id"'; then
    debug_log "Airtable upload: SUCCESS"
    echo "Airtable Update: SUCCESS"
else
    debug_log "Airtable upload: FAILED"
    echo "Airtable Update: FAILED"
    echo "$RESPONSE"
fi

debug_log "=== SCRIPT END (duration: ${run_duration_seconds}s) ==="
echo "Debug log saved to: $DEBUG_LOG"

echo "$FINAL_PAYLOAD"
