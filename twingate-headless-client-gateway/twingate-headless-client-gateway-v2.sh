#!/bin/bash
# twingate-headless-client-gateway-v2.sh
#
# Configures a Linux machine as a Twingate Internet gateway for a local network.
# Installs and configures: Twingate headless client, bind9/named (DNS), iptables (NAT)
#
# Supported distros: Ubuntu 22.04/24.04, Debian 13, Fedora (current), CentOS Stream 9
# Must be run as root or with sudo.
#
# Usage: sudo ./twingate-headless-client-gateway-v2.sh /path/to/servicekey.json [subnet]
#   /path/to/servicekey.json   Twingate service key file (required)
#   subnet                     Local network subnet in CIDR format (optional, default: 0.0.0.0/0)
#
# Example:
#   sudo ./twingate-headless-client-gateway-v2.sh ./servicekey.json 10.0.0.0/24

set -euo pipefail

LOG_FILE="/var/log/twingate-gateway-setup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# systemctl enable refuses to operate on alias/linked unit files (e.g. bind9 on Ubuntu).
# This helper resolves the canonical unit name via systemctl show before enabling.
systemctl_enable() {
  local service="$1"
  local canonical
  canonical=$(systemctl show -p Id --value "$service" 2>/dev/null | sed 's/\.service$//')
  if [[ -n "$canonical" && "$canonical" != "$service" ]]; then
    log "Note: $service is an alias for $canonical, enabling $canonical instead"
    systemctl enable "$canonical"
  else
    systemctl enable "$service"
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: sudo ./twingate-headless-client-gateway-v2.sh /path/to/servicekey.json [subnet]"
  echo ""
  echo "  /path/to/servicekey.json   Twingate service key file (required)"
  echo "  subnet                     Local network subnet in CIDR (optional, default: 0.0.0.0/0)"
  echo ""
  echo "Example:"
  echo "  sudo ./twingate-headless-client-gateway-v2.sh ./servicekey.json 10.0.0.0/24"
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  log "ERROR: This script must be run as root or with sudo."
  exit 1
fi

# Redirect all stdout and stderr to log file and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

log "=== Twingate Gateway Setup Starting ==="

trap 'log "ERROR: Setup failed at line $LINENO. Check $LOG_FILE for details."' ERR

if [[ -z "${1:-}" ]]; then
  log "ERROR: Twingate service key file path is required as the first argument."
  exit 1
fi

if [[ ! -f "$1" ]]; then
  log "ERROR: Service key file not found: $1"
  exit 1
fi

TWINGATE_SERVICE_KEY_FILE="$1"
log "Service key file: $TWINGATE_SERVICE_KEY_FILE"

LOCAL_NETWORK_SUBNET="${2:-0.0.0.0/0}"

if [[ -n "${2:-}" ]]; then
  if ! echo "$2" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
    log "ERROR: Invalid subnet format: $2. Expected format: x.x.x.x/xx"
    exit 1
  fi
fi

log "Local network subnet: $LOCAL_NETWORK_SUBNET"

MAIN_NETWORK_INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')

if [[ -z "$MAIN_NETWORK_INTERFACE" ]]; then
  log "ERROR: Could not determine main network interface. Is a default route configured?"
  exit 1
fi

MAIN_NETWORK_INTERFACE_IP=$(ip -4 addr show "$MAIN_NETWORK_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

if [[ -z "$MAIN_NETWORK_INTERFACE_IP" ]]; then
  log "ERROR: Could not determine main network interface IP address."
  exit 1
fi

log "Main network interface: $MAIN_NETWORK_INTERFACE ($MAIN_NETWORK_INTERFACE_IP)"

log "=== Detecting Linux distribution ==="

if [[ ! -f /etc/os-release ]]; then
  log "ERROR: /etc/os-release not found. Cannot determine distro."
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release

DISTRO_ID="${ID:-unknown}"
DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
NEEDS_RESOLVED_STUB_DISABLE=false

case "$DISTRO_ID" in
  ubuntu|debian)
    PKG_MANAGER="apt-get"
    BIND_PKG="bind9"
    BIND_CONF_FILE="/etc/bind/named.conf.options"
    BIND_CONF_DIR="/var/cache/bind"
    BIND_SERVICE="bind9"
    NAMED_OPTIONS_FILE="/etc/default/named"
    NAMED_OPTIONS_SETTING='OPTIONS="-u bind -4"'
    IPTABLES_SAVE_FILE="/etc/iptables/rules.v4"
    IPTABLES_SERVICE="netfilter-persistent"
    NEEDS_RESOLVED_STUB_DISABLE=true
    ;;
  fedora|centos)
    PKG_MANAGER="dnf"
    BIND_PKG="bind"
    BIND_CONF_FILE="/etc/named.conf"
    BIND_CONF_DIR="/var/named"
    BIND_SERVICE="named"
    NAMED_OPTIONS_FILE="/etc/sysconfig/named"
    NAMED_OPTIONS_SETTING='OPTIONS="-4"'
    IPTABLES_SAVE_FILE="/etc/sysconfig/iptables"
    IPTABLES_SERVICE="iptables"
    ;;
  *)
    log "ERROR: Unsupported distribution: $DISTRO_ID $DISTRO_VERSION_ID"
    log "Supported: Ubuntu 22.04/24.04, Debian 13, Fedora, CentOS Stream 9"
    exit 1
    ;;
