#!/bin/bash
###############################################################################
# iMac Health Monitor v3.2.4c
# Last Updated: 2025-12-03
#
# PATCH v3.2.4c (reachability accuracy):
# - Port listening checks now use netstat (LaunchAgent-safe) instead of lsof.
# - Tailscale detection uses full binary path (aliases/PATH not loaded for agents).
# - screensharing_running also considers port 5900 listener as evidence of service.
# - sshd_running remains informational; ssh_port_listening is canonical.
#
# CHANGELOG v3.2.4:
# - NEW: Reachability / remote access diagnostics:
#   - sshd_running + ssh_port_listening
#   - screensharing_running + vnc_port_listening
#   - tailscale_cli_present + tailscale_peer_reachable
#   - remote_access_artifacts + remote_access_artifacts_count
# - DOC: Added 2025-12-03 remote outage / TurboTax PDFs / CGPDFService storm entry in README.
#
# CHANGELOG v3.2.3:
# - CHANGED: Replaced AppleScript/System Events GUI app detection with a
#   process-based scanner using ps to detect apps running from
#   *.app/Contents/MacOS/.
# - FIXED: Eliminates false "No GUI apps detected" for active users, including
#   Finder, Chrome, Mail, pCloud, etc.
# - IMPROVED: App detection now independent of Accessibility permissions,
#   System Events responsiveness, and AppleScript failures on Sonoma.
# - IMPROVED: Still supports version extraction and ⚠️ LEGACY flags.
#
# (Older changelog retained below)
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

AIRTABLE_TABLE_NAME="${AIRTABLE_TABLE_NAME:-System Health}"

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
smart_status=$(safe_timeout 5 diskutil info "$boot_device" 2>/dev/null | awk -F': *' '/SMART Status/ {print $2}' | xargs)
[[ -z "$smart_status" ]] && smart_status="Unknown"

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
# Defaults for fields used in jq payload
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

kernel_panics_text="No kernel panics in last 24 hours"
[[ "$kernel_panics" -gt 0 ]] && kernel_panics_text="${kernel_panics} kernel panic(s) detected in last 24 hours"

system_errors_text="Log Activity: ${errors_1h} errors (${recent_5m} recent, ${critical_1h} critical)"
tm_status="Configured; Latest: Unable to determine"
if [[ "$tm_age_days" -ne -1 && "$tm_age_days" -gt 0 ]]; then
    backup_date=$(date -v-"${tm_age_days}"d '+%Y-%m-%d' 2>/dev/null || date -d "${tm_age_days} days ago" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")
    tm_status="Configured; Latest: ${backup_date}"
elif [[ "$tm_age_days" -eq 0 ]]; then
    tm_status="Configured; Latest: $(date '+%Y-%m-%d')"
fi

###############################################################################
# GPU / WindowServer Freeze Detector (last 2 minutes)
###############################################################################
gpu_freeze_patterns=(
    "GPU Reset" "GPU Hang" "AMDRadeon" "AGC::"
    "WindowServer.*stalled" "WindowServer.*overload"
    "IOSurface" "Metal.*timeout" "timed out waiting for" "GPU Debug Info"
)

gpu_freeze_detected="No"
gpu_recent_log=$(safe_timeout 8 log show --last 2m --predicate 'eventMessage CONTAINS[c] "gpu" OR eventMessage CONTAINS[c] "WindowServer" OR eventMessage CONTAINS[c] "display" OR eventMessage CONTAINS[c] "metal"' 2>/dev/null)
gpu_freeze_events=""

for pattern in "${gpu_freeze_patterns[@]}"; do
    match=$(echo "$gpu_recent_log" | grep -E "$pattern" | head -5)
    if [ -n "$match" ]; then
        gpu_freeze_detected="Yes"
        gpu_freeze_events+="${pattern}: $(echo "$match" | wc -l | tr -d ' ') events; "
    fi
done

gpu_freeze_events=$(echo "$gpu_freeze_events" | sed 's/; $//')
[[ -z "$gpu_freeze_events" ]] && gpu_freeze_events="None"

###############################################################################
# USER AND APPLICATION MONITORING (v3.2.3)
###############################################################################
get_active_users() {
    local users_info=""
    local user_list
    user_list=$(who | grep "console" | awk '{print $1}' | sort -u)
    local count=0

    if [[ -z "$user_list" ]]; then
        echo "0"
        echo "No console users"
        return
    fi

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        ((count++))

        local idle_ns idle idle_seconds
        idle_ns=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}')
        if [[ -n "$idle_ns" ]]; then
            idle_seconds=$(printf "%.0f" "$idle_ns")
            if [[ $idle_seconds -lt 60 ]]; then
                idle="${idle_seconds}s"
            elif [[ $idle_seconds -lt 3600 ]]; then
                idle="$((idle_seconds / 60))m"
            elif [[ $idle_seconds -lt 86400 ]]; then
                local hours=$((idle_seconds / 3600))
                local mins=$(((idle_seconds % 3600) / 60))
                idle="${hours}:$(printf "%02d" $mins)"
            else
                local days=$((idle_seconds / 86400))
                idle="${days}days"
            fi
            [[ $idle_seconds -lt 5 ]] && idle="active"
        else
            idle="unknown"
        fi

        users_info+="${user} (console, idle ${idle})"$'\n'
    done <<< "$user_list"

    echo "$count"
    echo "$users_info" | sed '/^$/d'
}

