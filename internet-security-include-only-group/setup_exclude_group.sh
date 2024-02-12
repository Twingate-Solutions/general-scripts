#!/bin/bash

# This script will add all users to the exclude group that
# don't exist as members of the include group currently.

# Pre-requisites:
# Install jq "sudo apt install jq"
# Make sure that the Twingate Python CLI is installed and functional
# It requires "requests" and "pandas" to be installed already

# Usage: ./setup_exclude_group.sh <include_group_id> <exclude_group_id> <twingate_network_name> <api_token>
# Example: ./setup_exclude_group.sh 123456789 987654321 mynetworkname tgapitoken

# Group IDs can be copied from the URL in the Twingate Admin Console ex: https://networkname.twingate.com/groups/123456789

# Get the group_id parameters
include_group_id="$1"
exclude_group_id="$2"

# Get the Twingate network name and API token
twingate_network_name="$3"
api_token="$4"


# Call tgcli.py to get session_id
login_response=$(python3 tgcli.py auth login -t "$twingate_network_name" -a "$api_token")
echo "Login_response: $login_response"
session_id=$(echo "$login_response" | grep -oP 'Session Created: \K\S+')
echo "Session_id: $session_id"
echo ""

# Call tgcli.py to get user_id_list
include_group_response=$(python3 tgcli.py -s "$session_id" group show -i "$include_group_id")
include_user_id_list=$(echo "$include_group_response" | jq -r '.data.group.users.edges[].node.id')
echo "Count of users in the include group: $(echo "$include_user_id_list" | wc -l)"
echo "User List from include group: $include_user_id_list"
echo ""

# Call tgcli.py to get full_user_id_list
full_user_list_response=$(python3 tgcli.py -s "$session_id" -f CSV user list)
full_user_id_list=$(echo "$full_user_list_response" | cut -d',' -f1)
full_user_id_list=$(echo "$full_user_id_list" | sed '1d')
echo "Count of users in full_user_id_list: $(echo "$full_user_id_list" | wc -l)"

# Loop through full_user_id_list and check to see if each user_id is in include_user_id_list, if not then add it to exclude_user_id_list as a CSV
for user_id in $full_user_id_list; do
    if [[ ! "$include_user_id_list" =~ "$user_id" ]]; then
        exclude_user_id_list="$exclude_user_id_list,$user_id"
    fi
done
exclude_user_id_list=$(echo "$exclude_user_id_list" | sed 's/^,//')
echo "Count of users to add to the exclude group: $(echo "$exclude_user_id_list" | wc -l)"
echo ""
echo "Executing update of exclude group"
echo ""
echo ""

# Call tgcli.py to add all users in exclude_user_id_list to the exclude_group_id
python3 tgcli.py -s "$session_id" group addUsers -g "$exclude_group_id" -u "$exclude_user_id_list"