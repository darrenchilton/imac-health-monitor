#!/bin/bash

################################################################################
# Error Burst Monitor
# Watches for spikes in error generation and identifies triggers
################################################################################

OUTPUT="$HOME/Desktop/error_burst_analysis_$(date +%Y%m%d_%H%M%S).txt"

echo "=== ERROR BURST ANALYSIS ===" | tee "$OUTPUT"
echo "Generated: $(date)" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Check error counts in different time windows
echo "==== ERROR COUNTS BY TIME WINDOW ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Last 5 minutes:" | tee -a "$OUTPUT"
timeout 5 log show --predicate 'messageType == error' --last 5m 2>/dev/null | wc -l | xargs | tee -a "$OUTPUT"

echo "Last 10 minutes:" | tee -a "$OUTPUT"
timeout 5 log show --predicate 'messageType == error' --last 10m 2>/dev/null | wc -l | xargs | tee -a "$OUTPUT"

echo "Last 15 minutes:" | tee -a "$OUTPUT"
timeout 5 log show --predicate 'messageType == error' --last 15m 2>/dev/null | wc -l | xargs | tee -a "$OUTPUT"

echo "Last 30 minutes:" | tee -a "$OUTPUT"
timeout 5 log show --predicate 'messageType == error' --last 30m 2>/dev/null | wc -l | xargs | tee -a "$OUTPUT"

echo "Last 1 hour:" | tee -a "$OUTPUT"
timeout 10 log show --predicate 'messageType == error' --last 1h 2>/dev/null | wc -l | xargs | tee -a "$OUTPUT"

echo "" | tee -a "$OUTPUT"

# Check what scheduled tasks might be running
echo "==== SCHEDULED TASKS THAT MIGHT CAUSE BURSTS ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "LaunchDaemons (system-wide scheduled tasks):" | tee -a "$OUTPUT"
ls -la /Library/LaunchDaemons/ | grep -i "interval\|hour\|period" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "LaunchAgents (user scheduled tasks):" | tee -a "$OUTPUT"
ls -la ~/Library/LaunchAgents/ | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Check currently running background processes that might burst
echo "==== CURRENTLY RUNNING BACKGROUND PROCESSES ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Spotlight/indexing processes:" | tee -a "$OUTPUT"
ps aux | grep -i "mds\|spotlight" | grep -v grep | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Location services:" | tee -a "$OUTPUT"
ps aux | grep -i "locationd" | grep -v grep | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Biome/logging processes:" | tee -a "$OUTPUT"
ps aux | grep -i "biome" | grep -v grep | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Time Machine:" | tee -a "$OUTPUT"
ps aux | grep -i "backupd\|tmutil" | grep -v grep | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Check if there's a pattern to when errors occur
echo "==== CHECKING YOUR HEALTH MONITOR SCHEDULE ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

if [ -f ~/Library/LaunchAgents/com.imac.healthmonitor.plist ]; then
    echo "Health monitor plist found:" | tee -a "$OUTPUT"
    cat ~/Library/LaunchAgents/com.imac.healthmonitor.plist | grep -A 2 "StartInterval\|StartCalendarInterval" | tee -a "$OUTPUT"
else
    echo "Health monitor plist not found in expected location" | tee -a "$OUTPUT"
fi
echo "" | tee -a "$OUTPUT"

# Look for periodic tasks
echo "==== SYSTEM PERIODIC TASKS ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Checking /etc/periodic/ for scheduled maintenance:" | tee -a "$OUTPUT"
ls -la /etc/periodic/daily/ 2>/dev/null | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Check for Time Machine auto-backup schedule
echo "==== TIME MACHINE CONFIGURATION ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
tmutil destinationinfo 2>/dev/null | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Time Machine auto-backup enabled:" | tee -a "$OUTPUT"
tmutil isscheduled 2>/dev/null | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Check system load to see if something is running heavily now
echo "==== CURRENT SYSTEM ACTIVITY ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Top CPU consumers:" | tee -a "$OUTPUT"
ps aux | sort -rk 3 | head -10 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "========================================" | tee -a "$OUTPUT"
echo "Report saved to: $OUTPUT" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
echo "THEORY: Your errors happen in bursts, likely triggered by:" | tee -a "$OUTPUT"
echo "  - Hourly scheduled tasks" | tee -a "$OUTPUT"
echo "  - Time Machine backups starting" | tee -a "$OUTPUT"
echo "  - System maintenance routines" | tee -a "$OUTPUT"
echo "  - Spotlight reindexing cycles" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
echo "To catch errors in action, run the real-time monitor:" | tee -a "$OUTPUT"
echo "  ./error_realtime_monitor.sh" | tee -a "$OUTPUT"