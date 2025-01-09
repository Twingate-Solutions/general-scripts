#!/bin/bash

datetime=$(date +"%Y%m%d_%H%M%S")
log_dir=~/Desktop/twingate_logs_$datetime
user_log_dir="$log_dir/user_logs"
system_log_dir="$log_dir/system_logs"
mkdir -p "$user_log_dir" "$system_log_dir"
log_file="$log_dir/system-info.log"

exec > >(tee -a "$log_file") 2>&1

user_logs=~/Library/Group\ Containers/6GX8KVTR9H.com.twingate/Logs
sys_logs=/private/var/log/twingate

if [ -d "$user_logs" ]; then
    cp -R "$user_logs" "$user_log_dir"
    echo "Copied logs from $user_logs to $user_log_dir"
else
    echo "No logs found in $user_logs"
fi

if [ -d "$sys_logs" ]; then
    cp -R "$sys_logs" "$system_log_dir"
    echo "Copied logs from $sys_logs to $system_log_dir"
else
    echo "No logs found in $sys_logs"
fi

log_command_output() {
    echo -e "\n### $1 ###"
    eval "$2"
}

log_command_output 'Twingate version detected' "cat '/Applications/Twingate.app/Contents/Info.plist' | grep -A1 -i 'fullversion'"
log_command_output 'Twingate installation history' 
log_command_output 'Twingate processes' "ps aux | grep -i '[t]wingate'"
log_command_output 'Launchctl List (Twingate)' "launchctl list | grep -i twingate"
log_command_output 'List Open Files and Network Connections (lsof)' "lsof -c Twingate"
log_command_output 'Network Services (networksetup)' "networksetup -listallnetworkservices"
log_command_output 'Application Details (system_profiler)' "system_profiler SPApplicationsDataType | grep -A 10 -i twingate | head -n 20"
log_command_output 'System Extensions (systemextensionsctl)' "systemextensionsctl list"
log_command_output 'Contents of /etc/hosts' "cat /etc/hosts"
log_command_output 'Network Interface Information (ifconfig)' "ifconfig"
log_command_output 'Network Routing Table (netstat -rn)' "netstat -rn"
log_command_output 'LaunchAgents and LaunchDaemons' "ls -la /Library/LaunchAgents /Library/LaunchDaemons /System/Library/LaunchAgents /System/Library/LaunchDaemons"
log_command_output 'DNS Information (scutil --dns)' "scutil --dns"
log_command_output 'Processes running' "ps -eo pid,etime,user,command"

zip_file=~/Desktop/twingate_logs_$datetime.zip
cd "$log_dir"
zip -r "$zip_file" ./*
echo "Zipped logs saved to $zip_file"

cd ~
rm -rf "$log_dir"
echo "Temporary log directory removed"
open ~/Desktop
