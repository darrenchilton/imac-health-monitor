#!/bin/bash

################################################################################
# Real-Time Error Monitor
# Watches for error bursts as they happen and logs details
################################################################################

OUTPUT="$HOME/Desktop/error_realtime_log_$(date +%Y%m%d_%H%M%S).txt"

echo "=== REAL-TIME ERROR MONITOR ===" | tee "$OUTPUT"
echo "Started: $(date)" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
echo "This script will monitor for 30 minutes and log when error bursts occur." | tee -a "$OUTPUT"
echo "Press Ctrl+C to stop early." | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
echo "Checking every 60 seconds..." | tee -a "$OUTPUT"
echo "========================================" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Initialize previous count
PREV_COUNT=0

# Run for 30 minutes (30 iterations of 60 seconds)
for i in {1..30}; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get current error count from last 2 minutes (to catch recent bursts)
    CURRENT_COUNT=$(timeout 5 log show --predicate 'messageType == error' --last 2m 2>/dev/null | wc -l | xargs)
    
    # Calculate rate
    if [ "$CURRENT_COUNT" -gt "$PREV_COUNT" ]; then
        DELTA=$((CURRENT_COUNT - PREV_COUNT))
    else
        DELTA=0
    fi
    
    # Log the measurement
    echo "[$TIMESTAMP] Errors (last 2min): $CURRENT_COUNT | New errors: $DELTA" | tee -a "$OUTPUT"
    
    # If we detect a burst (>100 new errors), capture details
    if [ "$DELTA" -gt 100 ]; then
        echo "  ⚠️  BURST DETECTED! Capturing details..." | tee -a "$OUTPUT"
        
        # Get top processes during the burst
        echo "  Top error sources:" | tee -a "$OUTPUT"
        timeout 5 log show --predicate 'messageType == error' --last 2m --style syslog 2>/dev/null | \
          awk '{print $5}' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /' | tee -a "$OUTPUT"
        
        # Get sample error messages
        echo "  Sample error messages:" | tee -a "$OUTPUT"
        timeout 5 log show --predicate 'messageType == error' --last 2m 2>/dev/null | tail -3 | sed 's/^/    /' | tee -a "$OUTPUT"
        
        # Check what's running
        echo "  Top CPU processes:" | tee -a "$OUTPUT"
        ps aux | sort -rk 3 | head -3 | awk '{print $11}' | sed 's/^/    /' | tee -a "$OUTPUT"
        
        echo "" | tee -a "$OUTPUT"
    fi
    
    PREV_COUNT=$CURRENT_COUNT
    
    # Wait 60 seconds before next check
    sleep 60
done

echo "" | tee -a "$OUTPUT"
echo "========================================" | tee -a "$OUTPUT"
echo "Monitoring completed: $(date)" | tee -a "$OUTPUT"
echo "Log saved to: $OUTPUT" | tee -a "$OUTPUT"