#!/bin/bash

# Make the script exit immediately if any command fails
set -e

# Set up empty variables that will be filled in later
mode=""          # Will hold the environment mode (dev/prod/local)
base_url=""      # Will store the API URL based on the mode
event_uid=""     # Will store the unique ID of the event we're working with

# Function to show how to use this script correctly
usage() {
    echo -e "Usage: $0 (-m|--mode) <dev|prod|local> (-e|--event-uid) <event_uid>"
    exit 1
}

# Process command line arguments one by one
while [[ $# -gt 0 ]]; do
    case $1 in
        # Handle --mode or -m argument
        --mode|-m)
            if [ -z "$2" ]; then
                echo -e "❌ Error: mode requires a value"
                usage
            fi
            mode="$2"
            shift 2
            ;;
        # Handle --event-uid or -e argument
        --event-uid|-e)
            if [ -z "$2" ]; then
                echo -e "❌ Error: event-uid requires a value"
                usage
            fi
            event_uid="$2"
            shift 2
            ;;
        # Handle any unexpected arguments
        *)
            echo -e "❌ Error: Unexpected argument: $1"
            usage
            ;;
    esac
done

# Make sure mode was provided
if [ -z "$mode" ]; then
    echo -e "❌ Error: mode is required"
    usage
fi

# Verify mode is one of: dev, prod, or local
if ! [[ "$mode" =~ ^(dev|prod|local)$ ]]; then
    echo -e "❌ Error: Invalid mode. Must be one of: dev, prod, local"
    usage
fi

# Make sure event_uid was provided
if [ -z "$event_uid" ]; then
    echo -e "❌ Error: event-uid is required"
    usage
fi

# Verify we're running this from inside a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo -e "❌ Error: Not in a git repository"
    exit 1
fi

# Set the appropriate API URL based on the mode
case "$mode" in
    "prod")
        base_url="https://review.iterate-ai.com"
        ;;
    "dev")
        base_url="https://iterate-review-dev.vercel.app"
        ;;
    "local")
        base_url="http://localhost:3001"
        ;;
esac

echo -e "\n🚀 Starting diff generation in $mode mode\n"

# Stage all changes in git
echo "Staging all files..."
git add -A

# Generate a diff of all staged changes
echo -e "🔍 Generating diff..."
if ! diff=$(git diff --cached --unified=50); then
    echo -e "❌ Error: Failed to generate diff"
    exit 1
fi

# Get information about the git repository
echo -e "📂 Getting git information..."
remote_url=$(git config --get remote.origin.url)
# Extract organization and repository names from the git URL
if [[ $remote_url =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    org="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
else
    echo -e "❌ Error: Could not parse git remote URL"
    exit 1
fi
branch=$(git rev-parse --abbrev-ref HEAD)
commit=$(git rev-parse HEAD)

# Prepare to send the diff to the API
echo -e "📤 Sending diff to API..."
# Escape the diff content for JSON
diff_escaped=$(echo "$diff" | jq -R -s '.')
# Create the JSON payload
json_data=$(jq -n \
    --arg event_id "$event_uid" \
    --arg diff_content "$diff" \
    '{
        "event_id": $event_id,
        "diff_content": $diff_content
    }')

echo -e "Debug: Sending request to $base_url/api/workbench/problems/diff"
# echo -e "Debug: JSON data: $json_data"

# Send the diff to the API and capture both the response and status code
response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$json_data" \
    "$base_url/api/workbench/problems/diff" 2>&1)

# Split response into body and status code
status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | sed '$d')

# Handle the API response
if [ "$status_code" -eq 201 ]; then
    # Success case
    echo -e "✨ Success!"
    echo "$response_body" | jq '.'
else
    # Error case
    echo -e "❌ Error: API request failed with status $status_code"
    # Try to format the error as JSON for better readability
    if ! echo "$response_body" | jq '.' >/dev/null 2>&1; then
        error_json=$(jq -n \
            --arg message "$response_body" \
            '{"error": $message}')
        echo "$error_json" | jq '.'
    else
        echo "$response_body" | jq '.'
    fi
fi

echo -e "\n✅ Diff generation complete\n"