#!/bin/bash

################################################################################
# iMac Health Monitor - Burst-Aware Edition with Software Updates
# Collects system health metrics and sends to Airtable
# Created: November 17, 2025
# Updated: November 18, 2025 - Added software updates monitoring
# Version: 2.1 - Software Updates Feature
#
# Changes from v2.0:
# - Added check_software_updates() function to monitor macOS updates
# - Uses safe_timeout to prevent hanging on slow Apple server responses
# - Parses update count and details (labels) from softwareupdate --list
# - Added "Software Updates" field to Airtable payload
# - Does NOT affect health score (informational only)
################################################################################

# Determine script location
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load configuration from .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
elif [ -f "$HOME/.config/imac-health-monitor/.env" ]; then
    source "$HOME/.config/imac-health-monitor/.env"
else
    echo "ERROR: .env file not found!"
    echo "Please create .env file with your Airtable credentials"
    echo "See .env.example for template"
    exit 1
fi

# Verify required configuration
if [ -z "$AIRTABLE_API_KEY" ] || [ -z "$AIRTABLE_BASE_ID" ]; then
    echo "ERROR: AIRTABLE_API_KEY or AIRTABLE_BASE_ID not set in .env"
    exit 1
fi

# Set defaults
AIRTABLE_TABLE_NAME="${AIRTABLE_TABLE_NAME:-System Health}"

# Noise filtering for macOS log spam:
# 1 = ignore normal background errors, only alert on real/sustained problems
# 0 = use more sensitive / legacy-style log-based alerts
NOISE_FILTERING="${NOISE_FILTERING:-1}"

LOG_FILE="$HOME/Library/Logs/imac_health_monitor.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages (FIXED: no longer pollutes function outputs)
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_message "=== Starting iMac Health Check (v2.1 - Software Updates) ==="

###############################################################################
# Helper utilities for robustness
###############################################################################

# Helper: command availability
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Helper: run with timeout if available (gtimeout/timeout), otherwise no timeout
safe_timeout() {
    local seconds="$1"; shift

    if have_cmd gtimeout; then
        gtimeout "${seconds}s" "$@"
    elif have_cmd timeout; then
        timeout "${seconds}s" "$@"
    else
        # No timeout tool; just run the command (better than silently skipping)
        "$@"
    fi
}

# Helper: safely capture output of a function/command without letting failures
# poison downstream logic.
# Usage: safe_get VAR_NAME some_function
safe_get() {
    local __var="$1"; shift
    local __out rc

    __out="$("$@" 2>&1)"
    rc=$?

    if [ $rc -ne 0 ]; then
        log_message "WARN: $* failed with rc=$rc, output: $__out"
        __out="Unavailable (error running $*)"
    fi

    printf -v "$__var" '%s' "$__out"
}

###############################################################################
# SMART status for external boot drive
###############################################################################

get_smart_status() {
    if ! have_cmd diskutil; then
        log_message "WARN: diskutil not found; SMART status unavailable"
        echo "Not Available"
        return 0
    fi

    local BOOT_DRIVE DISK_ID SMART_OUTPUT SMART_STATUS

    BOOT_DRIVE=$(diskutil info / 2>/dev/null | awk -F': *' '/Device Node:/ {print $2}')
    if [ -z "$BOOT_DRIVE" ]; then
        log_message "WARN: Unable to determine boot drive"
        echo "Not Available"
        return 0
    fi

    # Get disk identifier without partition (e.g., disk2s1 -> disk2)
    DISK_ID=$(echo "$BOOT_DRIVE" | sed 's/s[0-9]*$//')

    log_message "Checking SMART status for boot drive: $DISK_ID"

    SMART_OUTPUT=$(diskutil info "$DISK_ID" 2>/dev/null)
    SMART_STATUS=$(echo "$SMART_OUTPUT" | awk -F': *' '/SMART Status:/ {print $2}' | xargs)

    if [ -z "$SMART_STATUS" ]; then
        SMART_STATUS="Not Available"
    fi

    echo "$SMART_STATUS"
}

