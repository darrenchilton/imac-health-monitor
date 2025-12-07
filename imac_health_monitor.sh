#!/bin/bash
##################################################
# iMac Health Monitor
#
# This script collects diagnostics and posts a JSON
# payload to Airtable for monitoring health.
#
# CHANGELOG (Recent):
# - Adds unclassified_top_errors field summarizing error patterns not matched by existing subsystems.
# - Fixes pages_wired awk column field ($3 -> $4).
# - Replaces associative array in GUI app inventory with a simple string accumulator.
# - sshd_running remains informational; ssh_port_listening is 
#   the source of truth for whether SSH is reachable.
##################################################

###############################################################################
# Configuration
###############################################################################

AIRTABLE_API_KEY="${AIRTABLE_API_KEY:-}"
AIRTABLE_BASE_ID="${AIRTABLE_BASE_ID:-}"
AIRTABLE_TABLE_NAME="${AIRTABLE_TABLE_NAME:-iMac Health}"
AIRTABLE_URL="https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}"

LOG_FILE="${HOME}/imac_health_monitor.log"
LOCK_FILE="/tmp/imac_health_monitor.lock"

# Timeout for remote commands (e.g. log collection) in seconds
REMOTE_CMD_TIMEOUT=25

###############################################################################
# Utility Functions
###############################################################################

log() {
    local msg="$1"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE"
}

debug_log() {
    # Flip this to "true" for verbose debug logging
    local debug_enabled=false
    if $debug_enabled; then
        log "[DEBUG] $1"
    fi
}

# Simple JSON-safe string escaper for jq --arg
json_escape() {
    local s="$1"
    # Replace backslashes and double quotes
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    # Replace newlines with literal \n
    s=${s//$'\n'/\\n}
    echo "$s"
}

# Convert a numeric string to integer safely (default 0)
to_int() {
    local val="$1"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    else
        echo 0
    fi
}

# Run a command with an overall timeout
run_with_timeout() {
    local timeout="$1"
    shift
    command_output=$(gtimeout "$timeout" "$@" 2>&1)
    local status=$?
    if [ $status -eq 124 ]; then
        echo "TIMEOUT"
        return 124
    fi
    echo "$command_output"
    return $status
}

###############################################################################
# LOCK FILE MECHANISM - Prevent concurrent exec
###############################################################################
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    log "Another instance of the script is already running (PID: $(cat "$LOCK_FILE")). Exiting."
    exit 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

###############################################################################
# BASIC SYSTEM INFO
###############################################################################
log "Starting iMac health monitoring run"

hostname=$(scutil --get ComputerName 2>/dev/null || hostname)
serial=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2}')
macos_version=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")

###############################################################################
# TIME MACHINE STATUS
###############################################################################
debug_log "Checking Time Machine status"
tmutil_output=$(tmutil status 2>/dev/null || echo "Not Running")
tm_status="Unknown"
tm_age_days=-1

if echo "$tmutil_output" | grep -qi "Running = 1"; then
    tm_status="Running"
else
    tm_status="Not Running"
fi

# Get time since last backup (in days)
if tm_last=$(tmutil latestbackup 2>/dev/null); then
    if tm_date_raw=$(basename "$tm_last" 2>/dev/null); then
        if tm_epoch=$(date -j -f "%Y-%m-%d-%H%M%S" "$tm_date_raw" "+%s" 2>/dev/null); then
            now_epoch=$(date "+%s")
            diff_sec=$(( now_epoch - tm_epoch ))
            tm_age_days=$(( diff_sec / 86400 ))
        fi
    fi
fi

###############################################################################
# STORAGE / SMART STATUS
###############################################################################
debug_log "Collecting SMART and storage info"
smart_status="Unknown"
drive_info="Unknown"

