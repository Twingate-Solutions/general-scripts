#!/bin/bash

# Configuration Variables
PROCESS_NAME="Twingate" 	  # Replace with the name of the process to check
RESOURCE_URL="http://10.50.51.76" # Replace with your resource URL
TEST_METHOD="netcat"		  # Specify "get" or "ping" or "netcat"
NETCAT_HOST="10.50.51.76"         # Replace with host for netcat test
NETCAT_PORT="80"		  # Replace with port for netcat test
TEST_TIMEOUT="5"	          # Specify timeout length

# Function to display macOS notification
function show_notification {
    local title="$1"
    local subtitle="$2"
    local message="$3"
    local soundname="$4"
    osascript -e "display notification \"$message\" with title \"$title\" subtitle \"$subtitle\" sound name \"default\""
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
    elif [ "$TEST_METHOD" == "netcat" ]; then
        nc -z -v -G "$TEST_TIMEOUT" "$NETCAT_HOST" "$NETCAT_PORT" > /dev/null 2>&1
	if [ $? -eq 0 ]; then
	    echo "[+] Netcat test successful, user is logged in."
	    return 0
	else
            echo "[-] Netcat test failed, user is not logged in."
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
        echo "[+] Resource is accessible, no notification needed!"
        exit 0
    else
	echo "[-] Resource is not accessible, sending notification."
        show_notification "Twingate" "User is not logged in" "Have you forgotten to log in to Twingate? Please log in to access the network." "default"
    fi
else
    echo "[+] $PROCESS_NAME process is not running, exiting script."
    exit 1
fi

