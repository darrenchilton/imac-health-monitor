#!/bin/bash

echo "=== Time Machine Diagnostic Test ==="
echo ""

echo "1. Testing 'tmutil status':"
echo "----------------------------"
tmutil status 2>&1
echo ""

echo "2. Testing 'tmutil latestbackup':"
echo "----------------------------"
LATEST=$(tmutil latestbackup 2>&1)
echo "Result: '$LATEST'"
echo "Length: ${#LATEST}"
echo ""

echo "3. Testing 'tmutil listbackups':"
echo "----------------------------"
tmutil listbackups 2>&1 | head -5
echo "... (showing first 5)"
COUNT=$(tmutil listbackups 2>&1 | wc -l | xargs)
echo "Total backups found: $COUNT"
echo ""

echo "4. Testing 'tmutil destinationinfo':"
echo "----------------------------"
tmutil destinationinfo 2>&1
echo ""

echo "5. Testing 'tmutil latestbackup' with different approach:"
echo "----------------------------"
LATEST_ALT=$(tmutil latestbackup 2>/dev/null || echo "FAILED")
if [ "$LATEST_ALT" = "FAILED" ]; then
    echo "Command failed, trying listbackups..."
    LATEST_ALT=$(tmutil listbackups 2>/dev/null | tail -1 || echo "NO_BACKUPS")
fi
echo "Result: '$LATEST_ALT'"
echo ""

echo "6. Extracting timestamp from path:"
echo "----------------------------"
if [ -n "$LATEST_ALT" ] && [ "$LATEST_ALT" != "NO_BACKUPS" ] && [ "$LATEST_ALT" != "FAILED" ]; then
    BASENAME=$(basename "$LATEST_ALT")
    echo "Basename: '$BASENAME'"
else
    echo "No valid path to extract from"
fi
echo ""

echo "7. Current function would return:"
echo "----------------------------"
check_time_machine_test() {
    local STATUS="Not configured"
    local TM_RAW_STATUS=$(tmutil status 2>/dev/null || true)
    
    if [ -n "$TM_RAW_STATUS" ]; then
        if echo "$TM_RAW_STATUS" | grep -q "Running = 1"; then
            STATUS="Backup in progress"
        else
            STATUS="Configured, not currently running"
        fi
    fi
    
    local TM_LATEST=$(tmutil latestbackup 2>/dev/null || true)
    if [ -z "$TM_LATEST" ]; then
        TM_LATEST=$(tmutil listbackups 2>/dev/null | tail -n 1 || true)
    fi
    
    if [ -n "$TM_LATEST" ]; then
        local LATEST_BACKUP=$(basename "$TM_LATEST")
        STATUS="$STATUS; Latest: $LATEST_BACKUP"
    else
        STATUS="$STATUS; No completed backups found"
    fi
    
    echo "$STATUS"
}

check_time_machine_test
echo ""

echo "=== Diagnostic Complete ==="