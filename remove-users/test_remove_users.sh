#!/bin/bash

# This script removes all users from a group
# It needs to be run inside of the same folder that
# tgcli.py is in, and it needs to be run with the
# group_id as the first parameter

#Usage: ./remove_users.sh <group_id> <network_name> <api_token>

# Pre-requisites:
# Install jq "sudo apt install jq"
# Make sure that the Twingate Python CLI is installed and functional
# It requires requests and pandas to be installed already

# Make sure to replace '<network_name>' with your TG network name and
# '<api_token>' with your TG API token that has read/write access

# Get the group_id parameter
group_id="$1"
network_name="$2"
api_token="$3"

#Call tgcli.py to get session_id
login_response=$(python3 tgcli.py auth login -t "$network_name" -a "$api_token")
session_id=$(echo "$login_response" | grep -oP 'Session Created: \K\S+')

#Call tgcli.py to get user_id_list
group_response=$(python3 tgcli.py -s "$session_id" group show -i "$group_id")
user_id_list=$(echo "$group_response" | jq -r '.data.group.users.edges[].node.id')

#Loop through user_id_list and remove users, this probably should just pass them all in as a CSV instead
for user_id in $user_id_list; do
    python3 tgcli.py -s "$session_id" group removeUsers -g "$group_id" -u "$user_id"
    echo "user_id: $user_id removed"
done