###############################################################################
# Kernel panics (last 24 hours)
###############################################################################
# Returns: "<COUNT>|<HUMAN_READABLE_MESSAGE>"
check_kernel_panics() {
    log_message "Checking for kernel panics..."

    local LOG_DIR="/Library/Logs/DiagnosticReports"

    if [ ! -d "$LOG_DIR" ]; then
        echo "0|No DiagnosticReports directory found"
        return 0
    fi

    local COUNT
    COUNT=$(find "$LOG_DIR" -name "Kernel_*.panic" -mmin -1440 2>/dev/null | wc -l | xargs)

    # Ensure COUNT is numeric
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        COUNT=0
    fi

    if [ "$COUNT" -gt 0 ]; then
        local LATEST_PANIC
        # Sort by mtime and take the newest
        LATEST_PANIC=$(find "$LOG_DIR" -name "Kernel_*.panic" -mmin -1440 -print0 2>/dev/null \
            | xargs -0 ls -1t 2>/dev/null | head -1)
        local MSG="Found $COUNT panic(s) in last 24 hours."
        if [ -n "$LATEST_PANIC" ]; then
            MSG+=" Latest: $(basename "$LATEST_PANIC")"
        fi
        echo "${COUNT}|${MSG}"
    else
        echo "0|No kernel panics in last 24 hours"
    fi
}

###############################################################################
# Burst detection - check if errors are recent or historical
# NEW in v2.0: Distinguishes between active problems and cleared bursts
###############################################################################
###############################################################################
# Burst detection - check if errors are recent or historical (noise-aware)
###############################################################################
check_error_burst() {
    if ! have_cmd log; then
        # RECENT|TOTAL|CRITICAL
        echo "0|0|0"
        return 0
    fi

    # Errors in last 5 minutes (recent activity)
    local RECENT_ERRORS
    RECENT_ERRORS=$(safe_timeout 5 log show --predicate 'messageType == error' --last 5m 2>/dev/null \
        | wc -l | xargs)
    [ -z "$RECENT_ERRORS" ] && RECENT_ERRORS=0

    # Errors in last hour (historical volume)
    local TOTAL_ERRORS
    TOTAL_ERRORS=$(safe_timeout 10 log show --predicate 'messageType == error' --last 1h 2>/dev/null \
        | wc -l | xargs)
    [ -z "$TOTAL_ERRORS" ] && TOTAL_ERRORS=0

    # Critical faults in last hour
    local CRITICAL_COUNT
    CRITICAL_COUNT=$(safe_timeout 10 log show --predicate 'messageType == fault' --last 1h 2>/dev/null \
        | wc -l | xargs)
    [ -z "$CRITICAL_COUNT" ] && CRITICAL_COUNT=0

    # RECENT|TOTAL|CRITICAL
    echo "${RECENT_ERRORS}|${TOTAL_ERRORS}|${CRITICAL_COUNT}"
}

###############################################################################
# System log errors (noise-aware summary)
###############################################################################
check_system_errors() {
    log_message "Checking system logs for errors (noise-aware)..."

    if ! have_cmd log; then
        echo "System log tool not available|0|0|0"
        return 0
    fi

    local BURST_INFO RECENT_ERRORS TOTAL_ERRORS CRITICAL_COUNT
    BURST_INFO=$(check_error_burst)

    RECENT_ERRORS=$(echo "$BURST_INFO" | cut -d'|' -f1)
    TOTAL_ERRORS=$(echo "$BURST_INFO" | cut -d'|' -f2)
    CRITICAL_COUNT=$(echo "$BURST_INFO" | cut -d'|' -f3)

    # NOTE: format preserved to match existing parsing later in the script:
    # display_message|total_errors|critical_count|recent_errors
    echo "Log Activity: ${TOTAL_ERRORS} errors (1h), ${RECENT_ERRORS} recent (5m), ${CRITICAL_COUNT} critical (1h)|${TOTAL_ERRORS}|${CRITICAL_COUNT}|${RECENT_ERRORS}"
}


