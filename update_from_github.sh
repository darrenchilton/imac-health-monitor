#!/bin/bash

REPO_DIR="/Users/slavicanikolic/Documents/imac-health-monitor"
LOG_FILE="$HOME/Library/Logs/imac_health_updater.log"
BRANCH="main"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

cd "$REPO_DIR" || {
  log "ERROR: Cannot cd into $REPO_DIR"
  exit 1
}

# OPTIONAL: if you *never* want local edits and always want to match GitHub,
# uncomment this line to force local to remote each run.
# git reset --hard "origin/$BRANCH" 2>>"$LOG_FILE"

# Fetch latest from origin
if ! git fetch origin >>"$LOG_FILE" 2>&1; then
  log "ERROR: git fetch failed"
  exit 1
fi

LOCAL_SHA=$(git rev-parse "$BRANCH" 2>/dev/null)
REMOTE_SHA=$(git rev-parse "origin/$BRANCH" 2>/dev/null)

if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
  log "No updates; $BRANCH is already up to date."
  exit 0
fi

log "Updates found on origin/$BRANCH (local=$LOCAL_SHA remote=$REMOTE_SHA); pulling..."

if git pull --ff-only origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
  # Ensure main script is executable after pull
  chmod +x imac_health_monitor.sh 2>>"$LOG_FILE" || true
  log "Successfully pulled latest changes and updated script."
else
  log "ERROR: git pull failed (possible merge conflict or local changes)."
fi
