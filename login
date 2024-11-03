#!/bin/bash

SERVER_ENDPOINT=$1

if [ -z "$SERVER_ENDPOINT" ]; then
    echo "Usage: $0 <server-endpoint>"
    echo "Example: $0 https://example.yggdrasil.yushi.moe/api/yggdrasil"
    exit 1
fi

if [ $(uname) = "Linux" ]; then
    alias base64="base64 -w 0"
fi

# Function to select profile and return the index
select_profile() {
    local auth_response="$1"
    local profile_count=$(echo "$auth_response" | jq '.availableProfiles | length')
    
    echo "Multiple profiles found. Please select one:" >&2
    for i in $(seq 0 $(($profile_count - 1))); do
        local name=$(echo "$auth_response" | jq -r ".availableProfiles[$i].name")
        local id=$(echo "$auth_response" | jq -r ".availableProfiles[$i].id")
        echo "[$i] $name (ID: $id)" >&2
    done
    
    while true; do
        read -p "Enter profile number (0-$(($profile_count - 1))): " selection >&2
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "$profile_count" ]; then
            echo "$selection"
            break
        else
            echo "Invalid selection. Please try again." >&2
        fi
    done
}

# Function to handle authentication response
handle_auth_response() {
    local auth_response="$1"
    
    if echo "$auth_response" | jq -e 'has("error")' > /dev/null; then
        error_message=$(echo "$auth_response" | jq -r '.errorMessage')
        echo "Authentication failed: $error_message" >&2
        exit 1
    fi
    
    if echo "$auth_response" | jq -e 'has("availableProfiles")' > /dev/null; then
        profile_count=$(echo "$auth_response" | jq '.availableProfiles | length')
        
        if [ "$profile_count" -gt 1 ]; then
            # Get selected profile index
            local selection=$(select_profile "$auth_response")
            # Update auth response with selected profile
            local selected_profile=$(echo "$auth_response" | jq -r ".availableProfiles[$selection]")
            echo "$auth_response" | jq --argjson profile "$selected_profile" '. + {selectedProfile: $profile}'
        elif [ "$profile_count" -eq 1 ]; then
            echo "Only one available profile." >&2
            echo "$auth_response" | jq --argjson profile "$(echo "$auth_response" | jq '.availableProfiles[0]')" '. + {selectedProfile: $profile}'
        else
            echo "$auth_response"
        fi
    else
        echo "$auth_response"
    fi
}

main() {
    echo "Using server endpoint: $SERVER_ENDPOINT" >&2
    echo "Waiting for server response..." >&2
    
    server_response=$(curl -s "$SERVER_ENDPOINT")
    if [ $? -ne 0 ]; then
        echo "Failed to connect to server" >&2
        exit 1
    fi
    
    server_name=$(echo "$server_response" | jq -r ".meta.serverName")
    echo "Server name: $server_name" >&2
    echo "Note: when entering password, there is no echo on the screen." >&2
    
    read -p "Username: " username >&2
    read -s -p "Password: " password >&2
    echo >&2 # Add newline after password input
    
    echo "Getting client token..." >&2
    client_token=$(dd if=/dev/urandom count=1 2>/dev/null | base64 | cut -c1-128)
    
    # Make authentication request
    auth_response=$(curl -s -X POST -H "Content-Type: application/json" \
        "$SERVER_ENDPOINT/authserver/authenticate" \
        -d "{\"username\": \"$username\", \"password\": \"$password\", \"requestUser\": true, \"agent\": {\"name\": \"Minecraft\", \"version\": 1}, \"clientToken\": \"$client_token\"}")
    
    # Handle authentication response and get final JSON
    final_response=$(handle_auth_response "$auth_response")
    
    # Save the final response
    echo "$final_response" > authlib-token.json
    
    # Verify access token exists
    access_token=$(echo "$final_response" | jq -r ".accessToken")
    if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
        echo "Failed to get access token." >&2
        exit 1
    fi
    
    # Create authlib.env with proper content
    prefetch_data=$(echo "$server_response" | base64)
    {
        echo "CLIENT_TOKEN=$client_token"
        echo "SERVER_ADDRESS=$SERVER_ENDPOINT"
        echo "PREFETCH_DATA=$prefetch_data"
    } > authlib.env
    
    echo "Login Success!" >&2
    
    # Display selected profile information
    selected_name=$(echo "$final_response" | jq -r '.selectedProfile.name')
    selected_id=$(echo "$final_response" | jq -r '.selectedProfile.id')
    echo "Logged in as: $selected_name (ID: $selected_id)" >&2
}

# Run the main function
main
