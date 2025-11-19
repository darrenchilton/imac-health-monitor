#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
hostname=$(hostname)
macos_version=$(sw_vers -productVersion)

smart_status=$(safe_timeout 5 diskutil info disk0 2>/dev/null | awk -F': *' '/SMART Status/ {print $2}' | xargs)
[[ -z "$smart_status" ]] && smart_status="Unknown"

kernel_panics=$(safe_timeout 8 log show --predicate 'eventMessage contains "panic"' --last 24h 2>/dev/null | wc -l | tr -d ' ')

check_tm_age() {
    local path=$(safe_timeout 5 tmutil latestbackup 2>/dev/null)
    [[ -z "$path" ]] && echo "-1" && return
    local ts=$(stat -f "%m" "$path" 2>/dev/null)
    [[ -z "$ts" ]] && echo "-1" && return
    local now=$(date +%s)
    echo $(( (now - ts) / 86400 ))
}
tm_age_days=$(check_tm_age)

software_updates=$(safe_timeout 15 softwareupdate --list 2>&1 | \
    grep -q "No new software available" && echo "Up to Date" || echo "Unknown")

safe_log() { safe_timeout 12 log show --style syslog --last "$1" 2>/dev/null; }
LOG_1H=$(safe_log "1h")
LOG_5M=$(safe_log "5m")

count_in() { echo "$1" | grep -i "$2" | wc -l | tr -d ' '; }

errors_1h=$(count_in "$LOG_1H" "error")
recent_5m=$(count_in "$LOG_5M" "error")
critical_1h=$(count_in "$LOG_1H" "fault")

error_kernel_1h=$(count_in "$LOG_1H" "kernel")
error_windowserver_1h=$(count_in "$LOG_1H" "WindowServer")
error_spotlight_1h=$(count_in "$LOG_1H" "metadata")
error_icloud_1h=$(count_in "$LOG_1H" "icloud\|CloudKit")
error_disk_io_1h=$(count_in "$LOG_1H" "I/O error")
error_network_1h=$(count_in "$LOG_1H" "network\|dns\|resolver")
error_gpu_1h=$(count_in "$LOG_1H" "GPU\|AMDRadeon\|Metal")
error_systemstats_1h=$(count_in "$LOG_1H" "systemstats")
error_power_1h=$(count_in "$LOG_1H" "powerd")

thermal_throttles_1h=$(count_in "$LOG_1H" "Thermal")
fan_max_events_1h=$(count_in "$LOG_1H" "fan")

top_errors=$(echo "$LOG_1H" \
    | grep -i "error" \
    | sed 's/.*error/error/i' \
    | sort | uniq -c | sort -nr | head -3 \
    | awk '{$1=""; print substr($0,2)}' \
    | paste -sd " | " -)

crash_count=$(ls -1 ~/Library/Logs/DiagnosticReports/*.crash 2>/dev/null | wc -l | tr -d ' ')
top_crashes=$(ls -1t ~/Library/Logs/DiagnosticReports/*.crash 2>/dev/null | head -3 | sed 's/.*\///' | paste -sd "," -)

# Calculate additional metrics
drive_info=$(df -h / | awk 'NR==2 {printf "Total: %s, Used: %s (%s), Available: %s", $2, $3, $5, $4}')
uptime_val=$(uptime | awk '{print $3,$4}' | sed 's/,$//')
memory_pressure=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage:" | awk '{print $5}' || echo "N/A")
cpu_temp=$(osx-cpu-temp 2>/dev/null || echo "N/A")

# Format Kernel Panics text
if [[ "$kernel_panics" -eq 0 ]]; then
    kernel_panics_text="No kernel panics in last 24 hours"
else
    kernel_panics_text="${kernel_panics} kernel panic(s) detected in last 24 hours"
fi

# Format System Errors text with burst detection
system_errors_text="Log Activity: ${errors_1h} errors (${recent_5m} recent, ${critical_1h} critical)"

# Format Time Machine status
tm_status="Configured; Latest: Unable to determine"
if [[ "$tm_age_days" -ne -1 && "$tm_age_days" -gt 0 ]]; then
    # Calculate the date X days ago
    backup_date=$(date -v-${tm_age_days}d '+%Y-%m-%d' 2>/dev/null || date -d "${tm_age_days} days ago" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")
    tm_status="Configured; Latest: ${backup_date}"
elif [[ "$tm_age_days" -eq 0 ]]; then
    tm_status="Configured; Latest: $(date '+%Y-%m-%d')"
fi

# Determine severity and health score based on error analysis
# Key insight: Compare recent (5m) vs total (1h) errors to detect active vs resolved issues
if [[ "$recent_5m" -gt 50 ]]; then
    severity="Critical"
    health_score_label="Attention Needed"
    reasons="Active error burst detected (${recent_5m} errors in last 5 min)"
elif [[ "$recent_5m" -gt 20 ]]; then
    severity="Warning"
    health_score_label="Attention Needed"
    reasons="Elevated recent errors (${recent_5m} errors in last 5 min)"
elif [[ "$errors_1h" -gt 200 && "$recent_5m" -lt 10 ]]; then
    severity="Info"
    health_score_label="Healthy"
    reasons="Historical errors present but currently resolved (${errors_1h} total, ${recent_5m} recent)"
elif [[ "$critical_1h" -gt 10 ]]; then
    severity="Warning"
    health_score_label="Attention Needed"
    reasons="Elevated critical errors (${critical_1h} faults in last hour)"
else
    severity="Info"
    health_score_label="Healthy"
    reasons="System operating normally"
fi

# Adjust for hardware issues
[[ "$smart_status" != "Verified" && "$smart_status" != "Unknown" ]] && severity="Critical" && health_score_label="Attention Needed" && reasons="SMART status: ${smart_status}"
[[ "$kernel_panics" -gt 0 ]] && severity="Critical" && health_score_label="Attention Needed" && reasons="Kernel panic detected"
[[ "$tm_age_days" -gt 7 ]] && severity="Warning" && health_score_label="Attention Needed" && reasons="${reasons}; Time Machine backup overdue (${tm_age_days} days)"

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
  '{fields: {
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
      "fan_max_events_1h": $fm
  }}')


TABLE_ENCODED=$(echo "$AIRTABLE_TABLE_NAME" | sed 's/ /%20/g')

RESPONSE=$(curl -s -X POST \
  "https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$TABLE_ENCODED" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")

if echo "$RESPONSE" | grep -q '"id"'; then
    echo "Airtable Update: SUCCESS"
else
    echo "Airtable Update: FAILED"
    echo "$RESPONSE"
fi

echo "$JSON_PAYLOAD"