esac

log "Detected distro: $DISTRO_ID $DISTRO_VERSION_ID (pkg manager: $PKG_MANAGER)"

log "=== Installing packages ==="

if [[ "$PKG_MANAGER" == "dnf" ]]; then
  dnf -y update
  dnf install -y "$BIND_PKG" curl

  log "Disabling firewalld in favor of iptables..."
  systemctl stop firewalld || true
  systemctl disable firewalld || true
  dnf remove -y firewalld

  dnf install -y iptables-services
  systemctl enable iptables
  systemctl start iptables
else
  apt-get -y update
  apt-get install -y debconf-utils
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$BIND_PKG" iptables iptables-persistent curl iproute2 procps
fi

log "Package installation complete."

log "=== Installing Twingate client ==="
if command -v twingate &>/dev/null; then
  log "Twingate client already installed, skipping download"
else
  # Remove any partial artifacts from a previous failed install attempt
  # (the installer fails if the GPG key file already exists)
  rm -f /etc/apt/trusted.gpg.d/twingate*.gpg
  rm -f /usr/share/keyrings/twingate*.gpg
  rm -f /etc/apt/sources.list.d/twingate*.list
  curl -s https://binaries.twingate.com/client/linux/install.sh | bash
fi

log "Configuring Twingate headless client..."
twingate setup --headless "$TWINGATE_SERVICE_KEY_FILE"

log "Starting Twingate client..."
systemctl_enable twingate
twingate start

log "Twingate client setup complete."

log "=== Enabling IPv4 forwarding ==="

sysctl -w net.ipv4.ip_forward=1

SYSCTL_CONF="/etc/sysctl.d/99-twingate-gateway.conf"
if ! grep -q "^net.ipv4.ip_forward=1" "$SYSCTL_CONF" 2>/dev/null; then
  echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"
  log "Wrote net.ipv4.ip_forward=1 to $SYSCTL_CONF"
else
  log "net.ipv4.ip_forward=1 already present in $SYSCTL_CONF"
fi

sysctl -p "$SYSCTL_CONF"

log "IPv4 forwarding enabled."

# Disable systemd-resolved stub listener on Ubuntu/Debian to free port 53 for bind9
if [[ "$NEEDS_RESOLVED_STUB_DISABLE" == "true" ]]; then
  log "=== Disabling systemd-resolved stub listener (frees port 53 for bind9) ==="

  RESOLVED_CONF="/etc/systemd/resolved.conf"

  if grep -q "^DNSStubListener=" "$RESOLVED_CONF" 2>/dev/null; then
    sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"
  else
    echo "DNSStubListener=no" >> "$RESOLVED_CONF"
  fi

  if systemctl cat systemd-resolved.service &>/dev/null; then
    systemctl restart systemd-resolved
    log "systemd-resolved stub listener disabled."
  else
    log "systemd-resolved not installed, no stub listener to disable — skipping."
  fi
fi

log "=== Configuring DNS ($BIND_SERVICE) ==="

cat > "$BIND_CONF_FILE" <<EOF
acl LAN {
  ${LOCAL_NETWORK_SUBNET};
};
options {
        directory "${BIND_CONF_DIR}";
        allow-query { localhost; LAN; };
        recursion yes;
        forwarders {
                100.95.0.251;
                100.95.0.252;
                100.95.0.253;
                100.95.0.254;
        };
        dnssec-validation no;
        listen-on port 53 { 127.0.0.1; ${MAIN_NETWORK_INTERFACE_IP}; };
};
EOF

log "Wrote DNS config to $BIND_CONF_FILE"

# Write IPv4-only option (full replace, not sed)
echo "$NAMED_OPTIONS_SETTING" > "$NAMED_OPTIONS_FILE"
log "Set IPv4-only mode in $NAMED_OPTIONS_FILE"

systemctl restart "$BIND_SERVICE"
systemctl_enable "$BIND_SERVICE"

log "DNS configuration complete."

log "=== Configuring iptables NAT ==="

# MASQUERADE traffic leaving via the Twingate interface.
# Twingate automatically adds kernel routes for resource CIDRs via sdwan0,
# so only resource-bound traffic hits this rule. All other traffic follows
# the default route to the upstream gateway unchanged — ip_forward=1 is
# sufficient for that path; no additional MASQUERADE rule is needed.
if ! iptables -t nat -C POSTROUTING -s "$LOCAL_NETWORK_SUBNET" -o sdwan0 -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "$LOCAL_NETWORK_SUBNET" -o sdwan0 -j MASQUERADE
else
  log "iptables MASQUERADE rule for sdwan0 already exists, skipping"
fi

iptables-save > "$IPTABLES_SAVE_FILE"
log "iptables rules saved to $IPTABLES_SAVE_FILE"

systemctl_enable "$IPTABLES_SERVICE"
systemctl restart "$IPTABLES_SERVICE"

log "iptables NAT configuration complete."

log "=== Twingate Gateway Setup Complete ==="
log "Log file saved to: $LOG_FILE"
log ""
log "Next steps:"
log "  1. Add Resources to the Twingate Service Account in the Admin Console"
log "  2. Test DNS resolution from this machine: dig @${MAIN_NETWORK_INTERFACE_IP} <resource-hostname>"
log "  3. Point client devices to this machine (${MAIN_NETWORK_INTERFACE_IP}) as their gateway and DNS server"
