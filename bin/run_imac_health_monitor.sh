#!/bin/bash

# Change to the script directory
cd "$(dirname "$0")/.." || exit 1

# Run the health monitor script
./imac_health_monitor.sh

exit 0
