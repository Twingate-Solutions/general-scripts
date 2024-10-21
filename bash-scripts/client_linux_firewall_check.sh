#!/bin/bash
command_exists() { command -v "$1" > /dev/null 2>&1; }

check_firewalls() {
    printf "\nFirewall states\n---\n"
    
    if command_exists iptables; then
        rules_count=$(sudo iptables -n --list --line-numbers 2>/dev/null | grep -c '^[0-9]')
        printf "iptables - %s\n" "$( [ "$rules_count" -gt 0 ] && printf 'active (rules found)' || printf 'inactive (no rules found)')"
    else
        printf "iptables - not detected\n"
    fi
    
    if command_exists ufw; then
        status=$(sudo ufw status | grep -o 'Status: .*' | awk '{print $2}')
        printf "ufw - %s\n" "$( [ "$status" == "active" ] && printf 'active' || printf 'inactive' )"
    else
        printf "ufw - not detected\n"
    fi

    if command_exists firewall-cmd; then
        status=$(sudo firewall-cmd --state 2>/dev/null)
        if [ "$status" == "running" ]; then
            printf "firewalld - active\n"
        else
            printf "firewalld - inactive\n"
        fi
    else
        printf "firewalld - not detected\n"
    fi
}

check_firewalls
