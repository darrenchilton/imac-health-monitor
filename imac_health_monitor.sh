#!/bin/bash

################################################################################
# iMac Health Monitor Script
#
# Collects system health metrics on macOS and sends them to Airtable.
# Designed to be run manually or via launchd (e.g., once a day).
################################################################################

set -euo pipefail

# Directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${HOME}/Library/Logs/imac_health_monitor.log"

###############################################################################
# Logging helpers
###############################################################################

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info()  { log_message "INFO"  "$1"; }
log_warn()  { log_message "WARN"  "$1"; }
log_error() { log_message "ERROR" "$1"; }

###############################################################################
# Load environment (.env)
###############################################################################

ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    log_error "Missing .env file at $ENV_FILE. Please run setup.sh first."
    exit 1
fi

set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport

# Validate required env vars
REQUIRED_VARS=("AIRTABLE_API_KEY" "AIRTABLE_BASE_ID" "AIRTABLE_TABLE_NAME")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        log_error "Required environment variable $var is not set in .env"
        exit 1
    fi
done

###############################################################################
# Utility: safe command execution
###############################################################################

run_cmd() {
    local description="$1"
    shift
    local output

    log_info "Running: $description"
    if ! output="$("$@" 2>&1)"; then
        log_warn "Command failed: $description"
        log_warn "Error output: $output"
        echo "Unavailable"
        return 1
    fi

    echo "$output"
    return 0
}

###############################################################################
# Metric Collection Functions
###############################################################################

get_timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

get_hostname() {
    hostname
}

get_macos_version() {
    sw_vers -productVersion
}

# Function to check SMART status using "diskutil"
get_smart_status() {
    local smart_status
    smart_status=$(diskutil info / | grep "SMART Status" | awk -F: '{print $2}' | xargs)

    if [ -z "$smart_status" ]; then
        smart_status="Not Available"
    fi
    echo "$smart_status"
}

# Function to check for recent kernel panics (last 24 hours)
get_kernel_panics() {
    local since timeframe
    # last 24 hours
    timeframe="24 hours"
    since="24h"

    if ! command -v log >/dev/null 2>&1; then
        echo "log command unavailable"
        return
    fi

    # Count panic lines in last 24h
    local count
    count=$(log show --predicate 'eventMessage CONTAINS "panic(cpu" OR eventMessage CONTAINS "panicString"' --style syslog --last "$since" 2>/dev/null | wc -l | tr -d ' ')

    if [ -z "$count" ]; then
        count=0
    fi

    if [ "$count" -eq 0 ]; then
        echo "No kernel panics in last $timeframe"
    else
        echo "$count kernel panic-related log entries in last $timeframe"
    fi
}

# Function to check macOS unified logs for system errors and critical events
get_system_errors() {
    # Last 1 hour of errors/critical logs
    if ! command -v log >/dev/null 2>&1; then
        echo "log command unavailable"
        return
    fi

    local last="1h"
    local all_errors critical_count error_count

    all_errors=$(log show --predicate 'messageType == error OR messageType == fault' --style syslog --last "$last" 2>/dev/null || true)
    error_count=$(printf "%s" "$all_errors" | wc -l | tr -d ' ')

    # Check for "critical" severity in the same time window
    local all_critical
    all_critical=$(log show --predicate 'messageType == fault OR eventMessage CONTAINS "critical"' --style syslog --last "$last" 2>/dev/null || true)
    critical_count=$(printf "%s" "$all_critical" | wc -l | tr -d ' ')

    echo "Errors: $error_count, Critical: $critical_count (last 1h)"
}

