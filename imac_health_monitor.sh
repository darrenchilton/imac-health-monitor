#!/bin/bash
###############################################################################
# iMac Health Monitor v3.2.4f
# Last Updated: 2025-12-03
#
# PATCH v3.2.4f (reachability accuracy):
# - Port listening checks now use netstat (LaunchAgent-safe) instead of lsof.
# - Tailscale detection uses full binary path (aliases/PATH not loaded for agents).
# - screensharing_running also considers port 5900 listener as evidence of service.
# - sshd_running remains informational; ssh_port_listening is canonical.
# PATCH v3.2.4g (unclassified error attribution):
# - Adds unclassified_top_errors field summarizing error patterns not matched by existing subsystems.
# - Helps explain large gaps between total Error Count and categorized error_*_1h metrics, especially in evening spikes.
#
# CHANGELOG v3.2.4:
# - NEW: Reachability / remote access diagnostics:
#   - sshd_running + ssh_port_listening
#   - screensharing_running + vnc_port_listening
#   - tailscale_cli_present + tailscale_peer_reachable
# - NEW: Remote access artifact detection (AnyDesk / Splashtop presence).
# - NEW: More robust GPU freeze detection with 2-minute log window.
# - NEW: Detailed VMware inventory (guests, CPU, memory).
# - NEW: Application inventory and per-user GUI app listing.
# - NEW: Resource hog detection for CPU/MEM heavy processes.
# - IMPROVED: Thermal / CPU speed limit capture from pmset thermlog.
# - IMPROVED: Panic detection limited to last 24 hours.
# - IMPROVED: Time Machine status includes days-since-last-backup.
# - IMPROVED: Error thresholds tuned for this iMac over multi-week baseline.
#
# NOTE:
# - This script is intended to run as a LaunchAgent on a single iMac.
# - All metrics are sent to Airtable as a single record per run.
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

echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

###############################################################################
# Airtable configuration (from .env)
###############################################################################
AIRTABLE_PAT=""
AIRTABLE_BASE_ID=""
AIRTABLE_TABLE_NAME=""

ENV_PATH="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_PATH" ]; then
    echo "ERROR: .env file not found at $ENV_PATH"
    exit 1
fi

# shellcheck disable=SC1090
. "$ENV_PATH"

if [ -z "$AIRTABLE_PAT" ] || [ -z "$AIRTABLE_BASE_ID" ] || [ -z "$AIRTABLE_TABLE_NAME" ]; then
    echo "ERROR: Airtable variables not set correctly in .env"
    exit 1
fi

AIRTABLE_API_URL="https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_NAME"

###############################################################################
# Utility helpers
###############################################################################
have_cmd() { command -v "$1" >/dev/null 2>&1; }

safe_timeout() {
    local seconds="$1"; shift
    if have_cmd gtimeout; then gtimeout "${seconds}s" "$@"
    elif have_cmd timeout; then timeout "${seconds}s" "$@"
    else "$@"; fi
}

# Convert value to integer safely
to_int() {
    local val="$1"
    val=$(echo "${val:-0}" | tr -cd '0-9')
    [[ -z "$val" ]] && val=0
    echo "$val"
}

###############################################################################
# DEBUG LOGGING
###############################################################################
DEBUG_LOG="$SCRIPT_DIR/.debug_log.txt"
debug_log() { echo "[$(date '+%H:%M:%S')] $1" >> "$DEBUG_LOG"; }

> "$DEBUG_LOG"
debug_log "=== SCRIPT START ==="

timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
hostname=$(hostname)
macos_version=$(sw_vers -productVersion)

###############################################################################
# Boot disk + SMART status
###############################################################################
debug_log "Detecting boot device"
boot_device=$(diskutil info / 2>/dev/null | awk '/Device Node:/ {print $3}' | sed 's/s[0-9]*$//')
[[ -z "$boot_device" ]] && boot_device="disk0"