get_app_version() {
    local app_path="$1"
    local version
    version=$(defaults read "${app_path}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    [[ -z "$version" ]] && version=$(defaults read "${app_path}/Contents/Info.plist" CFBundleVersion 2>/dev/null)
    echo "$version"
}

check_legacy_status() {
    local app_name="$1"
    local version="$2"
    local major_version
    major_version=$(echo "$version" | cut -d. -f1)

    case "$app_name" in
        "VMware Fusion") [[ "$major_version" -lt 13 ]] && echo "⚠️ LEGACY" ;;
        "VirtualBox") [[ "$major_version" -lt 7 ]] && echo "⚠️ LEGACY" ;;
        "Parallels Desktop") [[ "$major_version" -lt 17 ]] && echo "⚠️ LEGACY" ;;
        "Adobe Photoshop"*) ([[ "$version" =~ "CS" ]] || [[ "$major_version" -lt 21 ]]) && echo "⚠️ LEGACY" ;;
    esac
}

get_user_applications() {
    local app_inventory=""
    local total_apps=0
    local user_list
    user_list=$(who | grep "console" | awk '{print $1}' | sort -u)

    if [[ -z "$user_list" ]]; then
        echo "0"
        echo "No users logged in"
        return
    fi

    local apps_all
    apps_all=$(ps aux 2>/dev/null | awk '/\.app\/Contents\/MacOS\// {printf "%s|%s\n",$1,$11}')

    if [[ -z "$apps_all" ]]; then
        while IFS= read -r user; do
            [[ -z "$user" ]] && continue
            app_inventory+="[${user}] Unable to detect GUI apps (ps scan empty)"$'\n'
        done <<< "$user_list"
        echo "0"; echo "$app_inventory" | sed '/^$/d'; return
    fi

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local user_cmds
        user_cmds=$(echo "$apps_all" | awk -F'|' -v u="$user" '$1 == u {print $2}' | sort -u)

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

legacy_software_flags=$(generate_legacy_flags "$application_inventory" "$vm_activity")
[[ -z "$legacy_software_flags" ]] && legacy_software_flags="No legacy software detected"
debug_log "END: User/app monitoring"

###############################################################################
# Reachability / Remote Access Diagnostics (patched)
###############################################################################
debug_log "START: Reachability/remote access checks"

# sshd running (informational) + port listening (canonical)
sshd_running="No"
pgrep -x "sshd" >/dev/null 2>&1 && sshd_running="Yes"

ssh_port_listening="No"
if netstat -anv -p tcp 2>/dev/null | grep -qE '\.22[[:space:]].*LISTEN'; then
    ssh_port_listening="Yes"
fi

# Screen Sharing / VNC running + port listening (5900)
screensharing_running="No"
pgrep -x "screensharingd" >/dev/null 2>&1 && screensharing_running="Yes"
pgrep -x "screensha" >/dev/null 2>&1 && screensharing_running="Yes"

vnc_port_listening="No"
if netstat -anv -p tcp 2>/dev/null | grep -qE '\.5900[[:space:]].*LISTEN'; then
    vnc_port_listening="Yes"
fi

# If port 5900 is listening, treat screensharing as running even if process name differs
if [[ "$vnc_port_listening" == "Yes" ]]; then
    screensharing_running="Yes"
fi

# Tailscale CLI presence + peer reachable (use full path)
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

# Residual remote-access software scan (AnyDesk, TeamViewer, etc.)
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
        "/Library/LaunchDaemons"
        "/Library/LaunchAgents"
        "/Library/LaunchDaemonsDisabled"
        "/Library/LaunchAgents.disabled"
        "$HOME/Library/LaunchAgents"
        "/Applications"
    )

    for p in "${paths[@]}"; do
        [[ ! -e "$p" ]] && continue
        for pat in "${remote_access_patterns[@]}"; do
            local found
            found=$(find "$p" -iname "*${pat}*" 2>/dev/null | head -20)
            if [[ -n "$found" ]]; then
                hits+="$found"$'\n'
            fi
        done
    done

    if [[ -n "$hits" ]]; then
        hits=$(echo "$hits" | sed '/^$/d' | sort -u)
        remote_access_artifacts_count=$(echo "$hits" | wc -l | tr -d ' ')
        remote_access_artifacts=$(echo "$hits" | paste -sd "," -)
    fi
}
scan_remote_artifacts

