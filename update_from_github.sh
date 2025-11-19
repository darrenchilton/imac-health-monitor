#!/bin/bash

# update_from_github.sh
# Auto-updates the health monitor from GitHub and checks for remote trigger

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$HOME/Library/Logs/imac_health_updater.log"

# Create log file if it doesn't exist
touch "$LOG_FILE"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "=== Starting GitHub update check ==="

# Navigate to script directory
cd "$SCRIPT_DIR" || {
    log_message "ERROR: Could not change to directory $SCRIPT_DIR"
    exit 1
}

# Fetch latest changes from GitHub
log_message "Fetching from GitHub..."
git fetch origin main 2>&1 | tee -a "$LOG_FILE"

# Check if there are updates
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" != "$REMOTE" ]; then
    log_message "Updates found! Pulling changes..."
    git pull origin main 2>&1 | tee -a "$LOG_FILE"
    
    # Make sure scripts are executable
    chmod +x imac_health_monitor.sh 2>&1 | tee -a "$LOG_FILE"
    chmod +x update_from_github.sh 2>&1 | tee -a "$LOG_FILE"
    chmod +x push_to_github.sh 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Update complete!"
else
    log_message "Already up to date."
fi

# ============================================
# CHECK FOR REMOTE TRIGGER FILE
# ============================================

if [ -f "$SCRIPT_DIR/.run_monitor_now" ]; then
    log_message "🎯 TRIGGER FILE DETECTED! Running health monitor..."
    
    # Run the monitor script
    "$SCRIPT_DIR/imac_health_monitor.sh" 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Monitor execution complete. Cleaning up trigger file..."
    
    # Remove the trigger file
    rm "$SCRIPT_DIR/.run_monitor_now"
    
    # Commit and push the removal
    git add .run_monitor_now
    git commit -m "Auto-remove trigger file after execution" 2>&1 | tee -a "$LOG_FILE"
    git push origin main 2>&1 | tee -a "$LOG_FILE"
    
    log_message "✅ Trigger file removed from repo."
else
    log_message "No trigger file detected."
fi

log_message "=== Update check complete ===\n"
exit 0