# Function to get drive space in GiB and % used for the root volume
get_drive_space() {
    # Use df with -g to show GiB and filter root filesystem (/)
    if ! command -v df >/dev/null 2>&1; then
        echo "df command unavailable"
        return
    fi

    local df_output total used avail percent_used
    df_output=$(df -g / | tail -1)

    # Example output columns: Filesystem, 512-blocks, Used, Avail, Capacity, iused, ifree, %iused, Mounted on
    # but with -g we expect: Filesystem, 512-blocks, Used, Avail, Capacity, iused, ifree, %iused, Mounted on
    # We'll parse the 'Used' and 'Avail' (Gi) and 'Capacity'
    total=$(echo "$df_output" | awk '{print $2}')
    used=$(echo "$df_output" | awk '{print $3}')
    avail=$(echo "$df_output" | awk '{print $4}')
    percent_used=$(echo "$df_output" | awk '{print $5}' | tr -d '%')

    # Some systems may have capacity with % sign; if parsing fails, fallback
    if [ -z "$total" ] || [ -z "$used" ] || [ -z "$avail" ]; then
        echo "Unable to parse disk usage"
        return
    fi

    echo "Total: ${total}Gi, Used: ${used}Gi (${percent_used}%), Available: ${avail}Gi"
}

# Function to get system uptime
get_uptime() {
    # 'uptime' output, e.g. "10:15  up  3 days,  2:34, 2 users, load averages: 1.23 1.09 0.88"
    local raw uptime_str
    raw=$(uptime)
    # Extract "up ..." portion
    uptime_str=$(echo "$raw" | sed 's/.*up *//; s/, *[0-9]* users.*$//')
    echo "$uptime_str"
}

# Function to get memory pressure / usage
get_memory_pressure() {
    # We can derive "used" vs "total" from vm_stat + page size
    if ! command -v vm_stat >/dev/null 2>&1; then
        echo "vm_stat command unavailable"
        return
    fi

    local pages_free pages_active pages_inactive pages_speculative pages_wired pages_compressed page_size
    page_size=$(vm_stat | head -1 | awk '{print $8}' | tr -d '.')
    pages_free=$(vm_stat | awk '/Pages free/ {print $3}' | tr -d '.')
    pages_active=$(vm_stat | awk '/Pages active/ {print $3}' | tr -d '.')
    pages_inactive=$(vm_stat | awk '/Pages inactive/ {print $3}' | tr -d '.')
    pages_speculative=$(vm_stat | awk '/Pages speculative/ {print $3}' | tr -d '.')
    pages_wired=$(vm_stat | awk '/Pages wired down/ {print $4}' | tr -d '.')
    pages_compressed=$(vm_stat | awk '/Pages occupied by compressor/ {print $5}' | tr -d '.')

    local total_pages used_pages
    total_pages=$((pages_free + pages_active + pages_inactive + pages_speculative + pages_wired + pages_compressed))
    used_pages=$((total_pages - pages_free))

    local total_mem_gb used_mem_gb used_percent
    total_mem_gb=$(echo "$total_pages * $page_size / 1024 / 1024 / 1024" | bc -l)
    used_mem_gb=$(echo "$used_pages * $page_size / 1024 / 1024 / 1024" | bc -l)
    used_percent=$(echo "scale=2; ($used_pages / $total_pages) * 100" | bc -l)

    printf "Used: %.1fGi (%.1f%%), Total: %.1fGi" "$used_mem_gb" "$used_percent" "$total_mem_gb"
}

# Function to get CPU temperature
get_cpu_temp() {
    # Requires osx-cpu-temp installed via Homebrew
    if ! command -v osx-cpu-temp >/dev/null 2>&1; then
        echo "Unavailable (osx-cpu-temp not installed)"
        return
    fi

    # osx-cpu-temp output example: "56.8°C"
    local temp
    temp=$(osx-cpu-temp 2>/dev/null || true)
    if [ -z "$temp" ]; then
        echo "Unavailable"
    else
        echo "$temp"
    fi
}

