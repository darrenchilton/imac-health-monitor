#!/bin/bash

################################################################################
# Simple Raw Error Capture
# Gets actual error messages without complex filtering
################################################################################

OUTPUT="$HOME/Desktop/raw_errors_$(date +%Y%m%d_%H%M%S).txt"

echo "=== RAW ERROR CAPTURE ===" | tee "$OUTPUT"
echo "Generated: $(date)" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# First, verify error counts
echo "==== CURRENT ERROR COUNTS ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Total errors (last 1 hour):" | tee -a "$OUTPUT"
ERROR_COUNT=$(timeout 10 log show --predicate 'messageType == error' --last 1h 2>/dev/null | wc -l | xargs)
echo "  $ERROR_COUNT" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Total critical (last 1 hour):" | tee -a "$OUTPUT"
CRITICAL_COUNT=$(timeout 10 log show --predicate 'messageType == fault' --last 1h 2>/dev/null | wc -l | xargs)
echo "  $CRITICAL_COUNT" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Get top processes using simpler method
echo "==== TOP ERROR-GENERATING PROCESSES ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h --style syslog 2>/dev/null | \
  awk '{print $5}' | sort | uniq -c | sort -rn | head -15 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Get ACTUAL error messages - last 50 from past hour
echo "==== LAST 50 ERROR MESSAGES (RAW) ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
timeout 20 log show --predicate 'messageType == error' --last 1h 2>/dev/null | tail -50 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Get ACTUAL critical messages - last 20 from past hour
echo "==== LAST 20 CRITICAL/FAULT MESSAGES (RAW) ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"
timeout 20 log show --predicate 'messageType == fault' --last 1h 2>/dev/null | tail -20 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

# Try to grep for specific patterns in the raw stream
echo "==== SEARCHING FOR SPECIFIC PATTERNS ====" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Errors mentioning 'locationd':" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h 2>/dev/null | grep -i "locationd" | tail -5 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Errors mentioning 'Biome':" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h 2>/dev/null | grep -i "biome" | tail -5 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Errors mentioning 'Sandbox':" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h 2>/dev/null | grep -i "sandbox" | tail -5 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Errors mentioning 'TimeMachine' or 'TM':" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h 2>/dev/null | grep -i "time.*machine\|backupd" | tail -5 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "Errors mentioning your old drive (disk0 or Fusion):" | tee -a "$OUTPUT"
timeout 15 log show --predicate 'messageType == error' --last 1h 2>/dev/null | grep -i "disk0\|fusion" | tail -5 | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

echo "========================================" | tee -a "$OUTPUT"
echo "Report saved to: $OUTPUT" | tee -a "$OUTPUT"