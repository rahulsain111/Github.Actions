#!/bin/bash

# get-eligible-env-ids.sh - Script to fetch environment IDs that have a specific tag deployed
#
# This script fetches all applications for a given organization in Acquia Cloud,
# then fetches environments for each application, filters for production or single environments,
# and checks if they have the specified tag deployed.
#
# Authentication is handled automatically using the embedded API credentials.
# If a token expires during execution, it will be automatically refreshed.
#
# Usage: ./get-eligible-env-ids.sh [-d] [ORGANIZATION_ID] <TAG_NAME>
#   Options:
#     -d: Enable debug mode with verbose logging
#   Arguments:
#     ORGANIZATION_ID: The ID of the organization in Acquia Cloud (optional, default provided)
#     TAG_NAME: The tag to check for, e.g., "cms-2.15.2" (required)
#
# Examples:
#   ./get-eligible-env-ids.sh cms-2.15.2
#   ./get-eligible-env-ids.sh 9509f888-c6af-443c-8dd4-0e13eda9f83b cms-2.15.2
#   ./get-eligible-env-ids.sh -d cms-2.15.2  # Run with debug output

# Exit on error
set -e

# Enable debug mode with -d flag
DEBUG=false
while getopts ":d" opt; do
  case ${opt} in
    d )
      DEBUG=true
      ;;
    \? )
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# Debug logging function
debug_log() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# Try to load API credentials from .env.prod file if it exists
ENV_FILE="$(dirname "$(dirname "$0")")/.env.prod"
if [ -f "$ENV_FILE" ]; then
    debug_log "Loading credentials from $ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    debug_log "Credentials loaded from $ENV_FILE"
fi

# At this point, credentials could be from:
# 1. .env.prod file we just sourced
# 2. Already set in the environment (e.g., from .bashrc, .zshrc, or direct export)
# Just check if they exist, regardless of source

# Check if API credentials are available from any source
if [ -z "$CLOUD_API_KEY" ] || [ -z "$CLOUD_SECRET_KEY" ]; then
    echo "Error: Missing API credentials" >&2
    echo "Please ensure CLOUD_API_KEY and CLOUD_SECRET_KEY are available from one of these sources:" >&2
    echo "  - In a .env.prod file in the project root" >&2
    echo "  - Exported in your shell environment (.bashrc, .zshrc, etc.)" >&2
    echo "  - Directly exported before running this script (e.g., export CLOUD_API_KEY=...)" >&2
    exit 1
fi

# If we get here, both credentials are available, so proceed with the script

# Authentication endpoint
AUTH_URL="https://id.acquia.com/oauth2/default/v1/token"
debug_log "Using CLOUD_API_KEY: ${CLOUD_API_KEY}"
debug_log "Using CLOUD_SECRET_KEY: ${CLOUD_SECRET_KEY}"
# Function to get a new access token
get_access_token() {
    # Important: Send user messages to stderr to avoid polluting the token
    echo "Fetching new access token..." >&2

    debug_log "Requesting token from $AUTH_URL with client_id=$CLOUD_API_KEY"

    # Create a temporary file for the token response
    local token_response_file=$(mktemp)

    # Use curl with more explicit options for debugging
    curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "User-Agent: Constellation-Ship-Release/1.0" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$CLOUD_API_KEY" \
        --data-urlencode "client_secret=$CLOUD_SECRET_KEY" \
        "$AUTH_URL" > "$token_response_file" 2>/dev/null

    local response=$(cat "$token_response_file")

    # Debug raw response (safely truncated)
    debug_log "Raw token response: ${response:0:100}...[truncated]"

    # Extract the access token from the response using grep as a fallback if jq fails
    local access_token
    if command -v jq &> /dev/null; then
        access_token=$(jq -r '.access_token' "$token_response_file")
    else
        # Fallback to grep and sed if jq is not available
        access_token=$(grep -o '"access_token":"[^"]*"' "$token_response_file" | sed 's/"access_token":"\(.*\)"/\1/')
    fi

    # Clean up temp file
    rm -f "$token_response_file"

    if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
        echo "Error fetching access token. Response preview: ${response:0:100}" >&2
        debug_log "Token fetch failed."
        return 1
    fi

    # Debug token length and first few characters
    debug_log "Successfully obtained new access token (${#access_token} characters)"
    debug_log "Token starts with: ${access_token:0:10}..."

    # Only output the actual token to stdout for capture
    printf "%s" "$access_token"
    return 0
}

