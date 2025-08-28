#!/bin/bash
set -euo pipefail

###############################################################################
# Twingate Log & Packet Capture Collection
#
# Usage:
#   sudo ./macos_log_pcap_test.sh [DURATION] [HOST ...]
#
# Examples:
#   sudo ./macos_log_pcap_test.sh
#       -> Collect logs for 1h; test host "releases.ubuntu.com"
#   sudo ./macos_log_pcap_test.sh 30m example.com
#       -> Collect logs for 30m; test host "example.com"
#   sudo ./macos_log_pcap_test.sh 2h example.com example.org
#       -> Collect logs for 2h; test hosts "example.com" and "example.org"
#
# Notes:
#   - Duration (time window for system log collection) defaults to 1h if omitted. Accepted: 5m, 2h, 1d, etc.
#   - Hosts default to releases.ubuntu.com if none are specified. A DNS lookup and curl will be issued for each host.
#   - A packet capture begins performing DNS/curl tests and stops after the macOS system log block.
#   - All outputs are bundled into: ~/Desktop/twingate_logs_<hostname>_<datetime>.zip
###############################################################################

duration="${1:-1h}"
if [[ $# -ge 2 ]]; then
  shift
  dns_hosts=("$@")
else
  dns_hosts=("releases.ubuntu.com")
fi

host_name=$(hostname -s)
datetime=$(date +"%Y%m%d_%H%M%S")

desktop_dir="/Users/${SUDO_USER:-$USER}/Desktop"
log_dir="$desktop_dir/twingate_logs_${host_name}_${datetime}"
tg_user_log_dir="$log_dir/tg_user"
tg_system_log_dir="$log_dir/tg_system"
mkdir -p "$tg_user_log_dir" "$tg_system_log_dir"

system_log_file="$log_dir/system_out.log"
collection_log_file="$log_dir/collection.log"
zip_file="$desktop_dir/twingate_logs_${host_name}_${datetime}.zip"

pcap_file="$log_dir/twingate_pcap_${host_name}_${datetime}.pcap"

exec > >(tee -a "$collection_log_file") 2>&1
log_command_output() {
  local title="$1"
  local cmd="$2"
  echo
  echo "== $title =="
  echo "+ $cmd"
  set +e
  bash -lc "$cmd"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "(exit code: $rc)"
  fi
}

TCPDUMP_PID=""
cleanup_tcpdump() {
  if [[ -n "${TCPDUMP_PID}" ]] && kill -0 "${TCPDUMP_PID}" 2>/dev/null; then
    echo "=== Stopping packet capture (PID ${TCPDUMP_PID}) ==="
    kill "${TCPDUMP_PID}" 2>/dev/null || true
    wait "${TCPDUMP_PID}" 2>/dev/null || true
  fi
}
trap cleanup_tcpdump EXIT INT TERM

echo "==== Collecting Twingate and macOS system logs ===="
echo "Started at: $(date -Iseconds)"
echo "Output folder: $log_dir"
echo "Collecting macOS system logs for: $duration"
echo "DNS/CURL hosts: ${dns_hosts[*]}"
echo

echo "=== Starting packet capture to: $pcap_file ==="
if command -v sudo >/dev/null 2>&1; then
  sudo tcpdump -i any -s 0 -U -w "$pcap_file" &
else
  tcpdump -i any -s 0 -U -w "$pcap_file" &
fi
TCPDUMP_PID=$!
echo "tcpdump PID: $TCPDUMP_PID"

for host in "${dns_hosts[@]}"; do
  echo
  echo "=== DNS & CURL checks for: ${host} ==="
  log_command_output "Resolve DNS (dig ${host})" "dig ${host}"
  log_command_output "Resolve DNS public resolver (dig @1.1.1.1 ${host})" "dig @1.1.1.1 ${host}"

  log_command_output "curl -vvvv (HTTP) to http://${host}" \
    "curl -vvvv --connect-timeout 10 --max-time 10 -sS -o /dev/null http://${host}"

  log_command_output "curl -vvvv (HTTPS) to https://${host}" \
    "curl -vvvv --connect-timeout 10 --max-time 10 -sS -o /dev/null https://${host}"
done

user_logs=~/Library/Group\ Containers/6GX8KVTR9H.com.twingate/Logs
sys_logs=/private/var/log/twingate

echo "=== Collecting Twingate Client user logs ==="
if [ -d "$user_logs" ]; then
  cp -R "$user_logs" "$tg_user_log_dir"
  echo "Copied logs from: $user_logs"
else
  echo "No logs found at: $user_logs"
fi

echo "=== Collecting Twingate Client system logs ==="
if [ -d "$sys_logs" ]; then
  cp -R "$sys_logs" "$tg_system_log_dir"
  echo "Copied logs from: $sys_logs"
else
  echo "No logs found at: $sys_logs"
fi

echo
echo "=== Collecting system info ==="
log_command_output "Date Time" "echo $datetime && date"
log_command_output "OS install history" "softwareupdate --history"
log_command_output "Contents of /etc/hosts" "cat /etc/hosts"
log_command_output "DNS Information (scutil --dns)" "scutil --dns"
log_command_output "Network Interface Information (ifconfig)" "ifconfig"
log_command_output "Network Routing Table (netstat -rn)" "netstat -rn"
log_command_output "Network Services (networksetup)" "networksetup -listallnetworkservices"
log_command_output "Twingate version detected" "cat /Applications/Twingate.app/Contents/Info.plist | grep -A1 -i 'fullversion'"
log_command_output "Twingate installation history" "plutil -p /Library/Receipts/InstallHistory.plist | grep -B5 -A3 'com.twingate.macos'"
log_command_output "Application Details (system_profiler)" "system_profiler SPApplicationsDataType | grep -A 7 'Twingate:'"
log_command_output "Launchctl List (Twingate)" "launchctl list | grep -i twingate"
log_command_output "System Extensions (systemextensionsctl)" "systemextensionsctl list"
log_command_output "LaunchAgents and LaunchDaemons" "ls -la /Library/LaunchAgents /Library/LaunchDaemons /System/Library/LaunchAgents /System/Library/LaunchDaemons"
log_command_output "Processes running" "ps -eo pid,etime,user,command"

echo
echo "=== Collecting macOS system logs (last $duration) ==="
if log show --style syslog --last "$duration" > "$system_log_file" 2>&1; then
  echo "System logs written to: $system_log_file"
else
  echo "(log show failed; no system logs captured)"
fi
echo

cleanup_tcpdump

if [[ -s "$pcap_file" ]]; then
  echo "Packet capture saved: $pcap_file"
else
  echo "Warning: packet capture file is empty or missing: $pcap_file"
fi

echo
echo
echo "Zipping files for retrieval at: $zip_file"
(
  cd "$log_dir"
  zip -r "$zip_file" ./* >/dev/null
)

rm -rf "$log_dir"

echo
echo "Done at: $(date -Iseconds)"
echo
open "$desktop_dir"
