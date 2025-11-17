#!/bin/bash

################################################################################
# iMac Health Monitor - Setup Script
# Configures the monitoring system for local use
################################################################################

set -e

echo "=========================================="
echo "iMac Health Monitor - Setup"
echo "=========================================="
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This script must be run on macOS"
    exit 1
fi

CURRENT_USER=$(whoami)

# Step 1: Check if .env exists
echo "Step 1: Configure Credentials"
echo "------------------------------"
echo ""

if [ -f ".env" ]; then
    echo "⚠️  .env file already exists"
    read -p "Do you want to reconfigure it? (y/n): " RECONFIG
    if [ "$RECONFIG" != "y" ] && [ "$RECONFIG" != "Y" ]; then
        echo "Keeping existing .env configuration"
        source .env
    else
        CONFIGURE_ENV=true
    fi
else
    CONFIGURE_ENV=true
fi

if [ "$CONFIGURE_ENV" = true ]; then
    echo "You'll need your Airtable credentials:"
    echo "1. API Key from https://airtable.com/account"
    echo "2. Base ID from https://airtable.com/api"
    echo "3. Table Name (usually 'System Health')"
    echo ""
    
    read -p "Enter your Airtable API Key: " API_KEY
    read -p "Enter your Airtable Base ID: " BASE_ID
    read -p "Enter your Table Name [System Health]: " TABLE_NAME
    TABLE_NAME=${TABLE_NAME:-"System Health"}
    
    # Create .env file
    cat > .env <<EOF
# iMac Health Monitor Configuration
# This file is gitignored and will NOT be committed

AIRTABLE_API_KEY="$API_KEY"
AIRTABLE_BASE_ID="$BASE_ID"
AIRTABLE_TABLE_NAME="$TABLE_NAME"
EOF
    
    echo "✓ .env file created"
    source .env
fi

echo ""

# Step 2: Test Airtable connection
echo "Step 2: Test Airtable Connection"
echo "---------------------------------"
echo ""

TEST_RESPONSE=$(curl -s -w "\n%{http_code}" "https://api.airtable.com/v0/meta/bases/$AIRTABLE_BASE_ID/tables" \
  -H "Authorization: Bearer $AIRTABLE_API_KEY")

HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Airtable connection successful!"
else
    echo "✗ Airtable connection failed (HTTP $HTTP_CODE)"
    echo "Please check your credentials in .env"
    exit 1
fi

echo ""

# Step 3: Test the monitoring script
echo "Step 3: Test Monitoring Script"
echo "-------------------------------"
echo ""

read -p "Run a test health check? (y/n): " RUN_TEST

if [ "$RUN_TEST" = "y" ] || [ "$RUN_TEST" = "Y" ]; then
    echo ""
    echo "Running health check..."
    echo "========================"
    ./imac_health_monitor.sh
    echo "========================"
    echo ""
    
    read -p "Did the test succeed? Check Airtable for new record (y/n): " TEST_OK
    
    if [ "$TEST_OK" != "y" ] && [ "$TEST_OK" != "Y" ]; then
        echo ""
        echo "Please check the error messages and your Airtable configuration"
        exit 1
    fi
    
    echo "✓ Test successful!"
fi

echo ""

# Step 4: Install script and configure launchd
echo "Step 4: Configure Automated Execution"
echo "--------------------------------------"
echo ""
echo "Where would you like to run the script from?"
echo "1) /usr/local/bin (system-wide, requires sudo)"
echo "2) Keep in current directory (recommended for GitHub workflow)"
echo ""
read -p "Choose option (1 or 2): " INSTALL_LOCATION

if [ "$INSTALL_LOCATION" = "1" ]; then
    # Install to system location
    echo ""
    echo "Installing to /usr/local/bin (requires sudo)..."
    sudo mkdir -p /usr/local/bin
    
    # Create wrapper script that knows where .env is
    WRAPPER_SCRIPT=$(cat <<'WRAPPER_EOF'
#!/bin/bash
REPO_DIR="REPO_DIR_PLACEHOLDER"
cd "$REPO_DIR"
./imac_health_monitor.sh "$@"
WRAPPER_EOF
)
    
    echo "$WRAPPER_SCRIPT" | sed "s|REPO_DIR_PLACEHOLDER|$SCRIPT_DIR|" | sudo tee /usr/local/bin/imac_health_monitor.sh > /dev/null
    sudo chmod +x /usr/local/bin/imac_health_monitor.sh
    
    SCRIPT_PATH="/usr/local/bin/imac_health_monitor.sh"
    echo "✓ Installed to /usr/local/bin/imac_health_monitor.sh"
else
    # Use current directory
    SCRIPT_PATH="$SCRIPT_DIR/imac_health_monitor.sh"
    chmod +x "$SCRIPT_PATH"
    echo "✓ Will run from: $SCRIPT_PATH"
fi

echo ""

# Step 5: Configure schedule
echo "Step 5: Configure Schedule"
echo "--------------------------"
echo ""
echo "How often should health checks run?"
echo "1) Daily at 9:00 AM"
echo "2) Twice daily (9 AM and 9 PM)"
echo "3) Every 6 hours"
echo ""
read -p "Choose option (1-3): " SCHEDULE_OPTION

# Create configured plist
PLIST_FILE="$HOME/Library/LaunchAgents/com.user.imac.healthmonitor.plist"

case $SCHEDULE_OPTION in
    1)
        # Daily at 9 AM
        cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.imac.healthmonitor</string>
    <key>Program</key>
    <string>$SCRIPT_PATH</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stderr.log</string>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
        ;;
    2)
        # Twice daily
        cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.imac.healthmonitor</string>
    <key>Program</key>
    <string>$SCRIPT_PATH</string>
    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>21</integer>
            <key>Minute</key>
            <integer>0</integer>
        </dict>
    </array>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stderr.log</string>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
        ;;
    3)
        # Every 6 hours
        cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.imac.healthmonitor</string>
    <key>Program</key>
    <string>$SCRIPT_PATH</string>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/imac_health_monitor_stderr.log</string>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
        ;;
esac

# Load launch agent
mkdir -p ~/Library/LaunchAgents
launchctl unload "$PLIST_FILE" 2>/dev/null || true
launchctl load "$PLIST_FILE"

echo "✓ Launch agent configured and loaded"

# Verify
if launchctl list | grep -q "com.user.imac.healthmonitor"; then
    echo "✓ Launch agent is active"
else
    echo "⚠️  Warning: Launch agent may not be loaded correctly"
fi

echo ""

# Summary
echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration:"
echo "- Credentials: $SCRIPT_DIR/.env (gitignored)"
echo "- Script: $SCRIPT_PATH"
echo "- Launch agent: $PLIST_FILE"
echo "- Logs: ~/Library/Logs/imac_health_monitor*.log"
echo ""
echo "Useful commands:"
echo "- Run manually: $SCRIPT_PATH"
echo "- View logs: tail -50 ~/Library/Logs/imac_health_monitor.log"
echo "- Check status: launchctl list | grep healthmonitor"
echo ""
echo "To update from GitHub:"
echo "  cd $SCRIPT_DIR"
echo "  git pull"
echo "  ./setup.sh  # if needed to reconfigure"
echo ""
echo "Your .env file is gitignored and safe!"
echo ""