# Function to check Time Machine status with fallback
get_time_machine_status() {
    # Prefer tmutil when available
    if command -v tmutil >/dev/null 2>&1; then
        # Try to get latest backup info
        local latest_backup
        latest_backup=$(tmutil latestbackup 2>/dev/null || true)
        if [ -n "$latest_backup" ]; then
            local latest_date
            latest_date=$(tmutil machinedirectory 2>/dev/null || true)
            echo "Configured; Latest: $(date -r "$(stat -f %m "$latest_backup")" +"%Y-%m-%d %H:%M:%S")"
            return
        fi

        # If no latest backup, see if any destinations exist
        local dest_info
        dest_info=$(tmutil destinationinfo 2>/dev/null || true)
        if [ -n "$dest_info" ]; then
            echo "Configured but no completed backups found"
            return
        fi
    fi

    # Fallback: check for Time Machine backup folders in /Volumes
    local tm_dirs
    tm_dirs=$(find /Volumes -maxdepth 3 -type d -name "Backups.backupdb" 2>/dev/null || true)
    if [ -n "$tm_dirs" ]; then
        echo "Backup folders found, but could not determine latest backup time (consider granting Full Disk Access)."
    else
        echo "Not configured or no Time Machine backups found"
    fi
}

###############################################################################
# Airtable API Helper
###############################################################################

send_to_airtable() {
    local payload="$1"

    if [ -z "$AIRTABLE_API_KEY" ] || [ -z "$AIRTABLE_BASE_ID" ] || [ -z "$AIRTABLE_TABLE_NAME" ]; then
        log_error "Airtable environment variables missing. Skipping send."
        return 1
    fi

    local url="https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}"

    log_info "Sending data to Airtable..."
    local response
    response=$(curl -sS -X POST "$url" \
        -H "Authorization: Bearer ${AIRTABLE_API_KEY}" \
        -H "Content-Type: application/json" \
        --data "$payload" 2>&1) || {
            log_error "Failed to send data to Airtable."
            log_error "curl output: $response"
            return 1
        }

    if echo "$response" | grep -q '"error"'; then
        log_error "Airtable API returned an error:"
        log_error "$response"
        return 1
    fi

    log_info "Successfully sent data to Airtable."
    return 0
}

###############################################################################
# Collect Metrics
###############################################################################

log_info "=== Starting iMac health check ==="

TIMESTAMP=$(get_timestamp)
HOSTNAME=$(get_hostname)
MACOS_VERSION=$(get_macos_version)

SMART_STATUS=$(get_smart_status)
KERNEL_PANICS=$(get_kernel_panics)
SYSTEM_ERRORS=$(get_system_errors)
DRIVE_SPACE=$(get_drive_space)
UPTIME=$(get_uptime)
MEMORY=$(get_memory_pressure)
CPU_TEMP=$(get_cpu_temp)
TM_STATUS=$(get_time_machine_status)

log_info "Collected metrics:"
log_info "Timestamp: $TIMESTAMP"
log_info "Hostname: $HOSTNAME"
log_info "macOS Version: $MACOS_VERSION"
log_info "SMART Status: $SMART_STATUS"
log_info "Kernel Panics: $KERNEL_PANICS"
log_info "System Errors: $SYSTEM_ERRORS"
log_info "Drive Space: $DRIVE_SPACE"
log_info "Uptime: $UPTIME"
log_info "Memory Pressure: $MEMORY"
log_info "CPU Temperature: $CPU_TEMP"
log_info "Time Machine: $TM_STATUS"

###############################################################################
# Derive numeric values for Health Score evaluation
###############################################################################

# Disk usage: extract percentage from "Total: X, Used: Y (Z%), Available: A"
PERCENT_USED_NUM=$(echo "$DRIVE_SPACE" | sed -n 's/.*(\([0-9]\+\)%).*/\1/p')
[ -z "$PERCENT_USED_NUM" ] && PERCENT_USED_NUM=0

# CPU temp: extract numeric part from e.g. "56.8°C"
CPU_TEMP_NUM=$(echo "$CPU_TEMP" | sed 's/[^0-9.]//g')
CPU_TEMP_INT=0
if [ -n "$CPU_TEMP_NUM" ]; then
    CPU_TEMP_INT=${CPU_TEMP_NUM%.*}
fi

# System errors: extract "Errors: N, Critical: M (last 1h)"
ERROR_COUNT_NUM=$(echo "$SYSTEM_ERRORS" | sed -n 's/Errors: \([0-9]\+\).*/\1/p')
[ -z "$ERROR_COUNT_NUM" ] && ERROR_COUNT_NUM=0

