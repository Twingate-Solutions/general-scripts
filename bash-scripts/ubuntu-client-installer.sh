#!/bin/bash

# Set local variables
dns_servers="1.2.3.4 5.6.7.8" #set your DNS servers here, space separated
dns_search_domain="company.internal" #set your search domains/suffixes here

ubuntu_version=$(lsb_release -rs)
echo "Ubuntu Version: $ubuntu_version"

# Try to figure out systemd-resolved vs NetworkManager
active_manager=""
if systemctl is-active --quiet NetworkManager; then
    active_manager="NetworkManager"
elif systemctl is-active --quiet systemd-networkd; then
    active_manager="systemd-networkd"
else
    active_manager="Unknown" # If neither in use then bail out later, can't do ifupdown yet
fi

echo "Active Network Manager: $active_manager"

# Function to configure the DNS settings 
configure_dns() {
    case $active_manager in
    "systemd-networkd")
        if systemctl is-active --quiet systemd-resolved; then # Let's assume systemd-resolved is in use
            echo "systemd-resolved is running"
            resolved_config="/etc/systemd/resolved.conf"
            if [ -f "$resolved_config" ]; then
                echo "Updating systemd-resolved configuration..."
                sed -i '/^DNS=/d' "$resolved_config"
                sed -i '/^Domains=/d' "$resolved_config"
                echo -e "DNS=$dns_servers\nDomains=$dns_search_domain\nDNSStubListener=no\nResolveUnicastSingleLabel=yes" >> "$resolved_config"
                systemctl restart systemd-resolved
                echo "systemd-resolved configuration updated and service restarted."
            else
                echo "systemd-resolved configuration file not found!"
                exit 1
            fi
        fi
        ;;
    "NetworkManager")
        # Just in case there's several connections let's update all of them
        nmcli con show | tail -n +2 | awk '{print $1}' | while read -r connection; do
            echo "Updating DNS for NetworkManager connection: $connection"
            nmcli con mod "$connection" ipv4.dns "$dns_servers" ipv4.dns-search "$dns_search_domain"
            nmcli con down "$connection" && nmcli con up "$connection"
        done
        ;;
    *)
        echo "Unsupported network manager: $active_manager"
        exit 1
        ;;
    esac
}

configure_dns

# Install the Twingate client now
curl -s https://binaries.twingate.com/client/linux/install.sh | sudo bash