if command -v diskutil >/dev/null 2>&1; then
    smart_status=$(diskutil info disk0 2>/dev/null | awk -F': ' '/SMART Status/{print $2}' | head -n1)
    drive_info=$(system_profiler SPSerialATADataType SPNVMeDataType 2>/dev/null | awk '/Model|Capacity/ {gsub(/^ +/,"",$0); print}' | paste -sd "; " -)
fi

###############################################################################
# CPU / TEMPERATURE / FAN / THERMAL STATE
###############################################################################
debug_log "Gathering CPU temperature and thermal info"
cpu_temp="Unknown"
thermal_state="Unknown"
fan_rpm="Unknown"
thermal_throttles_1h=0
thermal_warning_active="No"
fan_max_events_1h=0
cpu_speed_limit=100

if command -v powermetrics >/dev/null 2>&1; then
    powermetrics_output=$(sudo powermetrics --samplers smc -n1 2>/dev/null || true)
    cpu_temp=$(echo "$powermetrics_output" | awk -F': ' '/CPU die temperature/ {print $2}' | sed 's/ C//')
    fan_rpm=$(echo "$powermetrics_output" | awk -F': ' '/Fan: / {print $2}' | sed 's/ RPM//')
fi

if command -v pmset >/dev/null 2>&1; then
    thermal_state=$(pmset -g thermlog 2>/dev/null | awk -F'=' '/^ThermalLevel/ {print $2; exit}')
    if [[ -z "$thermal_state" ]]; then
        thermal_state="Unknown"
    fi
fi

# Collect thermal + fan-related events from last hour via unified logs
debug_log "Collecting last-hour thermal/fan logs"
LOG_1H=$(run_with_timeout "$REMOTE_CMD_TIMEOUT" log show --style syslog --last 1h --predicate 'eventMessage CONTAINS[c] "thermal" OR eventMessage CONTAINS[c] "throttl" OR eventMessage CONTAINS[c] "fan"' 2>/dev/null)
if [[ "$LOG_1H" == "TIMEOUT" ]]; then
    LOG_1H="LOG_TIMEOUT"
fi

if [[ "$LOG_1H" != "LOG_TIMEOUT" ]]; then
    thermal_throttles_1h=$(echo "$LOG_1H" | grep -iE "throttl" | wc -l | tr -d ' ')
    thermal_warning_active=$(echo "$LOG_1H" | grep -qiE "thermal.*warning|overtemp|over temperature" && echo "Yes" || echo "No")
    if command -v pmset >/dev/null 2>&1; then
        cpu_speed_limit=$(pmset -g thermlog 2>/dev/null | awk -F'=' '/CPU_Speed_Limit/ {print $2; exit}')
        if [[ -z "$cpu_speed_limit" ]]; then
            cpu_speed_limit=100
        fi
    fi
    fan_max_events_1h=$(echo "$LOG_1H" | grep -iE "fan.*max|fan.*speed.*high|fan.*rpm" | wc -l | tr -d ' ')
fi

###############################################################################
# KERNEL PANICS, SYSTEM ERRORS, CRASHES, RECENT ERRORS
###############################################################################
debug_log "Collecting kernel panic, system error, and crash info"

# Kernel panics (last 30 days)
kernel_panics=$(log show --predicate 'eventMessage CONTAINS "Previous shutdown cause"' --last 30d 2>/dev/null || true)
kernel_panic_count=$(echo "$kernel_panics" | grep -i "Previous shutdown cause" | wc -l | tr -d ' ')
if [[ "$kernel_panic_count" -gt 0 ]]; then
    kernel_panics_text=$(echo "$kernel_panics" | tail -n 20 | sed 's/"/\\"/g')
else
    kernel_panics_text="None"
fi

# System errors: last hour
system_errors=$(log show --style syslog --last 1h --predicate 'eventMessage CONTAINS[c] "error" || eventMessage CONTAINS[c] "fault"' 2>/dev/null || true)
system_error_count=$(echo "$system_errors" | wc -l | tr -d ' ')
if [[ "$system_error_count" -gt 0 ]]; then
    system_errors_text=$(echo "$system_errors" | tail -n 50 | sed 's/"/\\"/g')
