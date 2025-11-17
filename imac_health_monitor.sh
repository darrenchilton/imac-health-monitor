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
    
    log_message "Checking SMART status for boot drive: $DISK_ID"
    
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
    log_message "Checking for kernel panics..."
    
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
    log_message "Checking system logs for errors..."
    
    # Get error count from last 24 hours
    ERROR_COUNT=$(log show --predicate 'messageType == error' --last 24h 2>/dev/null | grep -c "^[0-9]" || echo "0")
    
    # Get critical error count
    CRITICAL_COUNT=$(log show --predicate 'messageType == fault' --last 24h 2>/dev/null | grep -c "^[0-9]" || echo "0")
    
    echo "Errors: $ERROR_COUNT, Critical: $CRITICAL_COUNT (last 24h)"
}

# Function to get drive space info
get_drive_space() {
    log_message "Checking drive space..."
    
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
    # Try to get temperature using powermetrics (requires sudo)
    # This is a placeholder - may need adjustment based on available tools
    TEMP="Not available without sudo"
    echo "$TEMP"
}

# Function to check Time Machine backup status
check_time_machine() {
    log_message "Checking Time Machine status..."
    
    TM_STATUS=$(tmutil latestbackup 2>/dev/null)
    if [ -n "$TM_STATUS" ]; then
        LATEST_BACKUP=$(basename "$TM_STATUS")
        echo "Latest backup: $LATEST_BACKUP"
    else
        echo "No Time Machine backup found"
    fi
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

log_message "Sending data to Airtable..."

# Send to Airtable
RESPONSE=$(curl -s -X POST "https://api.airtable.com/v0/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_NAME" \
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