###############################################################################
# Drive space info
###############################################################################
get_drive_space() {
    log_message "Checking drive space..."

    if ! have_cmd df; then
        echo "Total: Unknown, Used: Unknown (Unknown), Available: Unknown"
        return 0
    fi

    local BOOT_INFO TOTAL USED AVAILABLE PERCENT_USED
    BOOT_INFO=$(df -h "$HOME" 2>/dev/null | tail -1)

    if [ -z "$BOOT_INFO" ]; then
        echo "Total: Unknown, Used: Unknown (Unknown), Available: Unknown"
        return 0
    fi

    TOTAL=$(echo "$BOOT_INFO" | awk '{print $2}')
    USED=$(echo "$BOOT_INFO" | awk '{print $3}')
    AVAILABLE=$(echo "$BOOT_INFO" | awk '{print $4}')
    PERCENT_USED=$(echo "$BOOT_INFO" | awk '{print $5}')

    echo "Total: $TOTAL, Used: $USED ($PERCENT_USED), Available: $AVAILABLE"
}

###############################################################################
# System uptime
###############################################################################
get_uptime() {
    local UPTIME
    UPTIME=$(uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
    [ -z "$UPTIME" ] && UPTIME="Unknown"
    echo "$UPTIME"
}

###############################################################################
# Memory pressure
###############################################################################
get_memory_pressure() {
    if ! have_cmd vm_stat; then
        echo "Unavailable"
        return 0
    fi

    local MEMORY_INFO
    MEMORY_INFO=$(vm_stat 2>/dev/null | awk '
        /Pages free/     {gsub("\\.", "", $3); free=$3}
        /Pages active/   {gsub("\\.", "", $3); active=$3}
        /Pages inactive/ {gsub("\\.", "", $3); inactive=$3}
        /Pages wired/    {gsub("\\.", "", $3); wired=$3}
        END {
            total = free + active + inactive + wired
            if (total <= 0) {
                print "Unavailable"
            } else {
                used_percent = ((active + wired) / total) * 100
                printf "%.1f%% used", used_percent
            }
        }
    ')
    echo "$MEMORY_INFO"
}

###############################################################################
# CPU temperature (if available)
###############################################################################
get_cpu_temp() {
    # Try common Homebrew locations first
    if [ -x "/opt/homebrew/bin/osx-cpu-temp" ]; then
        /opt/homebrew/bin/osx-cpu-temp
        return
    fi

    if [ -x "/usr/local/bin/osx-cpu-temp" ]; then
        /usr/local/bin/osx-cpu-temp
        return
    fi

    # Fallback: rely on PATH (interactive shells)
    if have_cmd osx-cpu-temp; then
        osx-cpu-temp
        return
    fi

    echo "Unavailable"
}

###############################################################################
# Time Machine backup status (no FDA required)
###############################################################################
check_time_machine() {
    log_message "Checking Time Machine status..."

    local STATUS="Not configured"

    # Check if Time Machine is running
    local TM_RAW_STATUS
    TM_RAW_STATUS=$(tmutil status 2>/dev/null || true)

    if [ -n "$TM_RAW_STATUS" ]; then
        if echo "$TM_RAW_STATUS" | grep -q "Running = 1"; then
            local PHASE
            PHASE=$(echo "$TM_RAW_STATUS" \
                | awk -F'= ' '/BackupPhase/ {gsub(/[;"]/, "", $2); gsub(/^ *| *$/, "", $2); print $2; exit}')
            if [ -n "$PHASE" ]; then
                STATUS="Backup in progress ($PHASE)"
            else
                STATUS="Backup in progress"
            fi
        else
            STATUS="Configured"
        fi
    else
        echo "Not configured"
        return
    fi

    # Try tmutil commands first (require Full Disk Access)
    local TM_LATEST
    TM_LATEST=$(tmutil latestbackup 2>/dev/null || true)

    if [ -n "$TM_LATEST" ] && ! echo "$TM_LATEST" | grep -q "requires Full Disk Access"; then
        # Success with tmutil latestbackup
        if [[ "$TM_LATEST" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}) ]]; then
            local TIMESTAMP="${BASH_REMATCH[1]}"
            local DATE_PART="${TIMESTAMP:0:10}"
            local TIME_PART="${TIMESTAMP:11:2}:${TIMESTAMP:13:2}:${TIMESTAMP:15:2}"
            echo "$STATUS; Latest: $DATE_PART $TIME_PART"
        else
            local BACKUP_NAME
            BACKUP_NAME=$(basename "$TM_LATEST")
            echo "$STATUS; Latest: $BACKUP_NAME"
        fi
        return
    fi

    # Fallback: Use filesystem access (works without Full Disk Access)
    local DEST_INFO
    DEST_INFO=$(tmutil destinationinfo 2>/dev/null || true)

    if [ -z "$DEST_INFO" ]; then
        echo "$STATUS; No destination configured"
        return
    fi

    # Extract mount point
    local MOUNT_POINT
    MOUNT_POINT=$(echo "$DEST_INFO" | grep "Mount Point" | head -1 | awk -F': ' '{print $2}' | xargs)

    if [ -z "$MOUNT_POINT" ]; then
        echo "$STATUS; Destination not mounted"
        return
    fi

    # Get machine name
    local MACHINE_NAME
    MACHINE_NAME=$(hostname -s)

    # Check standard Time Machine structure
    local BACKUP_DIR="$MOUNT_POINT/Backups.backupdb/$MACHINE_NAME"

    if [ -d "$BACKUP_DIR" ]; then
        local LATEST_BACKUP
        LATEST_BACKUP=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$" | tail -1)

        if [ -n "$LATEST_BACKUP" ]; then
            local DATE_PART="${LATEST_BACKUP:0:10}"
            local TIME_PART="${LATEST_BACKUP:11:2}:${LATEST_BACKUP:13:2}:${LATEST_BACKUP:15:2}"
            echo "$STATUS; Latest: $DATE_PART $TIME_PART"
            return
        fi
    fi

    # Check APFS snapshot-style backups
    local ALT_BACKUP_DIR="$MOUNT_POINT/.timemachine"

    if [ -d "$ALT_BACKUP_DIR" ]; then
        local LATEST_BACKUP
        LATEST_BACKUP=$(find "$ALT_BACKUP_DIR" -maxdepth 2 -name "*.backup" -type d 2>/dev/null | sort | tail -1)

        if [ -n "$LATEST_BACKUP" ]; then
            local BACKUP_NAME
            BACKUP_NAME=$(basename "$LATEST_BACKUP" .backup)
            if [[ "$BACKUP_NAME" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}) ]]; then
                local TIMESTAMP="${BASH_REMATCH[1]}"
                local DATE_PART="${TIMESTAMP:0:10}"
                local TIME_PART="${TIMESTAMP:11:2}:${TIMESTAMP:13:2}:${TIMESTAMP:15:2}"
                echo "$STATUS; Latest: $DATE_PART $TIME_PART"
                return
            else
                echo "$STATUS; Latest: $BACKUP_NAME"
                return
            fi
        fi
    fi

    echo "$STATUS; Drive mounted, checking filesystem access..."
}