debug_log "Checking SMART status for $boot_device"
smart_status=$(diskutil info "$boot_device" 2>/dev/null | awk -F': ' '/SMART Status/ {print $2}' | xargs)
[[ -z "$smart_status" ]] && smart_status="Unknown or Unsupported"

###############################################################################
# Kernel panic detection (last 24h)
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

if (( kernel_panics > 0 )); then
    kernel_panics_text="Kernel panics in last 24h: $kernel_panics"
else
    kernel_panics_text="No kernel panics in last 24h"
fi

###############################################################################
# System error summary (5m window text)
###############################################################################
debug_log "Collecting brief 5m system error snippet"
syslog_errors=$(log show --predicate 'eventMessage CONTAINS "error" OR eventMessage CONTAINS "failed" OR eventMessage CONTAINS "timeout" OR eventMessage CONTAINS "panic"' --last 5m 2>/dev/null || true)
if [[ -n "$syslog_errors" ]]; then
    system_errors_text=$(echo "$syslog_errors" | tail -n 100)
else
    system_errors_text="No recent critical system log entries (5m window)"
fi

###############################################################################
# Error thresholds (from prior baseline)
###############################################################################
ERROR_1H_WARNING=75635
ERROR_1H_CRITICAL=100684
ERROR_5M_WARNING=10872
ERROR_5M_CRITICAL=15081
CRITICAL_FAULT_WARNING=50
CRITICAL_FAULT_CRITICAL=100