CRITICAL_COUNT_NUM=$(echo "$SYSTEM_ERRORS" | sed -n 's/.*Critical: \([0-9]\+\).*/\1/p')
[ -z "$CRITICAL_COUNT_NUM" ] && CRITICAL_COUNT_NUM=0

###############################################################################
# Time Machine - compute days since last backup (if present)
###############################################################################
TM_NEEDS_ATTENTION=false
TM_LAST_BACKUP_DAYS=0

# Extract date like: "Latest: 2025-11-18 05:42:36"
LATEST_DATE=$(echo "$TM_STATUS" | grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2}")
LATEST_TIME=$(echo "$TM_STATUS" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}")

if [ -n "$LATEST_DATE" ] && [ -n "$LATEST_TIME" ]; then
    LAST_BACKUP_TS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LATEST_DATE $LATEST_TIME" +%s 2>/dev/null || echo "")
    if [ -n "$LAST_BACKUP_TS" ]; then
        NOW_TS=$(date +%s)
        TM_LAST_BACKUP_DAYS=$(( (NOW_TS - LAST_BACKUP_TS) / 86400 ))
    fi
else
    TM_NEEDS_ATTENTION=true
fi

###############################################################################
# Health Score, Severity, and Reasons
###############################################################################

HEALTH_SCORE="Healthy"
SEVERITY="Info"
REASONS=""

# Helper: bump severity from Info -> Warning (but never down)
bump_to_warning() {
    if [ "$SEVERITY" = "Info" ]; then
        SEVERITY="Warning"
    fi
}

bump_to_critical() {
    SEVERITY="Critical"
}

# SMART status: treat "Not Available" as neutral, anything else as Critical
if [ "$SMART_STATUS" != "Verified" ] && [ "$SMART_STATUS" != "Not Available" ]; then
    bump_to_critical
    REASONS+="SMART status is '$SMART_STATUS'. "
fi

# Kernel panics in last 24h (always Critical if any)
if echo "$KERNEL_PANICS" | grep -q "kernel panic-related log entries"; then
    KERNEL_PANIC_COUNT=$(echo "$KERNEL_PANICS" | grep -Eo '^[0-9]+' | head -n1)
    if [ -z "$KERNEL_PANIC_COUNT" ]; then
        KERNEL_PANIC_COUNT=0
    fi
    if [ "$KERNEL_PANIC_COUNT" -gt 0 ]; then
        bump_to_critical
        REASONS+="Kernel panics in last 24 hours: $KERNEL_PANIC_COUNT. "
    fi
fi

# Disk usage thresholds
if [ "$PERCENT_USED_NUM" -ge 90 ] 2>/dev/null; then
    bump_to_critical
    REASONS+="Disk usage ${PERCENT_USED_NUM}% (>= 90%). "
elif [ "$PERCENT_USED_NUM" -ge 80 ] 2>/dev/null; then
    bump_to_warning
    REASONS+="Disk usage ${PERCENT_USED_NUM}% (>= 80%). "
fi

# CPU temperature thresholds
if [ "$CPU_TEMP_INT" -ge 85 ] && [ "$CPU_TEMP_INT" -lt 120 ]; then
    bump_to_critical
    REASONS+="CPU temp ${CPU_TEMP_INT}°C (>= 85°C). "
elif [ "$CPU_TEMP_INT" -ge 80 ] && [ "$CPU_TEMP_INT" -lt 85 ]; then
    bump_to_warning
    REASONS+="CPU temp ${CPU_TEMP_INT}°C (>= 80°C). "
fi

# System log errors / criticals
if [ "$CRITICAL_COUNT_NUM" -gt 0 ]; then
    bump_to_critical
    REASONS+="Critical log messages: ${CRITICAL_COUNT_NUM}. "
fi

if [ "$ERROR_COUNT_NUM" -gt 2000 ]; then
    bump_to_critical
    REASONS+="Error count very high (${ERROR_COUNT_NUM}). "