debug_log "END: Reachability/remote access checks"

###############################################################################
# HEALTH SCORING LOGIC
###############################################################################
severity="Info"
health_score_label="Healthy"
reasons="System operating normally"

errors_1h_int=$(to_int "$errors_1h")
recent_5m_int=$(to_int "$recent_5m")
critical_1h_int=$(to_int "$critical_1h")
crash_count_int=$(to_int "$crash_count")
thermal_throttles_int=$(to_int "$thermal_throttles_1h")
tm_age_days_int=$(to_int "$tm_age_days")

has_supporting_symptoms="No"
[[ "$crash_count_int" -ge 5 ]] && has_supporting_symptoms="Yes"
[[ "$thermal_throttles_int" -gt 0 ]] && has_supporting_symptoms="Yes"
[[ "$gpu_freeze_detected" == "Yes" ]] && has_supporting_symptoms="Yes"

if [[ "$smart_status" != "Verified" && "$smart_status" != "Unknown" ]]; then
    severity="Critical"
    health_score_label="Hardware Failure"
    reasons="SMART status: ${smart_status} - Drive failure imminent"
elif [[ "$kernel_panics" -gt 0 ]]; then
    severity="Critical"
    health_score_label="System Instability"
    reasons="Kernel panic detected (${kernel_panics} in last 24h) - System crashed"
elif [[ "$recent_5m_int" -ge "$ERROR_5M_CRITICAL" ]] || [[ "$errors_1h_int" -ge "$ERROR_1H_CRITICAL" ]]; then
    if [[ "$has_supporting_symptoms" == "Yes" ]]; then
        severity="Critical"
        health_score_label="Attention Needed"
        reasons="Severe error burst detected (1h: ${errors_1h_int}, 5m: ${recent_5m_int}) with supporting symptoms (crashes/thermal/GPU)"
    else
        severity="Warning"
        health_score_label="Monitor Closely"
        reasons="Large log burst detected (1h: ${errors_1h_int}, 5m: ${recent_5m_int}) but no crashes/thermal/GPU symptoms"
    fi
