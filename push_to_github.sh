#!/bin/bash

REPO_DIR="/Users/slavicanikolic/Documents/imac-health-monitor"
BRANCH="main"
LOG_FILE="$HOME/Library/Logs/imac_health_push.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cd "$REPO_DIR" || {
  log "ERROR: Cannot cd into $REPO_DIR"
  exit 1
}

# Make sure we actually have a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "ERROR: $REPO_DIR is not a git repository"
  exit 1
fi

# Show status
log "Checking for local changes..."
STATUS=$(git status --porcelain)

if [ -z "$STATUS" ]; then
  log "No changes to commit."
  exit 0
fi

echo "The following changes will be committed:"
echo "$STATUS"
echo

# Commit message: use CLI args if provided, otherwise prompt
if [ "$#" -gt 0 ]; then
  COMMIT_MSG="$*"
else
  read -r -p "Enter commit message: " COMMIT_MSG
fi

if [ -z "$COMMIT_MSG" ]; then
  log "Aborting: commit message is empty."
  exit 1
fi

log "Staging all changes..."
git add -A

log "Committing with message: $COMMIT_MSG"
if ! git commit -m "$COMMIT_MSG"; then
  log "ERROR: git commit failed."
  exit 1
fi

log "Pushing to origin/$BRANCH..."
if git push origin "$BRANCH"; then
  log "Successfully pushed changes to origin/$BRANCH."
else
  log "ERROR: git push failed (check network/credentials)."
  exit 1
fi