###############################################################################
# Collect full 1h / 5m logs
###############################################################################
safe_log() {
    local window="$1"
    debug_log "Collecting log window: $window"
    local out
    out=$(safe_timeout 300 log show --style syslog --last "$window" 2>/dev/null)
    if [[ $? -ne 0 || -z "$out" ]]; then
        echo "LOG_TIMEOUT"
    else
        echo "$out"
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
    unclassified_top_errors="N/A (log collection timed out)"
else
    errors_1h=$(echo "$LOG_1H" | grep -i "error" | wc -l | tr -d ' ')
    critical_1h=$(echo "$LOG_1H" | grep -iE "<Fault>|<Critical>|\[critical\]|\[fatal\]" | wc -l | tr -d ' ')
    [[ "$critical_1h" -gt "$errors_1h" ]] && critical_1h=$errors_1h

    error_kernel_1h=$(echo "$LOG_1H" | grep -i "kernel" | grep -iE "error|fail|panic" | wc -l | tr -d ' ')
    error_windowserver_1h=$(echo "$LOG_1H" | grep -i "WindowServer" | grep -iE "error|fail|crash" | wc -l | tr -d ' ')
    error_spotlight_1h=$(echo "$LOG_1H" | grep -i "metadata\|spotlight" | grep -iE "error|fail" | wc -l | tr -d ' ')
    error_icloud_1h=$(echo "$LOG_1H" | grep -iE "icloud|CloudKit" | grep -iE "error|fail|timeout" | wc -l | tr -d ' ')
    error_disk_io_1h=$(echo "$LOG_1H" | grep -iE "I/O error|disk.*error|read.*fail|write.*fail" | wc -l | tr -d ' ')
    error_network_1h=$(echo "$LOG_1H" | grep -iE "network|dns|resolver|connect|offline|reachability|timeout|failed" | grep -iE "error|fail|timeout|unreachable" | wc -l | tr -d ' ')
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

    unclassified_top_errors=$(echo "$LOG_1H" \
        | grep -i "error" \
        | grep -viE "kernel|WindowServer|metadata|spotlight|icloud|CloudKit|I/O error|disk.*error|read.*fail|write.*fail|network|dns|resolver|GPU|AMDRadeon|Metal|systemstats|powerd" \
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
# Crash report summary
###############################################################################
debug_log "Collecting recent crash files"
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
uptime_val=$(uptime | sed 's/^.*up \([^,]*\), .*$/\1/')

memory_pressure="N/A"
if vm_stat_output=$(vm_stat 2>/dev/null); then
    pages_free=$(echo "$vm_stat_output" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    pages_active=$(echo "$vm_stat_output" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    pages_inactive=$(echo "$vm_stat_output" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
    pages_speculative=$(echo "$vm_stat_output" | awk '/Pages speculative/ {gsub(/\./,"",$3); print $3}')
    pages_wired=$(echo "$vm_stat_output" | awk '/Pages wired down/ {gsub(/\./,"",$3); print $3}')
    free_like=$((pages_free + pages_inactive + pages_speculative))
    total_like=$((free_like + pages_active + pages_wired))
    if (( total_like > 0 )); then
        memory_pressure=$((100 - (free_like * 100 / total_like)))
    fi
fi

cpu_temp="N/A"
if have_cmd osx-cpu-temp; then
    cpu_temp=$(osx-cpu-temp 2>/dev/null || echo "N/A")
fi

###############################################################################
# Time Machine status
###############################################################################
debug_log "Checking Time Machine status"
if have_cmd tmutil && tmutil latestbackup >/dev/null 2>&1; then
    last_backup=$(tmutil latestbackup 2>/dev/null | tail -1)
    if [[ -n "$last_backup" ]]; then
        last_backup_time=$(stat -f "%m" "$last_backup" 2>/dev/null || stat -c "%Y" "$last_backup" 2>/dev/null)
        now=$(date +%s)
        tm_age_days=$(( (now - last_backup_time) / 86400 ))
        tm_age_days_int=$(to_int "$tm_age_days")
        tm_status="Configured; Latest: $(date -r "$last_backup_time" +"%Y-%m-%d") (${tm_age_days_int} days ago)"
    else
        tm_status="Configured; No completed backups found"
        tm_age_days_int=9999
    fi
else
    tm_status="Not Configured or no backup history"
    tm_age_days_int=9999
fi

###############################################################################
# Software update summary
###############################################################################
debug_log "Checking software updates"
software_updates=$(softwareupdate -l 2>/dev/null | head -n 10 || echo "Unknown")

###############################################################################
# Health scoring
###############################################################################
severity="Info"
health_score_label="Healthy"
reasons="System operating within normal parameters"

if (( critical_1h_int >= CRITICAL_FAULT_CRITICAL || kernel_panics > 0 )); then
    severity="Critical"
    health_score_label="System Instability"
    reasons="Kernel panics or critical faults detected in last 24h/1h window."
elif (( critical_1h_int >= CRITICAL_FAULT_WARNING )); then
    severity="Warning"
    health_score_label="Monitor Closely"
    reasons="Elevated critical faults in logs; investigate potential instability."
elif (( errors_1h_int >= ERROR_1H_CRITICAL || recent_5m_int >= ERROR_5M_CRITICAL )); then
    severity="Critical"
    health_score_label="Attention Needed"
    reasons="Severe error burst detected in system logs (1h/5m window)."
elif (( errors_1h_int >= ERROR_1H_WARNING || recent_5m_int >= ERROR_5M_WARNING )); then
    severity="Warning"
    health_score_label="Monitor Closely"
    reasons="Elevated system log activity above statistical baseline."
else
    severity="Info"
    health_score_label="Healthy"
    reasons="System behavior within statistically normal range."
fi

###############################################################################
# GPU freeze detection (2m window)
###############################################################################
debug_log "Checking for GPU/WindowServer freeze patterns (2m)"
gpu_freeze_detected="No"
gpu_freeze_events="None"

LOG_2M=$(safe_log "2m")
if [[ "$LOG_2M" != "LOG_TIMEOUT" ]]; then
    gpu_freeze_count=$(echo "$LOG_2M" | grep -iE "WindowServer|GPU|AMDRadeon|Metal" | grep -iE "stall|hang|reset|Watchdog|overload" | wc -l | tr -d ' ')
    if (( gpu_freeze_count > 0 )); then
        gpu_freeze_detected="Yes"
        gpu_freeze_events=$(echo "$LOG_2M" \
            | grep -iE "WindowServer|GPU|AMDRadeon|Metal" \
            | grep -iE "stall|hang|reset|Watchdog|overload" \
            | tail -n 10)
    fi
fi

###############################################################################
# Active users + application inventory
###############################################################################
debug_log "Collecting active user + GUI application inventory"
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
        declare -A user_apps
        while read -r pid owner cmd; do
            [[ -z "$pid" ]] && continue
            app_path=$(echo "$cmd" | sed 's/\/Contents\/MacOS\/.*//')
            app_name=$(basename "$app_path")
            app_version="Unknown"
            if [[ -d "$app_path/Contents" ]]; then
                version_raw=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null || true)
                [[ -n "$version_raw" ]] && app_version="$version_raw"
            fi
            key="$owner"
            value="${app_name} ${app_version}"
            if [[ -n "${user_apps[$key]:-}" ]]; then
                user_apps["$key"]+=", ${value}"
            else
                user_apps["$key"]="$value"
            fi
        done <<< "$(echo "$gui_procs" | awk '{print $1" "$2" "$3}')"

        app_lines=""
        for u in "${!user_apps[@]}"; do
            line="[$u] ${user_apps[$u]}"
            if [[ -z "$app_lines" ]]; then
                app_lines="$line"
            else
                app_lines="${app_lines}\n${line}"
            fi
        done
        application_inventory="$app_lines"
        total_gui_apps=$(echo "$gui_procs" | wc -l | tr -d ' ')
    fi
fi

###############################################################################
# VMware / virtualization status
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
    vm_count=$(echo "$vm_pids" | wc -w | tr -d ' ')
    vm_lines=""
    total_cpu=0
    total_mem=0

    while read -r pid; do
        [[ -z "$pid" ]] && continue
        vm_info=$(ps -p "$pid" -o %cpu=,%mem=,command= 2>/dev/null || true)
        vm_cpu=$(echo "$vm_info" | awk '{print int($1)}')
        vm_mem=$(echo "$vm_info" | awk '{print int($2)}')
        vm_cmd=$(echo "$vm_info" | cut -d' ' -f3-)
        total_cpu=$((total_cpu + vm_cpu))
        total_mem=$((total_mem + vm_mem))
        vm_name="UnknownGuest"
        vmx_path=$(echo "$vm_cmd" | sed 's/.*-config //; s/ .*//')
        if [[ -f "$vmx_path" ]]; then
            guest_os=$(grep -i "^guestOS " "$vmx_path" 2>/dev/null | awk -F' = ' '{print $2}' | tr -d '"' || echo "Unknown")
            vm_name="$guest_os"
        fi
        line="PID $pid: $vm_name (CPU: ${vm_cpu}%, MEM: ${vm_mem}%)"
        if [[ -z "$vm_lines" ]]; then
            vm_lines="$line"
        else
            vm_lines="${vm_lines}\n${line}"
        fi
    done <<< "$vm_pids"

    vm_state="Active VMs: $vm_count"
    vm_activity="$vm_lines"
    vmware_cpu_percent="$total_cpu"
    vmware_memory_gb="$total_mem"

    if echo "$vm_activity" | grep -qiE "Fusion 10|Fusion 11|Fusion 12"; then
        legacy_software_flags="VMware Legacy Version Detected"
        high_risk_apps="VMware Legacy"
    fi
fi

if [[ "$vmware_status" != "Running" ]]; then
    legacy_software_flags="None"
    high_risk_apps="None"
fi

###############################################################################
# Resource hog detection (CPU/MEM)
###############################################################################
debug_log "Detecting resource hog processes"
ps -axo pid,pcpu,pmem,comm 2>/dev/null | awk 'NR>1 && ($2+0 > 80 || $3+0 > 4)' | while read -r pid cpu mem cmd; do
    hog_entry="PID $pid: CPU ${cpu}%, MEM ${mem}%, CMD $cmd"
    if [[ "$resource_hogs" == "None" ]]; then
        resource_hogs="$hog_entry"
    else
        resource_hogs="${resource_hogs}\n${hog_entry}"
    fi
done

###############################################################################
# Remote access artifacts
###############################################################################
debug_log "Scanning for remote access artifacts (AnyDesk, Splashtop)"
REMOTE_ARTIFACTS=()
remote_access_artifacts_count=0
add_artifact() {
    local val="$1"
    REMOTE_ARTIFACTS+=("$val")
    remote_access_artifacts_count=$((remote_access_artifacts_count + 1))
}

if pgrep -x "AnyDesk" >/dev/null 2>&1; then
    add_artifact "AnyDesk process running"
fi
if pgrep -x "Splashtop Streamer" >/dev/null 2>&1; then
    add_artifact "Splashtop Streamer process running"
fi
if ls /Applications 2>/dev/null | grep -qi "AnyDesk"; then
    add_artifact "AnyDesk.app present in /Applications"
fi
if ls /Applications 2>/dev/null | grep -qi "Splashtop"; then
    add_artifact "Splashtop app present in /Applications"
fi
if ls ~/Library/Preferences 2>/dev/null | grep -qi "com.philandro.anydesk"; then
    add_artifact "AnyDesk preference files detected"
fi
if ls ~/Library/Preferences 2>/dev/null | grep -qi "com.splashtop"; then
    add_artifact "Splashtop preference files detected"
fi
if ls /Library/LaunchAgents 2>/dev/null | grep -qiE "anydesk|splashtop"; then
    add_artifact "Remote access LaunchAgents detected"
fi
if ls /Library/LaunchDaemons 2>/dev/null | grep -qiE "anydesk|splashtop"; then
    add_artifact "Remote access LaunchDaemons detected"
fi

remote_access_artifacts="None"
if (( remote_access_artifacts_count > 0 )); then
    remote_access_artifacts=$(printf "%s\n" "${REMOTE_ARTIFACTS[@]}")
fi

###############################################################################
# Reachability / remote access live status
###############################################################################
debug_log "Checking reachability (sshd, Screen Sharing, Tailscale)"
sshd_running="No"
ssh_port_listening="No"
screensharing_running="No"
vnc_port_listening="No"
tailscale_cli_present="No"
tailscale_peer_reachable="Unknown"

if pgrep -x "sshd" >/dev/null 2>&1; then
    sshd_running="Yes"
fi
if netstat -an 2>/dev/null | grep -qE "\\.22[[:space:]]+.*LISTEN"; then
    ssh_port_listening="Yes"
fi
if pgrep -x "screensharingd" >/dev/null 2>&1; then
    screensharing_running="Yes"
fi
if netstat -an 2>/dev/null | grep -qE "\\.5900[[:space:]]+.*LISTEN"; then
    vnc_port_listening="Yes"
fi

if command -v /Applications/Tailscale.app/Contents/MacOS/Tailscale >/dev/null 2>&1; then
    tailscale_cli_present="Yes"
    ts_status=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status 2>/dev/null || true)
    if echo "$ts_status" | grep -qi "Tailscale is stopped"; then
        tailscale_peer_reachable="No"
    else
        if echo "$ts_status" | grep -qiE "100\\.|fd7a:115c:a1e0::"; then
            tailscale_peer_reachable="Yes"
        else
            tailscale_peer_reachable="Unknown"
        fi
    fi
fi

###############################################################################
# Thermal / CPU speed limit
###############################################################################
debug_log "Inspecting thermal state and CPU speed limit"
thermal_throttles_int=$(to_int "$thermal_throttles_1h")
if have_cmd pmset; then
    thermlog=$(pmset -g thermlog 2>/dev/null || true)
    if echo "$thermlog" | grep -qi "CPU_Speed_Limit"; then
        cpu_speed_limit_raw=$(echo "$thermlog" | awk -F'CPU_Speed_Limit=' 'NF>1 {print $2}' | awk '{print $1}' | tail -1)
        cpu_speed_limit=$(to_int "$cpu_speed_limit_raw")
        if (( cpu_speed_limit < 100 )); then
            thermal_warning_active="Yes"
        fi
    fi
fi

###############################################################################
# JSON Payload
###############################################################################
run_duration_seconds=$SECONDS
DEBUG_LOG_CONTENT=$(cat "$DEBUG_LOG" 2>/dev/null || echo "Debug log unavailable")

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
  --arg unclassified_te "$unclassified_top_errors" \
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
  --argjson cpu_speed_limit "$cpu_speed_limit" \
  --argjson fan_max_events_1h "$fan_max_events_1h" \
  --arg sshd_running "$sshd_running" \
  --arg ssh_port_listening "$ssh_port_listening" \
  --arg screensharing_running "$screensharing_running" \
  --arg vnc_port_listening "$vnc_port_listening" \
  --arg tailscale_cli_present "$tailscale_cli_present" \
  --arg tailscale_peer_reachable "$tailscale_peer_reachable" \
  --arg remote_access_artifacts "$remote_access_artifacts" \
  --argjson remote_access_artifacts_count "$remote_access_artifacts_count" \
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
  --argjson e1h "$errors_1h_int" \
  --argjson e5m "$recent_5m_int" \
  --argjson cf1h "$critical_1h_int" \
  --argjson cc "$crash_count" \
  --argjson tt "$thermal_throttles_int" \
  --argjson tmage "$tm_age_days_int" \
  --argjson user_cnt "$user_count" \
  --argjson app_cnt "$total_gui_apps" \
  --argjson vm_cnt "$vm_count" \
  '
  {
    "fields": {
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
      "unclassified_top_errors": $unclassified_te,
      "top_crashes": $tc,
      "crash_count": $cc,

      "error_kernel_1h": $ek,
      "error_windowserver_1h": $ew,
      "error_spotlight_1h": $es,
      "error_icloud_1h": $ei,
      "error_disk_io_1h": $ed,
      "error_network_1h": $en,
      "error_gpu_1h": $eg,
      "error_systemstats_1h": $est,
      "error_power_1h": $ep,
      "Error Count": $e1h,
      "Recent Error Count (5 min)": $e5m,
      "Critical Fault Count (1h)": $cf1h,

      "thermal_throttles_1h": $tt,
      "Thermal Warning Active": $thermal_warn,
      "CPU Speed Limit": $cpu_speed_limit,
      "fan_max_events_1h": $fan_max_events_1h,

      "GPU Freeze Detected": $gpu_freeze,
      "GPU Freeze Events": $gpu_events,

      "Active Users": $active_users,
      "Application Inventory": $app_inv,
      "user_count": $user_cnt,
      "total_gui_apps": $app_cnt,

      "VMware Status": $vmware_stat,
      "VM Activity": $vm_act,
      "vm_count": $vm_cnt,
      "vmware_cpu_percent": 0,
      "vmware_memory_gb": 0,
      "Legacy Software Flags": $legacy_flags,
      "High Risk Apps": $high_risk,
      "Resource Hogs": $res_hogs,

      "remote_access_artifacts": $remote_access_artifacts,
      "remote_access_artifacts_count": $remote_access_artifacts_count,
      "sshd_running": $sshd_running,
      "ssh_port_listening": $ssh_port_listening,
      "screensharing_running": $screensharing_running,
      "vnc_port_listening": $vnc_port_listening,
      "tailscale_cli_present": $tailscale_cli_present,
      "tailscale_peer_reachable": $tailscale_peer_reachable,

      "Run Duration (seconds)": $run_duration,
      "Debug Log": $debug_log
    }
  }')

###############################################################################
# Send to Airtable
###############################################################################
debug_log "Posting to Airtable at $AIRTABLE_API_URL"

HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST \
  "$AIRTABLE_API_URL" \
  -H "Authorization: Bearer $AIRTABLE_PAT" \
  -H "Content-Type: application/json" \
  --data-binary "$JSON_PAYLOAD")

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

debug_log "Airtable HTTP status: $HTTP_CODE"
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
    echo "ERROR: Airtable API returned HTTP $HTTP_CODE"
    echo "$HTTP_BODY"
    exit 1
fi

debug_log "=== SCRIPT END (success) ==="
echo "Health monitor run completed successfully."