else
    system_errors_text="None"
fi

# Crashes via system log, last 7 days
crash_logs=$(log show --predicate 'eventMessage CONTAINS "EXC_" OR eventMessage CONTAINS "crash"' --last 7d 2>/dev/null || true)
crash_count=$(echo "$crash_logs" | wc -l | tr -d ' ')
if [[ "$crash_count" -gt 0 ]]; then
    top_crashes=$(echo "$crash_logs" | tail -n 50 | sed 's/"/\\"/g')
else
    top_crashes="None"
fi

# Recent "ERROR" patterns from last hour, plus classification
debug_log "Analyzing error logs and classifying by subsystem"

# Collect again for classification
if [[ "$LOG_1H" == "LOG_TIMEOUT" ]]; then
    errors_1h="LOG_TIMEOUT"
    critical_1h=0
    error_kernel_1h=0
    error_disk_1h=0
    error_network_1h=0
    error_gpu_1h=0
    error_systemstats_1h=0
    error_power_1h=0
    top_errors="N/A (log collection timed out)"
    unclassified_top_errors="N/A (log collection timed out)"
else
    errors_1h=$(echo "$LOG_1H" | grep -i "error" | wc -l | tr -d ' ')
    critical_1h=$(echo "$LOG_1H" | grep -iE "panic|fatal|corrupt|I\/O error" | wc -l | tr -d ' ')

    error_kernel_1h=$(echo "$LOG_1H" | grep -i "kernel" | grep -i "error" | wc -l | tr -d ' ')
    error_disk_1h=$(echo "$LOG_1H" | grep -iE "disk0|I/O error|SMART" | grep -i "error" | wc -l | tr -d ' ')
    error_network_1h=$(echo "$LOG_1H" | grep -iE "network|Wi-Fi|en0|en1|ethernet" | grep -i "error" | wc -l | tr -d ' ')
    error_gpu_1h=$(echo "$LOG_1H" | grep -iE "GPU|graphics|Metal" | grep -i "error" | wc -l | tr -d ' ')
    error_systemstats_1h=$(echo "$LOG_1H" | grep -i "systemstats" | grep -iE "error|fail" | wc -l | tr -d ' ')
    error_power_1h=$(echo "$LOG_1H" | grep -i "powerd" | grep -iE "error|fail|warning" | wc -l | tr -d ' ')

    thermal_throttles_1h=$(echo "$LOG_1H" | grep -iE "ther...mal.*throttl|throttl.*thermal|cpu.*throttl" | wc -l | tr -d ' ')
    thermal_warning_active="No"
    cpu_speed_limit=100
         fan_max_events_1h=$(echo "$LOG_1H" | grep -iE "fan.*max|fan.*speed.*high|fan.*rpm" | wc -l | tr -d ' ')
 
     top_errors=$(echo "$LOG_1H" \
         | grep -i "error" \
         | sed 's/.*error/error/i' \
         | sort | uniq -c | sort -nr | head -3 \
         | awk '{$1=""; print substr($0,2)}' \
         | paste -sd " | " -)

     unclassified_top_errors=$(echo "$LOG_1H" \
         | grep -i "error" \
         | grep -ivE "kernel|disk0|I/O error|SMART|network|Wi-Fi|en0|en1|ethernet|GPU|graphics|Metal|systemstats|powerd" \
         | sed 's/.*error/error/i' \
         | sort | uniq -c | sort -nr | head -3 \
         | awk '{$1=""; print substr($0,2)}' \
         | paste -sd " | " -)

     if [[ -z "$unclassified_top_errors" ]]; then
         unclassified_top_errors="None (all errors matched known subsystems)"
     fi
 fi


