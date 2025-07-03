#!/bin/bash

################################################################################
# Imprivata GroundControl Device Monitor
#
# Monitors iPhone checkout status via GroundControl API, tracking devices
# marked as Checked In, Checked Out, Overdue, or Failed.
#
# Devices with a Failed status are automatically rebooted via Workspace ONE
# if the total is within a safe reboot threshold (default: 50).
#
# Dependencies:
# - jq (brew install jq)
#
# Author: @brianirish
################################################################################

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------

# GroundControl API Key and endpoint
API_KEY="REPLACE_WITH_YOUR_KEY"
API_URL="https://www.groundctl.com/api/v1/devices/find/all?api_key=$API_KEY"

# Local path to save the API response
INPUT_FILE="/Users/yourusername/scripts/device_monitor/devices_output.json"

# Path to macOS system sound for alerting
ALERT_SOUND="/System/Library/Sounds/Funk.aiff"

# Workspace ONE OAuth token and reboot command configuration
TOKEN_CACHE_FILE="/Users/yourusername/scripts/device_monitor/ws1_token_cache.json"
TOKEN_LIFETIME_SECONDS=3600
TOKEN_URL="https://na.uemauth.workspaceone.com/connect/token"
CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
WS1_API_URL="https://YOUR_ENVIRONMENT.awmdm.com/API/mdm/devices/commands/bulk?command=softreset&searchby=Serialnumber"

# Safety limit: number of devices allowed for automated reboot
MAX_REBOOT_THRESHOLD=50

# ------------------------------------------------------------------------------
# NETWORK CHECK
# ------------------------------------------------------------------------------

echo ""
echo "🔍 Imprivata GroundControl Device Monitor"
echo "🌐 Checking internet connectivity..."

if ! ping -c 1 -W 1 google.com >/dev/null 2>&1; then
    echo "❌ No internet connection detected. Aborting script."
    exit 1
fi

echo "✅ Internet connection OK. Continuing..."

# ------------------------------------------------------------------------------
# CALL GROUNDCONTROL API
# ------------------------------------------------------------------------------

echo "📡 Contacting GroundControl API..."
curl --connect-timeout 60 --max-time 600 --retry 5 --retry-delay 5 \
    --compressed -o "$INPUT_FILE" -X GET "$API_URL" \
    -H "accept: application/json"

echo "📄 Response saved to: $INPUT_FILE"

# ------------------------------------------------------------------------------
# DEPENDENCY AND FILE VALIDATION
# ------------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is not installed. Please install with: brew install jq"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Input file not found: $INPUT_FILE"
    exit 1
fi

# ------------------------------------------------------------------------------
# PARSE DEVICES AND TRACK STATUS COUNTS
# ------------------------------------------------------------------------------

echo "🔄 Parsing device statuses..."

checked_in=0
checked_out=0
overdue=0
failed=0
overdue_serials=()
failed_serials=()

while read -r device; do
    serial=$(echo "$device" | jq -r '.serial')
    name=$(echo "$device" | jq -r '.name')
    model=$(echo "$device" | jq -r '.model')
    status=$(echo "$device" | jq -r '.checkout_status')

    echo "Serial: $serial"
    echo "Name: $name"
    echo "Model: $model"
    echo "Status: $status"
    echo "---"

    case "$status" in
        "Checked In") ((checked_in++)) ;;
        "Checked Out") ((checked_out++)) ;;
        "Overdue")
            ((overdue++))
            overdue_serials+=("$serial")
            ;;
        "Failed")
            ((failed++))
            failed_serials+=("$serial")
            ;;
    esac
done < <(jq -c '
.[] 
| { serial: .serial, name: .name, model: .modelName, 
    checkout_status: (.customFieldValues[]? 
                      | select(.name == "Device Checkout Status" 
                               and (.value == "Checked Out" 
                                    or .value == "Checked In" 
                                    or .value == "Failed" 
                                    or .value == "Overdue")) 
                      | .value)
}
| select(.checkout_status != null)
' "$INPUT_FILE")

# ------------------------------------------------------------------------------
# DISPLAY RESULTS
# ------------------------------------------------------------------------------

echo "📊 Totals:"
echo -e "✅ Checked In: $checked_in\n☑️ Checked Out: $checked_out\n❓ Overdue: $overdue\n❌ Failed: $failed"

if [ ${#failed_serials[@]} -gt 0 ]; then
    echo -e "\n❌ Failed Serial Numbers:"
    echo "${failed_serials[*]}" | sed 's/ /, /g'
fi

if [ ${#overdue_serials[@]} -gt 0 ]; then
    echo -e "\n❓ Overdue Serial Numbers:"
    echo "${overdue_serials[*]}" | sed 's/ /, /g'
fi

# Play system alert sound
afplay "$ALERT_SOUND"

# ------------------------------------------------------------------------------
# WORKSPACE ONE REBOOT LOGIC (for Failed devices)
# ------------------------------------------------------------------------------

if [ "$failed" -gt 0 ]; then
    echo ""
    if [ "$failed" -le "$MAX_REBOOT_THRESHOLD" ]; then
        echo "⚠️  Attempting soft reset on $failed failed device(s)..."

        get_ws1_token() {
            now=$(date +%s)
            if [ -f "$TOKEN_CACHE_FILE" ]; then
                token_age=$((now - $(stat -f %m "$TOKEN_CACHE_FILE")))
                if [ $token_age -lt $TOKEN_LIFETIME_SECONDS ]; then
                    ACCESS_TOKEN=$(jq -r '.access_token' "$TOKEN_CACHE_FILE")
                    return
                fi
            fi

            echo "🔐 Requesting new Workspace ONE access token..."
            TOKEN_RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET")

            echo "$TOKEN_RESPONSE" > "$TOKEN_CACHE_FILE"
            ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

            if [ "$ACCESS_TOKEN" == "null" ] || [ -z "$ACCESS_TOKEN" ]; then
                echo "❌ Failed to obtain Workspace ONE token. Skipping reboot."
                return 1
            fi
        }

        get_ws1_token || exit 1

        PAYLOAD=$(jq -n --argjson values "$(printf '%s\n' "${failed_serials[@]}" | jq -R . | jq -s .)" \
          '{BulkValues: {Value: $values}}')

        RESPONSE=$(curl -s -X POST "$WS1_API_URL" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$PAYLOAD")

        echo "✅ Workspace ONE Reboot Response:"
        echo "- Devices Processed: $(echo "$RESPONSE" | jq '.TotalItems')"
        echo "- Accepted: $(echo "$RESPONSE" | jq '.AcceptedItems')"
        echo "- Failed: $(echo "$RESPONSE" | jq '.FailedItems')"

    else
        echo "🛑 Too many failed devices ($failed). Reboot skipped for safety."
    fi
fi