###############################################################################
# Software Updates Available
###############################################################################
# Returns: "Up to Date" or "N updates available: details"
check_software_updates() {
    log_message "Checking for software updates..."
    
    if ! have_cmd softwareupdate; then
        echo "Update tool not available"
        return 0
    fi
    
    # Use timeout to prevent hanging (softwareupdate can be slow)
    local UPDATE_CHECK
    UPDATE_CHECK=$(safe_timeout 60 softwareupdate --list 2>&1)
    
    # Check if updates were found
    if echo "$UPDATE_CHECK" | grep -q "Software Update found"; then
        # Count updates (lines starting with *)
        local UPDATE_COUNT
        UPDATE_COUNT=$(echo "$UPDATE_CHECK" | grep -c "^\*")
        
        # Extract update details (label and title)
        local UPDATE_DETAILS=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\*[[:space:]]Label:[[:space:]](.+)$ ]]; then
                local LABEL="${BASH_REMATCH[1]}"
                UPDATE_DETAILS+="$LABEL, "
            fi
        done < <(echo "$UPDATE_CHECK")
        
        # Clean up trailing comma and space
        UPDATE_DETAILS="${UPDATE_DETAILS%, }"
        
        if [ -n "$UPDATE_DETAILS" ]; then
            echo "$UPDATE_COUNT updates available: $UPDATE_DETAILS"
        else
            echo "$UPDATE_COUNT updates available"
        fi
    else
        echo "Up to Date"
    fi
}