# Base URL for Acquia Cloud API
BASE_URL="https://cloud.acquia.com/api"

# Sites Aggregation Service URL
SITES_API_URL="https://sites-aggregation-service-prod.prod.cicd.acquia.io/api"

# Set default organization ID
DEFAULT_ORG_ID="9509f888-c6af-443c-8dd4-0e13eda9f83b"

# Check if required arguments are provided
if [ "$#" -lt 1 ]; then
    echo "Error: Missing required arguments."
    echo ""
    echo "Usage: $0 [-d] [ORGANIZATION_ID] <TAG_NAME>"
    echo ""
    echo "Options:"
    echo "  -d                  Enable debug mode with verbose logging"
    echo ""
    echo "Arguments:"
    echo "  ORGANIZATION_ID     The ID of the organization in Acquia Cloud (optional)"
    echo "  TAG_NAME           The tag to check for, e.g., 'cms-2.15.2' (required)"
    echo ""
    echo "Examples:"
    echo "  $0 cms-2.15.2"
    echo "  $0 9509f888-c6af-443c-8dd4-0e13eda9f83b cms-2.15.2"
    echo "  $0 -d cms-2.15.2   # Run with debug output"
    exit 1
fi

# Get access token
debug_log "Obtaining initial access token..."
TOKEN=$(get_access_token)
if [ $? -ne 0 ]; then
    echo "Failed to get access token, aborting."
    exit 1
fi

# Verify token format - it should be in JWT format starting with ey...
if [[ ! "$TOKEN" =~ ^ey ]]; then
    echo "Error: Token appears to be malformed. Should start with 'ey', got: ${TOKEN:0:10}"
    debug_log "FULL TOKEN: $TOKEN"
    debug_log "TOKEN LENGTH: ${#TOKEN}"
    exit 1
fi

# Print a token prefix for debugging (safely)
debug_log "Authentication successful. Token acquired: ${TOKEN:0:10}...[truncated]"
debug_log "Token length: ${#TOKEN}"

# Make sure the token isn't empty or just whitespace
if [ -z "${TOKEN// /}" ]; then
    echo "Error: Obtained token is empty. Authentication failed."
    exit 1
fi

# Check if we have 1 or 2 arguments to determine the position of TAG_NAME
if [ "$#" -eq 1 ]; then
    # If we have 1 argument, it's the TAG_NAME and we use default org ID
    ORGANIZATION_ID=$DEFAULT_ORG_ID
    TAG_NAME=$1
else
    # If we have 2+ arguments, the first is org ID and second is TAG_NAME
    ORGANIZATION_ID=$1
    TAG_NAME=$2
fi

echo "Will check for environments with tag: $TAG_NAME"
debug_log "Organization ID: $ORGANIZATION_ID"

