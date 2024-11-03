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

# [Previous functions remain unchanged: detect_java, detect_authlib, select_profile]
detect_java() {
    local java_path=""
    
    if command -v java >/dev/null 2>&1; then
        java_path=$(command -v java)
        if [ -L "$java_path" ]; then
            java_path=$(readlink -f "$java_path")
        fi
    fi
    
    if [ -z "$java_path" ]; then
        echo "Java not found in PATH." >&2
        read -p "Please enter the full path to your Java executable (including 'java' or 'java.exe'): " java_path >&2
    fi
    
    if [ ! -f "$java_path" ]; then
        echo "Warning: The specified Java path does not exist or is not accessible." >&2
        read -p "Please enter the correct path to your Java executable: " java_path >&2
    fi
    
    if [[ "$java_path" == *" "* ]]; then
        java_path="\"$java_path\""
    fi
    
    echo "$java_path"
}

detect_authlib() {
    local authlib_name=""
    
    if [ -f "authlib-injector.jar" ]; then
        authlib_name="authlib-injector.jar"
    else
        local versioned_jar=$(ls authlib-injector-*.jar 2>/dev/null | head -n 1)
        if [ ! -z "$versioned_jar" ]; then
            authlib_name="$versioned_jar"
        else
            echo "authlib-injector.jar not found in current directory." >&2
            read -p "Please enter the name of your authlib-injector jar file: " authlib_name >&2
            
            while [ ! -f "$authlib_name" ]; do
                echo "File not found: $authlib_name" >&2
                read -p "Please enter the correct authlib-injector jar filename: " authlib_name >&2
            done
        fi
    fi
    
    echo "$authlib_name"
}

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

refresh_token() {
    local access_token="$1"
    local client_token="$2"
    local profile_id="$3"
    local profile_name="$4"
    
    echo "Refreshing token..." >&2
    local refresh_response=$(curl -s -X POST -H "Content-Type: application/json" \
        "$SERVER_ENDPOINT/authserver/refresh" \
        -d "{
            \"accessToken\": \"$access_token\",
            \"clientToken\": \"$client_token\",
            \"requestUser\": false,
            \"selectedProfile\": {
                \"id\": \"$profile_id\",
                \"name\": \"$profile_name\",
                \"properties\": []
            }
        }")
    
    if echo "$refresh_response" | jq -e 'has("error")' > /dev/null; then
        error_message=$(echo "$refresh_response" | jq -r '.errorMessage')
        echo "Token refresh failed: $error_message" >&2
        return 1
    fi
    
    echo "$refresh_response"
}

handle_auth_response() {
    local auth_response="$1"
    local client_token="$2"
    
    if echo "$auth_response" | jq -e 'has("error")' > /dev/null; then
        error_message=$(echo "$auth_response" | jq -r '.errorMessage')
        echo "Authentication failed: $error_message" >&2
        exit 1
    fi
    
    if echo "$auth_response" | jq -e 'has("availableProfiles")' > /dev/null; then
        profile_count=$(echo "$auth_response" | jq '.availableProfiles | length')
        local access_token=$(echo "$auth_response" | jq -r '.accessToken')
        
        if [ "$profile_count" -gt 1 ]; then
            local selection=$(select_profile "$auth_response")
            local profile=$(echo "$auth_response" | jq ".availableProfiles[$selection]")
            local profile_id=$(echo "$profile" | jq -r '.id')
            local profile_name=$(echo "$profile" | jq -r '.name')
            
            refresh_response=$(refresh_token "$access_token" "$client_token" "$profile_id" "$profile_name")
            if [ $? -eq 0 ]; then
                echo "$refresh_response"
            else
                exit 1
            fi
        elif [ "$profile_count" -eq 1 ]; then
            echo "Only one profile available." >&2
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
    
    INST_JAVA=$(detect_java)
    AUTHLIB_INJECTOR_NAME=$(detect_authlib)
    
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
    echo >&2
    
    echo "Getting client token..." >&2
    client_token=$(dd if=/dev/urandom count=1 2>/dev/null | base64 | cut -c1-128)
    
    auth_response=$(curl -s -X POST -H "Content-Type: application/json" \
        "$SERVER_ENDPOINT/authserver/authenticate" \
        -d "{\"username\": \"$username\", \"password\": \"$password\", \"requestUser\": true, \"agent\": {\"name\": \"Minecraft\", \"version\": 1}, \"clientToken\": \"$client_token\"}")
    
    final_response=$(handle_auth_response "$auth_response" "$client_token")
    
    echo "$final_response" > authlib-token.json
    
    access_token=$(echo "$final_response" | jq -r ".accessToken")
    if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
        echo "Failed to get access token." >&2
        exit 1
    fi
    
    prefetch_data=$(printf '%s' "$server_response" | base64)
    {
        echo "CLIENT_TOKEN=$client_token"
        echo "SERVER_ADDRESS=$SERVER_ENDPOINT"
        echo "PREFETCH_DATA=$prefetch_data"
        echo "INST_JAVA=$INST_JAVA"
        echo "AUTHLIB_INJECTOR_NAME=$AUTHLIB_INJECTOR_NAME"
    } > authlib.env
    
    echo "Login Success!" >&2
    
    selected_name=$(echo "$final_response" | jq -r '.selectedProfile.name')
    selected_id=$(echo "$final_response" | jq -r '.selectedProfile.id')
    echo "Logged in as: $selected_name (ID: $selected_id)" >&2
}

main
