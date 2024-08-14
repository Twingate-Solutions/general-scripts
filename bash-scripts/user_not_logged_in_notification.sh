#!/bin/bash

# Configuration Variables
PROCESS_NAME="Twingate" # Replace with the name of the process to check
RESOURCE_URL="https://internal.domain.com" # Replace with your resource URL
TEST_METHOD="get" # or "ping"

# Function to display macOS notification
function show_notification {
    local title="$1"
    local message="$2"
    osascript -e "display notification \"$message\" with title \"$title\""
}

# Function to check if the process is running
function is_process_running {
    pgrep -x "$PROCESS_NAME" > /dev/null 2>&1
}

# Function to test the Resource URL
function test_resource_url {
    if [ "$TEST_METHOD" == "get" ]; then
        STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$RESOURCE_URL")
        if [ "$STATUS_CODE" == "200" ]; then
            echo "[+] Resource test successful, user is logged in."
            return 0
        else
            echo "[-] Resource test failed, user is not logged in."
            return 1
        fi
    elif [ "$TEST_METHOD" == "ping" ]; then
        ping -c 1 -W 5 "$RESOURCE_URL" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[+] Ping test successful, user is logged in."
            return 0
        else
            echo "[-] Ping test failed, user is not logged in."
            return 1
        fi
    else
        echo "[-] Invalid test method specified."
        return 2
    fi
}

# Main Script
if is_process_running; then
    echo "[+] $PROCESS_NAME process is running, continuing script."

    if test_resource_url; then
        exit 0
    else
        show_notification "Twingate Status" "Have you forgotten to log in to Twingate? Please log in to access the network."
    fi
else
    echo "[+] $PROCESS_NAME process is not running, exiting script."
    exit 1
fi