elif [[ "$critical_1h_int" -ge "$CRITICAL_FAULT_CRITICAL" ]]; then
    severity="Critical"
    health_score_label="Attention Needed"
    reasons="Excessive critical faults (${critical_1h_int}/hour)"
elif [[ "$recent_5m_int" -ge "$ERROR_5M_WARNING" ]] || [[ "$errors_1h_int" -ge "$ERROR_1H_WARNING" ]]; then
    severity="Warning"
    health_score_label="Monitor Closely"
    reasons="Elevated error activity (1h: ${errors_1h_int}, 5m: ${recent_5m_int})"
elif [[ "$critical_1h_int" -ge "$CRITICAL_FAULT_WARNING" ]]; then
    severity="Warning"
    health_score_label="Monitor Closely"
    reasons="Elevated critical faults (${critical_1h_int}/hour)"
fi

if [[ "$tm_age_days_int" -gt 7 ]]; then
    [[ "$severity" == "Info" ]] && severity="Warning" && health_score_label="Backup Overdue"
    if [[ "$reasons" == "System operating normally" ]]; then
        reasons="Time Machine backup overdue (${tm_age_days_int} days)"
    else
        reasons="${reasons}; Time Machine backup overdue (${tm_age_days_int} days)"
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
  --argjson cc "$crash_count_int" \
  --argjson tt "$thermal_throttles_int" \
  --argjson tmage "$tm_age_days_int" \
  --argjson user_cnt "$user_count" \
  --argjson app_cnt "$total_gui_apps" \
  --argjson vm_cnt "$vm_count" \
  --argjson vmw_cpu "$vmware_cpu_percent" \
  --argjson vmw_mem "$vmware_memory_gb" \
  '{
    fields: {
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

      "GPU Freeze Detected": $gpu_freeze,
      "GPU Freeze Events": $gpu_events,
      "fan_max_events_1h": $fan_max_events_1h,

      "Active Users": $active_users,
      "Application Inventory": $app_inv,
      "VMware Status": $vmware_stat,
      "VM State": $vm_state,
      "VM Activity": $vm_act,

      "High Risk Apps": $high_risk,
      "Resource Hogs": $res_hogs,
      "Legacy Software Flags": $legacy_flags,

      "sshd_running": $sshd_running,
      "ssh_port_listening": $ssh_port_listening,
      "screensharing_running": $screensharing_running,
      "vnc_port_listening": $vnc_port_listening,
      "tailscale_cli_present": $tailscale_cli_present,
      "tailscale_peer_reachable": $tailscale_peer_reachable,
      "remote_access_artifacts": $remote_access_artifacts,
      "remote_access_artifacts_count": $remote_access_artifacts_count,

      "Debug Log": $debug_log,
      "user_count": $user_cnt,
      "total_gui_apps": $app_cnt,
      "vm_count": $vm_cnt,
      "vmware_cpu_percent": $vmw_cpu,
      "vmware_memory_gb": $vmw_mem
    }
  }'
)

# Wrap and send to Airtable (existing logic)
FINAL_PAYLOAD=$(jq -n \
  --argjson main "$JSON_PAYLOAD" \
  '{records: [$main]}')

AIRTABLE_URL="https://api.airtable.com/v0/${AIRTABLE_BASE_ID}/${AIRTABLE_TABLE_NAME}"

debug_log "Posting to Airtable"
curl -sS -X POST "$AIRTABLE_URL" \
  -H "Authorization: Bearer ${AIRTABLE_PAT}" \
  -H "Content-Type: application/json" \
  -d "$FINAL_PAYLOAD" >/dev/null 2>&1

if [[ $? -eq 0 ]]; then
    debug_log "Airtable upload: SUCCESS"
else
    debug_log "Airtable upload: FAILED"
fi

debug_log "=== SCRIPT END ==="

echo "Debug log saved to: $DEBUG_LOG"
echo "$FINAL_PAYLOAD"
exit 0
