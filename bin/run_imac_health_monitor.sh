#!/bin/bash
set -e

# Go to the repo
cd /Users/slavicanikolic/Documents/imac-health-monitor

# Get latest version from GitHub
/usr/bin/git pull --rebase --ff-only

# Run the health monitor script
./imac_health_monitor.sh