###############################################################################
# Collect all metrics
###############################################################################
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
HOSTNAME=$(hostname 2>/dev/null || echo "Unknown")

safe_get SMART_STATUS get_smart_status

# Kernel panics: get count + human-readable message
safe_get KERNEL_PANIC_RAW check_kernel_panics
KERNEL_PANIC_COUNT=${KERNEL_PANIC_RAW%%|*}
KERNEL_PANICS=${KERNEL_PANIC_RAW#*|}

# System errors with burst detection - UPDATED in v2.0
safe_get SYSTEM_ERRORS_RAW  check_system_errors

# Parse the multi-field output
SYSTEM_ERRORS=${SYSTEM_ERRORS_RAW%%|*}  # Display message
SYSTEM_ERRORS_FIELDS=${SYSTEM_ERRORS_RAW#*|}

ERROR_COUNT_NUM=$(echo "$SYSTEM_ERRORS_FIELDS" | cut -d'|' -f1)
CRITICAL_COUNT_NUM=$(echo "$SYSTEM_ERRORS_FIELDS" | cut -d'|' -f2)
RECENT_ERROR_COUNT=$(echo "$SYSTEM_ERRORS_FIELDS" | cut -d'|' -f3)

# Ensure all are numeric
[[ ! "$ERROR_COUNT_NUM" =~ ^[0-9]+$ ]] && ERROR_COUNT_NUM=0
[[ ! "$CRITICAL_COUNT_NUM" =~ ^[0-9]+$ ]] && CRITICAL_COUNT_NUM=0
[[ ! "$RECENT_ERROR_COUNT" =~ ^[0-9]+$ ]] && RECENT_ERROR_COUNT=0

safe_get DRIVE_SPACE    get_drive_space
safe_get UPTIME         get_uptime
safe_get MEMORY         get_memory_pressure
safe_get CPU_TEMP       get_cpu_temp
safe_get TM_STATUS      check_time_machine
safe_get SOFTWARE_UPDATES check_software_updates
MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")

log_message "Metrics collected successfully"

###############################################################################
# Derive numeric values for Health Score evaluation
###############################################################################

# Disk usage: extract percentage from "Used (Z%)"
PERCENT_USED_NUM=$(echo "$DRIVE_SPACE" \
    | grep -Eo '\([0-9]+%\)' \
    | tr -d '()%' \
    | head -1)
# Fallback if not numeric
if ! [[ "$PERCENT_USED_NUM" =~ ^[0-9]+$ ]]; then
    PERCENT_USED_NUM=0
fi

# CPU temperature: extract numeric part from "56.8°C"
CPU_TEMP_NUM=$(echo "$CPU_TEMP" | sed 's/[^0-9.]//g')
CPU_TEMP_INT=0
if [ -n "$CPU_TEMP_NUM" ]; then
    CPU_TEMP_INT=${CPU_TEMP_NUM%.*}
fi

###############################################################################
# Time Machine - compute days since last backup (if present)
###############################################################################
TM_NEEDS_ATTENTION=false
TM_LAST_BACKUP_DAYS=0

# Extract date like: "Latest: 2025-11-18 05:42:36"
LATEST_DATE=$(echo "$TM_STATUS" | grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2}")
LATEST_TIME=$(echo "$TM_STATUS" | grep -Eo "[0-9]{2}:[0-9]{2}:[0-9]{2}")

if [ -n "$LATEST_DATE" ] && [ -n "$LATEST_TIME" ]; then
    LAST_BACKUP_TS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LATEST_DATE $LATEST_TIME" +%s 2>/dev/null)
    NOW_TS=$(date +%s)
    if [ -n "$LAST_BACKUP_TS" ]; then
        TM_LAST_BACKUP_DAYS=$(( (NOW_TS - LAST_BACKUP_TS) / 86400 ))
    fi
else
    TM_NEEDS_ATTENTION=true
fi

###############################################################################
# Severity + Reasons + Health Score - UPDATED with burst-aware logic in v2.0
###############################################################################

SEVERITY="Info"
REASONS=""

# Helper: escalate severity (never downgrade)
bump_to_warning() {
    if [ "$SEVERITY" = "Info" ]; then
        SEVERITY="Warning"
    fi
}
bump_to_critical() {
    SEVERITY="Critical"
}

### SMART status
if [ "$SMART_STATUS" != "Verified" ] && [ "$SMART_STATUS" != "Not Available" ]; then
    bump_to_critical
    REASONS+="SMART status is '$SMART_STATUS'. "
fi

### Kernel panics (24h)
if [ "$KERNEL_PANIC_COUNT" -gt 0 ] 2>/dev/null; then
    bump_to_critical
    REASONS+="Kernel panics in last 24 hours: $KERNEL_PANIC_COUNT. "
fi

### Disk usage thresholds
if [ "$PERCENT_USED_NUM" -ge 90 ] 2>/dev/null; then
    bump_to_critical
    REASONS+="Disk usage ${PERCENT_USED_NUM}% (>= 90%). "
elif [ "$PERCENT_USED_NUM" -ge 80 ] 2>/dev/null; then
    bump_to_warning
    REASONS+="Disk usage ${PERCENT_USED_NUM}% (>= 80%). "
fi

### CPU temp thresholds
if [ "$CPU_TEMP_INT" -ge 85 ] 2>/dev/null && [ "$CPU_TEMP_INT" -lt 120 ] 2>/dev/null; then
    bump_to_critical
    REASONS+="CPU temp ${CPU_TEMP_INT}°C (>= 85°C). "
elif [ "$CPU_TEMP_INT" -ge 80 ] 2>/dev/null && [ "$CPU_TEMP_INT" -lt 85 ] 2>/dev/null; then
    bump_to_warning
    REASONS+="CPU temp ${CPU_TEMP_INT}°C (>= 80°C). "
fi

### System logs - noise-aware logic (v2.1+)

### System logs — tuned for normal macOS noise (your baseline)

if [ "${NOISE_FILTERING:-1}" = "1" ]; then
    # Critical only if massive, sustained error storms
    if [ "$RECENT_ERROR_COUNT" -gt 5000 ] 2>/dev/null; then
        bump_to_critical
        REASONS+="Severe sustained system error storm (${RECENT_ERROR_COUNT} errors in last 5 min). "

    # Warning only if significantly above your normal baseline
    elif [ "$RECENT_ERROR_COUNT" -gt 2000 ] 2>/dev/null; then
        bump_to_warning
        REASONS+="Elevated system log activity (${RECENT_ERROR_COUNT} errors in last 5 min). "

    else
        # Anything below 2000 recent errors = normal for macOS
        REASONS+="System log noise stable and within normal macOS levels. "
    fi

else
    # Legacy logic if NOISE_FILTERING=0
    ...
fi



### Time Machine thresholds
if [ "$TM_NEEDS_ATTENTION" = true ]; then
    bump_to_critical
    REASONS+="Time Machine not configured or destination missing. "
elif [ "$TM_LAST_BACKUP_DAYS" -ge 7 ] 2>/dev/null; then
    bump_to_critical
    REASONS+="Last Time Machine backup ${TM_LAST_BACKUP_DAYS} days ago (>= 7 days). "
elif [ "$TM_LAST_BACKUP_DAYS" -ge 3 ] 2>/dev/null; then
    bump_to_warning
    REASONS+="Last Time Machine backup ${TM_LAST_BACKUP_DAYS} days ago (>= 3 days). "
fi

### Final Health Score from Severity
if [ "$SEVERITY" = "Info" ]; then
    HEALTH_SCORE="Healthy"
else
    HEALTH_SCORE="Attention Needed"
fi

### Default reason for healthy systems
if [ -z "$REASONS" ]; then
    REASONS="All checks passed within defined thresholds."
fi

###############################################################################
# Prepare JSON payload for Airtable (robust to special characters if jq present)
###############################################################################
JSON_PAYLOAD=""

if have_cmd jq; then
    JSON_PAYLOAD=$(jq -n \
      --arg ts "$TIMESTAMP" \
      --arg host "$HOSTNAME" \
      --arg ver "$MACOS_VERSION" \
      --arg smart "$SMART_STATUS" \
      --arg kp "$KERNEL_PANICS" \
      --arg sys_err "$SYSTEM_ERRORS" \
      --arg disk "$DRIVE_SPACE" \
      --arg up "$UPTIME" \
      --arg mem "$MEMORY" \
      --arg cpu "$CPU_TEMP" \
      --arg tm "$TM_STATUS" \
      --arg sw_updates "$SOFTWARE_UPDATES" \
      --arg health "$HEALTH_SCORE" \
      --arg severity "$SEVERITY" \
      --arg reasons "$REASONS" \
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
          "Software Updates": $sw_updates,
          "Health Score": $health,
          "Severity": $severity,
          "Reasons": $reasons
      }}')
else
    log_message "WARN: jq not installed; building JSON without escaping (may break on special characters)"
    JSON_PAYLOAD=$(cat <<EOF
{
  "fields": {
    "Timestamp": "$TIMESTAMP",
    "Hostname": "$HOSTNAME",
    "macOS Version": "$MACOS_VERSION",
    "SMART Status": "$SMART_STATUS",
    "Kernel Panics": "$KERNEL_PANICS",
    "System Errors": "$SYSTEM_ERRORS",
    "Drive Space": "$DRIVE_SPACE",
    "Uptime": "$UPTIME",
    "Memory Pressure": "$MEMORY",
    "CPU Temperature": "$CPU_TEMP",
    "Time Machine": "$TM_STATUS",
    "Software Updates": "$SOFTWARE_UPDATES",
    "Health Score": "$HEALTH_SCORE",
    "Severity": "$SEVERITY",
    "Reasons": "$REASONS"
  }
}
EOF
)
fi

###############################################################################
# Send to Airtable
###############################################################################

# Debug: Log the JSON payload
echo "DEBUG: JSON Payload:" >> "$LOG_FILE"
echo "$JSON_PAYLOAD" >> "$LOG_FILE"

log_message "Sending data to Airtable..."

TABLE_ENCODED=$(echo "$AIRTABLE_TABLE_NAME" | sed 's/ /%20/g')
RESPONSE=$(curl -s -X POST "https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$TABLE_ENCODED" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")

# Check if successful
if echo "$RESPONSE" | grep -q '"id"'; then
    log_message "✓ Data successfully sent to Airtable"
    if have_cmd jq; then
        echo "$RESPONSE" | jq '.' >> "$LOG_FILE" 2>/dev/null
    else
        echo "$RESPONSE" >> "$LOG_FILE" 2>/dev/null
    fi
else
    log_message "✗ ERROR: Failed to send data to Airtable"
    log_message "Response: $RESPONSE"
fi

log_message "=== Health check completed (v2.1 - Software Updates) ==="
echo ""