elif [ "$ERROR_COUNT_NUM" -gt 500 ]; then
    bump_to_warning
    REASONS+="Error count elevated (${ERROR_COUNT_NUM}). "
fi

# Time Machine thresholds
if [ "$TM_NEEDS_ATTENTION" = true ]; then
    bump_to_critical
    REASONS+="Time Machine not configured or destination missing. "
elif [ "$TM_LAST_BACKUP_DAYS" -ge 7 ]; then
    bump_to_critical
    REASONS+="Last Time Machine backup ${TM_LAST_BACKUP_DAYS} days ago (>= 7 days). "
elif [ "$TM_LAST_BACKUP_DAYS" -ge 3 ]; then
    bump_to_warning
    REASONS+="Last Time Machine backup ${TM_LAST_BACKUP_DAYS} days ago (>= 3 days). "
fi

# Derive Health Score from Severity
if [ "$SEVERITY" = "Info" ]; then
    HEALTH_SCORE="Healthy"
else
    HEALTH_SCORE="Attention Needed"
fi

# Friendly default reason
if [ -z "$REASONS" ]; then
    if [ "$HEALTH_SCORE" = "Healthy" ]; then
        REASONS="All checks passed within defined thresholds."
    else
        REASONS="Issues detected but not individually described."
    fi
fi

log_info "Final Health Score: $HEALTH_SCORE"
log_info "Severity: $SEVERITY"
log_info "Reasons: $REASONS"

###############################################################################
# Build JSON payload for Airtable
###############################################################################

# Escape double quotes in text fields for JSON safety
json_escape() {
    echo "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

JSON_TIMESTAMP=$(json_escape "$TIMESTAMP")
JSON_HOSTNAME=$(json_escape "$HOSTNAME")
JSON_MACOS_VERSION=$(json_escape "$MACOS_VERSION")
JSON_SMART_STATUS=$(json_escape "$SMART_STATUS")
JSON_KERNEL_PANICS=$(json_escape "$KERNEL_PANICS")
JSON_SYSTEM_ERRORS=$(json_escape "$SYSTEM_ERRORS")
JSON_DRIVE_SPACE=$(json_escape "$DRIVE_SPACE")
JSON_UPTIME=$(json_escape "$UPTIME")
JSON_MEMORY=$(json_escape "$MEMORY")
JSON_CPU_TEMP=$(json_escape "$CPU_TEMP")
JSON_TM_STATUS=$(json_escape "$TM_STATUS")
JSON_HEALTH_SCORE=$(json_escape "$HEALTH_SCORE")
JSON_SEVERITY=$(json_escape "$SEVERITY")
JSON_REASONS=$(json_escape "$REASONS")

JSON_PAYLOAD=$(cat <<EOF
{
  "fields": {
    "Timestamp": "$JSON_TIMESTAMP",
    "Hostname": "$JSON_HOSTNAME",
    "macOS Version": "$JSON_MACOS_VERSION",
    "SMART Status": "$JSON_SMART_STATUS",
    "Kernel Panics": "$JSON_KERNEL_PANICS",
    "System Errors": "$JSON_SYSTEM_ERRORS",
    "Drive Space": "$JSON_DRIVE_SPACE",
    "Uptime": "$JSON_UPTIME",
    "Memory Pressure": "$JSON_MEMORY",
    "CPU Temperature": "$JSON_CPU_TEMP",
    "Time Machine": "$JSON_TM_STATUS",
    "Health Score": "$JSON_HEALTH_SCORE",
    "Severity": "$JSON_SEVERITY",
    "Reasons": "$JSON_REASONS"
  }
}
EOF
)

log_info "JSON payload prepared for Airtable."

###############################################################################
# Send to Airtable
###############################################################################

if send_to_airtable "$JSON_PAYLOAD"; then
    log_info "Health data successfully recorded in Airtable."
else
    log_error "Failed to record health data in Airtable."
fi

log_info "=== Health check completed ==="
echo ""