# Function to make API requests with auto token refresh on auth errors (401/403)
make_request() {
    local endpoint=$1
    local method=${2:-GET}
    local data=$3
    local max_retries=2  # Increased from 1 to 2
    local retry_count=0

    while [ $retry_count -le $max_retries ]; do
        local response
        local http_code

        # Make the API request and capture both response and status code
        debug_log "Making $method request to $endpoint"
        if [ "$method" = "GET" ]; then
            debug_log "curl -s -X $method -H 'Authorization: Bearer ***' -H 'Content-Type: application/json' '$BASE_URL$endpoint'"
            # Print token length for debugging
            debug_log "Token length: ${#TOKEN}"

            # Add extra debug for first few characters of token
            if [ "$DEBUG" = true ] && [ ! -z "$TOKEN" ]; then
                token_prefix="${TOKEN:0:10}"
                debug_log "Using token starting with: $token_prefix..."
            fi

            # Ensure we're using the current global TOKEN value
            # Construct Authorization header carefully to ensure proper format
            AUTH_HEADER="Authorization: Bearer $TOKEN"
            debug_log "Auth header length: ${#AUTH_HEADER}"

            response=$(curl -s -w "%{http_code}" -X $method \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                "$BASE_URL$endpoint")
        else
            debug_log "curl -s -X $method -H 'Authorization: Bearer ***' -H 'Content-Type: application/json' -d '$data' '$BASE_URL$endpoint'"
            # Print token length for debugging
            debug_log "Token length: ${#TOKEN}"

            # Add extra debug for first few characters of token
            if [ "$DEBUG" = true ] && [ ! -z "$TOKEN" ]; then
                token_prefix="${TOKEN:0:10}"
                debug_log "Using token starting with: $token_prefix..."
            fi

            # Ensure we're using the current global TOKEN value
            # Construct Authorization header carefully to ensure proper format
            AUTH_HEADER="Authorization: Bearer $TOKEN"
            debug_log "Auth header length: ${#AUTH_HEADER}"

            response=$(curl -s -w "%{http_code}" -X $method \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "$BASE_URL$endpoint")
        fi

        # Extract HTTP status code (last 3 chars of response)
        http_code=${response: -3}
        # Extract the actual response body (everything except last 3 chars)
        body=${response:0:${#response}-3}

        debug_log "HTTP status code: $http_code"
        debug_log "Response preview: ${body:0:100}...[truncated]"

        # Check for token expiration (401 Unauthorized or 403 Forbidden)
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            # Check if it's a token expiration error or authorization error
            local message=$(echo "$body" | jq -r '.message // ""')
            local error=$(echo "$body" | jq -r '.error // ""')

            debug_log "Error message: $message"
            debug_log "Error type: $error"

            # Handle various error messages that indicate token issues
            if [[ "$message" == *"token has expired"* || \
                  "$message" == *"Invalid access token"* || \
                  "$message" == *"missing access token"* || \
                  "$message" == *"Authorization header is missing"* || \
                  "$error" == "unauthorized" ]]; then

                if [ $retry_count -lt $max_retries ]; then
                    echo "Authentication error ($http_code). Refreshing token and retrying..." >&2
                    debug_log "HTTP $http_code received with auth error message. Attempting to refresh."

                    # Get a new access token and export it to ensure it's available globally
                    # Using command substitution in global context to ensure TOKEN is updated globally
                    TOKEN=$(get_access_token)
                    if [ $? -ne 0 ]; then
                        echo "Failed to refresh access token. Aborting." >&2
                        return 1
                    fi

                    # Verify the new token
                    debug_log "New token acquired. New token length: ${#TOKEN}"
                    debug_log "New token starts with: ${TOKEN:0:10}..."

                    # Validate the token is not empty
                    if [ -z "$TOKEN" ]; then
                        echo "Error: New token is empty. Cannot continue." >&2
                        return 1
                    fi

                    retry_count=$((retry_count+1))
                    # Wait a moment before retrying to ensure token is properly registered
                    sleep 1
                    continue
                else
                    echo "Maximum retries reached. Giving up." >&2
                    return 1
                fi
            fi
        fi

        # Check for other error responses
        local error=$(echo "$body" | jq -r '.error // empty')
        if [ -n "$error" ] || [ "$http_code" != "200" ]; then
            echo "Error from API (HTTP $http_code): $error" >&2
            echo "Message: $(echo "$body" | jq -r '.message // "No message"')" >&2
            return 1
        fi

        # If we get here, the request was successful
        echo "$body"
        return 0
    done
}

# Function to check if a site exists for a given application
check_site_exists() {
    local app_id=$1

    debug_log "Checking if site exists for application: $app_id"

    # Make request to sites aggregation service
    local response
    local http_code
    local max_retries=2
    local retry_count=0

    while [ $retry_count -le $max_retries ]; do
        debug_log "Making GET request to $SITES_API_URL/applications/$app_id/sites"

        # Make the API request to sites aggregation service
        response=$(curl -s -w "%{http_code}" -X GET \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            "$SITES_API_URL/applications/$app_id/sites")

        # Extract HTTP status code (last 3 chars of response)
        http_code=${response: -3}
        # Extract the actual response body (everything except last 3 chars)
        local body=${response:0:${#response}-3}

        debug_log "Sites API HTTP status code: $http_code"
        debug_log "Sites API response preview: ${body:0:100}...[truncated]"

        # Check for token expiration (401 Unauthorized or 403 Forbidden)
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            local message=$(echo "$body" | jq -r '.message // ""' 2>/dev/null || echo "")
            local error=$(echo "$body" | jq -r '.error // ""' 2>/dev/null || echo "")

            debug_log "Sites API error message: $message"
            debug_log "Sites API error type: $error"

            # Handle various error messages that indicate token issues
            if [[ "$message" == *"token has expired"* || \
                  "$message" == *"Invalid access token"* || \
                  "$message" == *"missing access token"* || \
                  "$message" == *"Authorization header is missing"* || \
                  "$error" == "unauthorized" ]]; then

                if [ $retry_count -lt $max_retries ]; then
                    echo "Authentication error ($http_code) for sites API. Refreshing token and retrying..." >&2
                    debug_log "Sites API HTTP $http_code received with auth error message. Attempting to refresh."

                    # Get a new access token
                    TOKEN=$(get_access_token)
                    if [ $? -ne 0 ]; then
                        echo "Failed to refresh access token for sites API. Aborting." >&2
                        return 1
                    fi

                    debug_log "New token acquired for sites API. New token length: ${#TOKEN}"
                    retry_count=$((retry_count+1))
                    sleep 1
                    continue
                else
                    echo "Maximum retries reached for sites API. Giving up." >&2
                    return 1
                fi
            fi
        fi

        # Check if the request was successful
        if [ "$http_code" = "200" ]; then
            # Parse the response to check if sites exist
            local site_count=$(echo "$body" | jq -r '.count // 0' 2>/dev/null || echo "0")

            debug_log "Site count for application $app_id: $site_count"

            if [ "$site_count" -gt 0 ]; then
                debug_log "Site exists for application $app_id"
                return 0  # Site exists
            else
                debug_log "No site exists for application $app_id"
                return 1  # No site exists
            fi
        else
            echo "Error from Sites API (HTTP $http_code) for application $app_id" >&2
            debug_log "Sites API error body: $body"
            return 1
        fi
    done

    return 1  # Default to no site exists if we can't determine
}

echo "Fetching applications for organization $ORGANIZATION_ID..."
ELIGIBLE_ENV_IDS=()
ELIGIBLE_SSH_URLS=()
debug_log "Initializing eligible environments list and SSH URLs"

# Get all applications for the organization
APPLICATIONS=$(make_request "/organizations/$ORGANIZATION_ID/applications")
if [ $? -ne 0 ]; then
    echo "Failed to retrieve applications for organization $ORGANIZATION_ID"
    exit 1
fi

# Extract application IDs
APPLICATION_IDS=$(echo "$APPLICATIONS" | jq -r '._embedded.items[].uuid // empty')

if [ -z "$APPLICATION_IDS" ]; then
    echo "No applications found for organization $ORGANIZATION_ID"
    exit 0
fi

# Process each application
for APP_ID in $APPLICATION_IDS; do
    echo "Processing application $APP_ID..."

    # Check if a site exists for this application
    echo "  Checking if site exists for application $APP_ID..."
    if check_site_exists "$APP_ID"; then
        echo "  ✓ Site exists for application $APP_ID"
    else
        echo "  ✗ No site exists for application $APP_ID, skipping"
        continue
    fi

    # Get all environments for the application
    ENVIRONMENTS=$(make_request "/applications/$APP_ID/environments")
    if [ $? -ne 0 ]; then
        echo "  Failed to retrieve environments for application $APP_ID, skipping"
        continue
    fi

    # Check if we got any environments back
    ENV_COUNT=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items | length // 0')

    if [ "$ENV_COUNT" -eq 0 ]; then
        echo "  No environments found for application $APP_ID"
        continue
    fi

    # Add debug output to see what's going on
    echo "  DEBUG: Examining JSON structure for environment filtering"
    ENV_ITEMS=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items | length')
    echo "  DEBUG: Found $ENV_ITEMS environments"

    # Process environments based on count and name
    if [ "$ENV_COUNT" -eq 1 ]; then
        # If only one environment, use it regardless of name
        ENV_IDS=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items[].id')
        echo "  DEBUG: Single environment detected, using ID: $ENV_IDS"
    else
        # Try a simpler approach first - just look for prod in the name
        ENV_IDS=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items[] | select(.name | test("prod"; "i")) | .id')
        echo "  DEBUG: Selected environments by name: $ENV_IDS"

        # Only try to use flags if no environments matched by name
        if [ -z "$ENV_IDS" ]; then
            echo "  DEBUG: No environments matched by name, trying to check flags"

            # First check if we can access flags at all (debug purpose)
            FIRST_ENV_TYPE=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items[0] | type')
            FIRST_FLAGS_TYPE=$(echo "$ENVIRONMENTS" | jq -r '._embedded.items[0].flags | type')
            echo "  DEBUG: First environment type: $FIRST_ENV_TYPE, flags field type: $FIRST_FLAGS_TYPE"

            # Try a safer approach - manually iterate through environments
            for ((i=0; i<$ENV_ITEMS; i++)); do
                ENV_ID=$(echo "$ENVIRONMENTS" | jq -r "._embedded.items[$i].id")
                HAS_PROD_FLAG=$(echo "$ENVIRONMENTS" | jq -r "try ._embedded.items[$i].flags.production catch false")
                if [ "$HAS_PROD_FLAG" = "true" ]; then
                    echo "  DEBUG: Found environment $ENV_ID with production flag"
                    if [ -z "$ENV_IDS" ]; then
                        ENV_IDS="$ENV_ID"
                    else
                        ENV_IDS="$ENV_IDS $ENV_ID"
                    fi
                fi
            done
        fi
    fi

    if [ -z "$ENV_IDS" ]; then
        echo "  No production environments found for application $APP_ID"
        continue
    fi

    # Process each environment
    for ENV_ID in $ENV_IDS; do
        ENV_NAME=$(echo "$ENVIRONMENTS" | jq -r --arg ENV_ID "$ENV_ID" '._embedded.items[] | select(.id == $ENV_ID) | .name // "unknown"')
        if [ "$ENV_NAME" = "unknown" ]; then
            ENV_NAME="ID: $ENV_ID"
        fi
        echo "  Processing environment $ENV_NAME ($ENV_ID)..."

        # Extract the deployed tag directly from the environments response
        DEPLOYED_TAG=$(echo "$ENVIRONMENTS" | jq -r --arg ENV_ID "$ENV_ID" '._embedded.items[] | select(.id == $ENV_ID) | .vcs.path // "unknown"')

        if [ "$DEPLOYED_TAG" = "unknown" ] || [ -z "$DEPLOYED_TAG" ]; then
            echo "    Could not determine deployed tag, skipping"
            continue
        fi

        # Extract SSH URL from the environment data - the field is directly available at the environment level
        SSH_URL=$(echo "$ENVIRONMENTS" | jq -r --arg ENV_ID "$ENV_ID" '._embedded.items[] | select(.id == $ENV_ID) | .ssh_url // "unknown"')

        if [ "$SSH_URL" = "unknown" ] || [ -z "$SSH_URL" ]; then
            echo "    SSH URL not available for this environment"
        else
            echo "    SSH URL: $SSH_URL"
        fi

        echo "    Current deployed tag: $DEPLOYED_TAG"

        # Check if the deployed tag matches the target tag
        if [ "$DEPLOYED_TAG" = "tags/$TAG_NAME" ]; then
            echo "    ✓ Environment has the target tag deployed"
            ELIGIBLE_ENV_IDS+=("$ENV_ID")
            ELIGIBLE_SSH_URLS+=("$SSH_URL")
        else
            echo "    ✗ Environment does not have the target tag deployed"
        fi
    done
done

echo "Checking for eligible environments completed."
debug_log "Processing complete. Found ${#ELIGIBLE_ENV_IDS[@]} eligible environments."

if [ ${#ELIGIBLE_ENV_IDS[@]} -eq 0 ]; then
    echo "No eligible environments found with tag: $TAG_NAME"
    exit 0
fi

echo -e "\nEligible environments with tag '$TAG_NAME':"
for i in "${!ELIGIBLE_ENV_IDS[@]}"; do
    echo "Environment ID: ${ELIGIBLE_ENV_IDS[$i]}"
    echo "SSH URL: ${ELIGIBLE_SSH_URLS[$i]}"
    echo "-------------------"
done

# Also output environment IDs as a comma-separated list for easy copying
IFS=,
ELIGIBLE_CSV="${ELIGIBLE_ENV_IDS[*]}"
echo -e "\nEnvironment IDs (comma-separated) for easy copying:"
echo "$ELIGIBLE_CSV"

# Also output space-separated list of environment IDs for easy copying
IFS=' '
ELIGIBLE_SPACE="${ELIGIBLE_ENV_IDS[*]}"
echo -e "\nEnvironment IDs (space-separated) for easy copying:"
echo "$ELIGIBLE_SPACE"

# Also output SSH URLs as a comma-separated list for easy copying
IFS=,
ELIGIBLE_SSH_URLS_CSV="${ELIGIBLE_SSH_URLS[*]}"
echo -e "\nSSH URLs (comma-separated) for easy copying:"
echo "$ELIGIBLE_SSH_URLS_CSV"

# Also output SSH URLs and environment IDs in a way that's easy to use with other tools
echo -e "\nEnvironment ID to SSH URL mapping (useful for scripting):"
for i in "${!ELIGIBLE_ENV_IDS[@]}"; do
    echo "${ELIGIBLE_ENV_IDS[$i]}:${ELIGIBLE_SSH_URLS[$i]}"
done
