#!/bin/bash

################################################################################
# iMac Health Monitor
# Collects system health metrics and sends to Airtable
# Created: November 17, 2025
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
LOG_FILE="$HOME/Library/Logs/imac_health_monitor.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "=== Starting iMac Health Check ==="

# Function to get SMART status for external boot drive
get_smart_status() {
    # Get the boot drive identifier
    BOOT_DRIVE=$(diskutil info / | grep "Device Node:" | awk '{print $3}')
    
    # Get disk identifier without partition (e.g., disk2s1 -> disk2)
    DISK_ID=$(echo "$BOOT_DRIVE" | sed 's/s[0-9]*$//')
    
    log_message "Checking SMART status for boot drive: $DISK_ID" >&2
    
    # Get SMART status
    SMART_OUTPUT=$(diskutil info "$DISK_ID" 2>&1)
    SMART_STATUS=$(echo "$SMART_OUTPUT" | grep "SMART Status:" | awk -F: '{print $2}' | xargs)
    
    if [ -z "$SMART_STATUS" ]; then
        SMART_STATUS="Not Available"
    fi
    
    echo "$SMART_STATUS"
}

# Function to check for recent kernel panics
check_kernel_panics() {
    log_message "Checking for kernel panics..." >&2
    
    # Check for panic logs in the last 7 days
    PANIC_COUNT=$(find /Library/Logs/DiagnosticReports -name "Kernel_*.panic" -mtime -7 2>/dev/null | wc -l | xargs)
    
    if [ "$PANIC_COUNT" -gt 0 ]; then
        LATEST_PANIC=$(find /Library/Logs/DiagnosticReports -name "Kernel_*.panic" -mtime -7 2>/dev/null | head -1)
        PANIC_INFO="Found $PANIC_COUNT panic(s) in last 7 days. Latest: $(basename "$LATEST_PANIC" 2>/dev/null)"
    else
        PANIC_INFO="No kernel panics in last 7 days"
    fi
    
    echo "$PANIC_INFO"
}

# Function to check system log for errors
check_system_errors() {
    log_message "Checking system logs for errors..." >&2
    
    # Use faster method - check last 1 hour instead of 24h, with timeout
    ERROR_COUNT=$(timeout 10 log show --predicate 'messageType == error' --last 1h 2>/dev/null | wc -l || echo "0")
    CRITICAL_COUNT=$(timeout 10 log show --predicate 'messageType == fault' --last 1h 2>/dev/null | wc -l || echo "0")
    
    # If timeout occurred, use placeholder
    if [ "$ERROR_COUNT" = "0" ] && [ "$CRITICAL_COUNT" = "0" ]; then
        echo "Log check skipped (too slow)"
    else
        echo "Errors: $ERROR_COUNT, Critical: $CRITICAL_COUNT (last 1h)"
    fi
}

# Function to get drive space info
get_drive_space() {
    log_message "Checking drive space..." >&2
    
    BOOT_INFO=$(df -h / | tail -1)
    TOTAL=$(echo "$BOOT_INFO" | awk '{print $2}')
    USED=$(echo "$BOOT_INFO" | awk '{print $3}')
    AVAILABLE=$(echo "$BOOT_INFO" | awk '{print $4}')
    PERCENT_USED=$(echo "$BOOT_INFO" | awk '{print $5}')
    
    echo "Total: $TOTAL, Used: $USED ($PERCENT_USED), Available: $AVAILABLE"
}

# Function to get system uptime
get_uptime() {
    UPTIME=$(uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
    echo "$UPTIME"
}

# Function to get memory pressure
get_memory_pressure() {
    MEMORY_INFO=$(vm_stat | awk '
        /Pages free/ {free=$3}
        /Pages active/ {active=$3}
        /Pages inactive/ {inactive=$3}
        /Pages wired/ {wired=$3}
        END {
            total = free + active + inactive + wired
            used_percent = ((active + wired) / total) * 100
            printf "%.1f%% used", used_percent
        }
    ')
    echo "$MEMORY_INFO"
}

# Function to get CPU temperature (if available)
get_cpu_temp() {
    # Prefer osx-cpu-temp if available (no sudo required)
    if command -v osx-cpu-temp >/dev/null 2>&1; then
        # Example output: "56.8°C"
        TEMP=$(osx-cpu-temp)
        echo "$TEMP"
        return
    fi

    # Fallback: nothing available
    echo "Unavailable"
}


# Function to check Time Machine backup status
# This version works WITHOUT Full Disk Access by using filesystem access
check_time_machine() {
    log_message "Checking Time Machine status..." >&2

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
            local BACKUP_NAME=$(basename "$TM_LATEST")
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
    local MACHINE_NAME=$(hostname -s)

    # Check standard Time Machine structure
    local BACKUP_DIR="$MOUNT_POINT/Backups.backupdb/$MACHINE_NAME"

    if [ -d "$BACKUP_DIR" ]; then
        local LATEST_BACKUP=$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$" | tail -1)
        
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
        local LATEST_BACKUP=$(find "$ALT_BACKUP_DIR" -maxdepth 2 -name "*.backup" -type d 2>/dev/null | sort | tail -1)
        
        if [ -n "$LATEST_BACKUP" ]; then
            local BACKUP_NAME=$(basename "$LATEST_BACKUP" .backup)
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



# Collect all metrics
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
HOSTNAME=$(hostname)
SMART_STATUS=$(get_smart_status)
KERNEL_PANICS=$(check_kernel_panics)
SYSTEM_ERRORS=$(check_system_errors)
DRIVE_SPACE=$(get_drive_space)
UPTIME=$(get_uptime)
MEMORY=$(get_memory_pressure)
CPU_TEMP=$(get_cpu_temp)
TM_STATUS=$(check_time_machine)
MACOS_VERSION=$(sw_vers -productVersion)

log_message "Metrics collected successfully"

# Prepare JSON payload for Airtable
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
    "Health Score": "$([ "$SMART_STATUS" = "Verified" ] && [ "$KERNEL_PANICS" = "No kernel panics in last 7 days" ] && echo "Healthy" || echo "Attention Needed")"
  }
}
EOF
)

# Debug: Log the JSON payload
echo "DEBUG: JSON Payload:" >> "$LOG_FILE"
echo "$JSON_PAYLOAD" >> "$LOG_FILE"

log_message "Sending data to Airtable..."

# Send to Airtable
TABLE_ENCODED=$(echo "$AIRTABLE_TABLE_NAME" | sed 's/ /%20/g')
RESPONSE=$(curl -s -X POST "https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$TABLE_ENCODED" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")

# Check if successful
if echo "$RESPONSE" | grep -q '"id"'; then
    log_message "✓ Data successfully sent to Airtable"
    echo "$RESPONSE" | jq '.' >> "$LOG_FILE" 2>/dev/null
else
    log_message "✗ ERROR: Failed to send data to Airtable"
    log_message "Response: $RESPONSE"
fi

log_message "=== Health check completed ==="
echo ""