#!/bin/bash

# Path to your .env file
ENV_PATH="$HOME/Documents/imac-health-monitor/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "ERROR: .env file not found at $ENV_PATH"
    exit 1
fi

# Load environment variables
set -a
source "$ENV_PATH"
set +a

echo "Fetching Airtable schema..."
echo "Base ID: $AIRTABLE_BASE_ID"
echo ""

# Fetch schema and save to Desktop
curl "https://api.airtable.com/v0/meta/bases/${AIRTABLE_BASE_ID}/tables" \
  -H "Authorization: Bearer ${AIRTABLE_API_KEY}" \
  | jq '.' > ~/Desktop/airtable_schema.json

if [ $? -eq 0 ]; then
    echo "✅ Schema saved to ~/Desktop/airtable_schema.json"
    echo ""
    echo "Preview:"
    head -n 20 ~/Desktop/airtable_schema.json
else
    echo "❌ Failed to fetch schema"
fi