if [[ "$LOG_5M" == "LOG_TIMEOUT" ]]; then
    recent_5m=0
else
    recent_5m=$(echo "$LOG_5M" | grep -i "error" | wc -l | tr -d ' ')
fi

errors_1h_int=$(to_int "$errors_1h")
recent_5m_int=$(to_int "$recent_5m")
critical_1h_int=$(to_int "$critical_1h")

###############################################################################
# MEMORY PRESSURE / SWAP / VM
###############################################################################
debug_log "Checking memory pressure and swap usage"

memory_pressure="Unknown"
swap_used_gb=0
pages_free=0
pages_active=0
pages_wired=0
free_like=0
total_like=0

if command -v memory_pressure >/dev/null 2>&1; then
    memory_pressure=$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide memory free percentage:/ {print $2; exit}')
    memory_pressure=${memory_pressure:-"Unknown"}
fi

if vm_stat_output=$(vm_stat 2>/dev/null); then
    pages_free=$(echo "$vm_stat_output" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    pages_active=$(echo "$vm_stat_output" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    pages_wired=$(echo "$vm_stat_output" | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4}')
    free_like=$((pages_free + pages_active))
    total_like=$((free_like + pages_wired))
fi

if sysctl vm.swapusage >/dev/null 2>&1; then
    swap_used_gb=$(sysctl vm.swapusage 2>/dev/null | awk -F'[:, ]+' '/used/ {print $5}' | sed 's/\..*//')
fi

###############################################################################
# UPTIME / LOAD
###############################################################################
debug_log "Checking uptime and load"
uptime_val=$(uptime | sed 's/^.*up \([^,]*\), .*$/\1/')
load_average=$(uptime | awk -F'load averages:' '{print $2}' | xargs)

###############################################################################
# SSH / REMOTE ACCESS
###############################################################################
debug_log "Checking SSH / remote access"
sshd_running="No"
ssh_port_listening="No"

if pgrep -x "sshd" >/dev/null 2>&1; then
    sshd_running="Yes"
fi

if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; then
        ssh_port_listening="Yes"
    fi
fi

###############################################################################
# SOFTWARE UPDATES
###############################################################################
debug_log "Checking software updates"
software_updates=$(softwareupdate -l 2>/dev/null | sed 's/"/\\"/g' || echo "Unknown")

###############################################################################
# USERS & GUI APPLICATION INVENTORY
###############################################################################
debug_log "Collecting console users and GUI application inventory"
who_output=$(who 2>/dev/null || true)
if [[ -n "$who_output" ]]; then
    active_users=$(echo "$who_output" | awk '{print $1" ("$2", idle "$5")"}' | sort -u | paste -sd ", " -)
    user_count=$(echo "$who_output" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
else
    active_users="No console users"
    user_count=0
fi

application_inventory="No GUI applications detected"
total_gui_apps=0

ps_output=$(ps -axo pid,user,comm 2>/dev/null || true)
if [[ -n "$ps_output" ]]; then
    gui_procs=$(echo "$ps_output" | grep -E "/Applications/.+/.+\.app/Contents/MacOS/.+" | grep -v "grep" || true)
    if [[ -n "$gui_procs" ]]; then
        app_lines=""
        while read -r pid owner cmd; do
            [[ -z "$pid" ]] && continue
            app_path=$(echo "$cmd" | sed 's/\/Contents\/MacOS\/.*//')
            app_name=$(basename "$app_path")
            app_version="Unknown"
            if [[ -d "$app_path/Contents" ]]; then
                version_raw=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null || true)
                [[ -n "$version_raw" ]] && app_version="$version_raw"
            fi
            line="[$owner] ${app_name} ${app_version}"
            if [[ -z "$app_lines" ]]; then
                app_lines="$line"
            else
                app_lines="${app_lines}\n${line}"
            fi
        done <<< "$(echo "$gui_procs" | awk '{print $1" "$2" "$3}')"

        application_inventory="$app_lines"
        total_gui_apps=$(echo "$gui_procs" | wc -l | tr -d ' ')
    fi
fi

###############################################################################
# VMWARE / LEGACY SOFTWARE FLAGS
###############################################################################
debug_log "Checking for VMware activity"
vmware_status="Not Running"
vm_state="None"
vm_activity="No VMware processes detected"
vm_count=0
vmware_cpu_percent=0
vmware_memory_gb=0
legacy_software_flags="None"
high_risk_apps="None"
resource_hogs="None"

if pgrep -x "vmware-vmx" >/dev/null 2>&1; then
    vmware_status="Running"
    vm_pids=$(pgrep -x "vmware-vmx" 2>/dev/null || true)
    if [[ -n "$vm_pids" ]]; then
        vm_count=$(echo "$vm_pids" | wc -l | tr -d ' ')
        vm_activity=$(ps -p "$vm_pids" -o pid,pcpu,pmem,comm 2>/dev/null | sed 's/"/\\"/g')
        # Summarize CPU/memory usage
        vmware_cpu_percent=$(ps -p "$vm_pids" -o pcpu= 2>/dev/null | awk '{sum+=$1} END{print int(sum)}')
        vmware_memory_gb=$(ps -p "$vm_pids" -o rss= 2>/dev/null | awk '{sum+=$1} END{printf "%.1f", sum/1024/1024}')
    fi
fi

###############################################################################
# LEGACY / HIGH-RISK / RESOURCE HOG APPS
###############################################################################
debug_log "Scanning for legacy/high-risk applications"
legacy_software_flags_list=()
high_risk_apps_list=()
resource_hogs_list=()

# Example checks: (customize as needed)
if mdfind "kMDItemDisplayName == 'Flash Player'" 2>/dev/null | grep -q "Flash Player.app"; then
    legacy_software_flags_list+=("Flash Player installed")
fi

if mdfind "kMDItemDisplayName == 'Java 6'" 2>/dev/null | grep -q "Java 6"; then
    legacy_software_flags_list+=("Java 6 runtime present")
fi

# High-risk: unofficial torrent clients
if mdfind "kMDItemDisplayName == 'uTorrent'" 2>/dev/null | grep -q "uTorrent.app"; then
    high_risk_apps_list+=("uTorrent installed")
fi

# Resource hogs: anything with sustained CPU > 200% at snapshot
ps aux | awk 'NR>1 && $3 > 200 {print $1, $2, $3, $11}' | while read -r user pid cpu cmd; do
    resource_hogs_list+=("User: $user, PID: $pid, CPU: $cpu, CMD: $cmd")
done

if [[ ${#legacy_software_flags_list[@]} -gt 0 ]]; then
    legacy_software_flags=$(printf "%s\n" "${legacy_software_flags_list[@]}")
fi
if [[ ${#high_risk_apps_list[@]} -gt 0 ]]; then
    high_risk_apps=$(printf "%s\n" "${high_risk_apps_list[@]}")
fi
if [[ ${#resource_hogs_list[@]} -gt 0 ]]; then
    resource_hogs=$(printf "%s\n" "${resource_hogs_list[@]}")
fi

###############################################################################
# HEALTH SCORE & SEVERITY
###############################################################################
debug_log "Computing health score and severity"

health_score=100
reasons=()

# Time Machine age
if (( tm_age_days >= 0 )); then
    if (( tm_age_days > 30 )); then
        health_score=$((health_score - 30))
        reasons+=("Time Machine backup is older than 30 days")
    elif (( tm_age_days > 7 )); then
        health_score=$((health_score - 15))
        reasons+=("Time Machine backup is older than 7 days")
    fi
else
    reasons+=("Time Machine backup age unknown")
fi

# SMART
if [[ "$smart_status" != "Verified" && "$smart_status" != "Not Supported" && -n "$smart_status" ]]; then
    health_score=$((health_score - 40))
    reasons+=("SMART status is not Verified")
fi

# Kernel panics / critical errors
if (( kernel_panic_count > 0 )); then
    health_score=$((health_score - 20))
    reasons+=("Kernel panics detected in the last 30 days")
fi
if (( critical_1h_int > 0 )); then
    health_score=$((health_score - 20))
    reasons+=("Critical errors detected in the last hour")
fi

# Memory pressure
if [[ "$memory_pressure" =~ ^[0-9]+$ ]]; then
    if (( memory_pressure < 20 )); then
        health_score=$((health_score - 20))
        reasons+=("System-wide memory free percentage is below 20%")
    elif (( memory_pressure < 40 )); then
        health_score=$((health_score - 10))
        reasons+=("System-wide memory free percentage is below 40%")
    fi
fi

# Swap
if (( swap_used_gb > 4 )); then
    health_score=$((health_score - 15))
    reasons+=("Swap usage is greater than 4 GB")
elif (( swap_used_gb > 1 )); then
    health_score=$((health_score - 5))
    reasons+=("Swap usage is greater than 1 GB")
fi

# Thermal / Throttling
if (( thermal_throttles_1h > 0 )); then
    health_score=$((health_score - 15))
    reasons+=("Thermal throttling events detected in the last hour")
fi
if [[ "$thermal_warning_active" == "Yes" ]]; then
    health_score=$((health_score - 10))
    reasons+=("Active thermal warning present")
fi
if (( cpu_speed_limit < 100 )); then
    health_score=$((health_score - 10))
    reasons+=("CPU speed limit below 100% due to thermal pressure")
fi

# VMware resource usage
if (( vmware_cpu_percent > 300 )); then
    health_score=$((health_score - 20))
    reasons+=("VMware using more than 300% CPU combined")
elif (( vmware_cpu_percent > 150 )); then
    health_score=$((health_score - 10))
    reasons+=("VMware using more than 150% CPU combined")
fi

if (( $(printf "%.0f\n" "$vmware_memory_gb") > 8 )); then
    health_score=$((health_score - 20))
    reasons+=("VMware using more than 8 GB RAM combined")
elif (( $(printf "%.0f\n" "$vmware_memory_gb") > 4 )); then
    health_score=$((health_score - 10))
    reasons+=("VMware using more than 4 GB RAM combined")
fi

# Bound score
if (( health_score < 0 )); then
    health_score=0
fi
if (( health_score > 100 )); then
    health_score=100
fi

if (( health_score >= 80 )); then
    health_score_label="Good"
elif (( health_score >= 60 )); then
    health_score_label="Fair"
elif (( health_score >= 40 )); then
    health_score_label="Poor"
else
    health_score_label="Critical"
fi

severity="info"
if (( health_score < 40 || critical_1h_int > 0 || kernel_panic_count > 0 )); then
    severity="critical"
elif (( health_score < 60 )); then
    severity="warning"
fi

if [[ ${#reasons[@]} -gt 0 ]]; then
    reasons_str=$(printf "%s\n" "${reasons[@]}" | paste -sd "; " -)
else
    reasons_str="No major issues detected"
fi

###############################################################################
# JSON PAYLOAD ASSEMBLY
###############################################################################
debug_log "Assembling JSON payload"

if [[ -z "$AIRTABLE_API_KEY" || -z "$AIRTABLE_BASE_ID" ]]; then
    log "ERROR: AIRTABLE_API_KEY or AIRTABLE_BASE_ID not set. Exiting."
    exit 1
fi

# Use jq to construct JSON
reasons_json=$(json_escape "$reasons_str")
software_updates_json=$(json_escape "$software_updates")
system_errors_json=$(json_escape "$system_errors_text")
kernel_panics_json=$(json_escape "$kernel_panics_text")
top_crashes_json=$(json_escape "$top_crashes")
vm_activity_json=$(json_escape "$vm_activity")
legacy_software_flags_json=$(json_escape "$legacy_software_flags")
high_risk_apps_json=$(json_escape "$high_risk_apps")
resource_hogs_json=$(json_escape "$resource_hogs")
application_inventory_json=$(json_escape "$application_inventory")
active_users_json=$(json_escape "$active_users")

json_payload=$(jq -n \
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
  --arg reasons "$reasons_str" \
  --arg te "$top_errors" \
  --arg unclassified_te "$unclassified_top_errors" \
  --arg tp "$thermal_state" \
  --arg fanrpm "$fan_rpm" \
  --arg sshd "$sshd_running" \
  --arg sshport "$ssh_port_listening" \
  --arg vmstat "$vmware_status" \
  --arg vmstate "$vm_state" \
  --arg vmact "$vm_activity" \
  --arg legacy "$legacy_software_flags" \
  --arg risk "$high_risk_apps" \
  --arg hogs "$resource_hogs" \
  --arg apps "$application_inventory" \
  --arg users "$active_users" \
  --argjson hs "$health_score" \
  --argjson tmage "$tm_age_days" \
  --argjson kc "$kernel_panic_count" \
  --argjson e1h "$errors_1h_int" \
  --argjson e5m "$recent_5m_int" \
  --argjson cf1h "$critical_1h_int" \
  --argjson therm "$thermal_throttles_1h" \
  --argjson swap "$swap_used_gb" \
  --argjson vmcpu "$vmware_cpu_percent" \
  --argjson vmram "$vmware_memory_gb" \
  --argjson user_cnt "$user_count" \
  --argjson app_cnt "$total_gui_apps" \
  '{
    "fields": {
      "Hostname": $host,
      "macOS Version": $ver,
      "SMART Status": $smart,
      "Kernel Panics": $kc,
      "Kernel Panics Details": $kp,
      "System Errors 1h": $e1h,
      "Critical Errors 1h": $cf1h,
      "Recent Errors 5m": $e5m,
      "Top Error Patterns 1h": $te,
      "unclassified_top_errors": $unclassified_te,
      "Disk / Storage Info": $disk,
      "Uptime": $up,
      "Memory Free %": $mem,
      "Swap Used (GB)": $swap,
      "CPU Temperature": $cpu,
      "Thermal State": $tp,
      "Thermal Throttles (1h)": $therm,
      "Thermal Warning Active": $thermal_warning_active,
      "CPU Speed Limit %": $cpu_speed_limit,
      "Fan RPM": $fanrpm,
      "Time Machine Status": $tm,
      "Time Since Last Backup (days)": $tmage,
      "Software Updates": $swu,
      "SSHD Running": $sshd,
      "SSH Port 22 Listening": $sshport,
      "VMware Status": $vmstat,
      "VMware Activity": $vmact,
      "VMware CPU %": $vmcpu,
      "VMware Memory (GB)": $vmram,
      "Legacy Software Flags": $legacy,
      "High-Risk Applications": $risk,
      "Resource Hogs": $hogs,
      "Active Users": $users,
      "User Count": $user_cnt,
      "GUI Application Inventory": $apps,
      "GUI Application Count": $app_cnt,
      "Health Score": $hs,
      "Health Score Label": $health,
      "Severity": $severity,
      "Reasons": $reasons
    }
  }')

###############################################################################
# POST TO AIRTABLE
###############################################################################
debug_log "Posting to Airtable"

response=$(curl -sS -X POST "$AIRTABLE_URL" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \
  -H "Content-Type: application/json" \
  --data "$json_payload" 2>&1)
curl_status=$?

if [ $curl_status -ne 0 ]; then
    log "ERROR: Failed to send data to Airtable (curl status $curl_status). Response: $response"
    exit 1
else
    log "Successfully sent data to Airtable."
fi

log "iMac health monitoring run completed."
exit 0
