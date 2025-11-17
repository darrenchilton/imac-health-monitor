#!/bin/bash

################################################################################
# Airtable Connection Test
# Tests your Airtable API configuration before running the full monitoring setup
################################################################################

echo "=========================================="
echo "Airtable Configuration Test"
echo "=========================================="
echo ""

# Prompt for configuration
read -p "Enter your Airtable API Key: " API_KEY
read -p "Enter your Airtable Base ID (starts with 'app'): " BASE_ID
read -p "Enter your Table Name [System Health]: " TABLE_NAME
TABLE_NAME=${TABLE_NAME:-"System Health"}

echo ""
echo "Testing configuration..."
echo "- API Key: ${API_KEY:0:10}... (first 10 chars)"
echo "- Base ID: $BASE_ID"
echo "- Table Name: $TABLE_NAME"
echo ""

# Test 1: List tables in base (requires read permission)
echo "Test 1: Checking API connection..."
RESPONSE=$(curl -s -w "\n%{http_code}" "https://api.airtable.com/v0/meta/bases/$BASE_ID/tables" \
  -H "Authorization: Bearer $API_KEY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ API connection successful!"
    echo ""
    echo "Available tables in your base:"
    echo "$BODY" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  - /'
else
    echo "✗ API connection failed!"
    echo "HTTP Status: $HTTP_CODE"
    echo "Response: $BODY"
    echo ""
    echo "Common issues:"
    echo "- API key is incorrect"
    echo "- Base ID is wrong"
    echo "- API key doesn't have access to this base"
    exit 1
fi

echo ""

# Test 2: Try to create a test record
echo "Test 2: Testing write access..."
TEST_RECORD=$(cat <<EOF
{
  "fields": {
    "Timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')",
    "Hostname": "TEST",
    "macOS Version": "Test Record",
    "SMART Status": "Verified",
    "Health Score": "Healthy",
    "Kernel Panics": "This is a test record",
    "System Errors": "Test: 0",
    "Drive Space": "Test",
    "Uptime": "Test",
    "Memory Pressure": "Test",
    "CPU Temperature": "Test",
    "Time Machine": "Test"
  }
}
EOF
)

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "https://api.airtable.com/v0/$BASE_ID/$TABLE_NAME" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$TEST_RECORD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Write access successful!"
    RECORD_ID=$(echo "$BODY" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    echo "✓ Test record created with ID: $RECORD_ID"
    echo ""
    
    # Offer to delete test record
    read -p "Delete test record? (y/n): " DELETE_TEST
    if [ "$DELETE_TEST" = "y" ] || [ "$DELETE_TEST" = "Y" ]; then
        DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
          "https://api.airtable.com/v0/$BASE_ID/$TABLE_NAME/$RECORD_ID" \
          -H "Authorization: Bearer $API_KEY")
        
        DELETE_CODE=$(echo "$DELETE_RESPONSE" | tail -1)
        if [ "$DELETE_CODE" = "200" ]; then
            echo "✓ Test record deleted"
        else
            echo "⚠ Could not delete test record (you can delete it manually in Airtable)"
        fi
    else
        echo "Test record left in table (you can delete it manually)"
    fi
else
    echo "✗ Write access failed!"
    echo "HTTP Status: $HTTP_CODE"
    echo "Response: $BODY"
    echo ""
    echo "Common issues:"
    echo "- Table name doesn't match (remember it's case-sensitive)"
    echo "- API key doesn't have write permission"
    echo "- Field names in script don't match your table"
    echo ""
    echo "Current table name you entered: '$TABLE_NAME'"
    echo "Make sure this EXACTLY matches your Airtable table name"
    exit 1
fi

echo ""
echo "=========================================="
echo "✓ All tests passed!"
echo "=========================================="
echo ""
echo "Your Airtable is configured correctly."
echo ""
echo "Next steps:"
echo "1. Edit imac_health_monitor.sh"
echo "2. Add these values at the top:"
echo "   AIRTABLE_API_KEY=\"$API_KEY\""
echo "   AIRTABLE_BASE_ID=\"$BASE_ID\""
echo "   AIRTABLE_TABLE_NAME=\"$TABLE_NAME\""
echo "3. Follow the SETUP_GUIDE.md for installation"
echo ""
