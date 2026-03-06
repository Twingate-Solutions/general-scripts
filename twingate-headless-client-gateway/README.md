# Headless Client Gateway

The purpose of this script is to help automate the setup of a whole network Internet Gateway, utilizing the Twingate [Headless Client](https://www.twingate.com/docs/services). This type of setup would be useful in a situation where there's a number of IoT devices that cannot have the traditional Client installed, and need to use either a proxy or a simple gateway in order to access remote Resources.

The resulting system that this script will configure can be used as the gateway and DNS server for such devices, and by running the Headless Client on it those devices will be able to access both general Internet sites as well as Twingate protected Resources.

## Script Versions

There are two versions of this script in this folder. The end result of both is identical — a Linux machine configured as a Twingate-aware network gateway — but they differ in how they get there.

**`twingate-headless-client-gateway.sh` (v1)**
The original script. Supports Ubuntu and basic Fedora installs. Straightforward but minimal error handling, no logging, and limited distro coverage.

**`twingate-headless-client-gateway-v2.sh` (v2 — recommended)**
A full rewrite with broader distro support, proper error handling, and structured logging. Key improvements over v1:

- Supports Ubuntu 22.04/24.04, Debian 13, Fedora, and CentOS Stream 9
- All output logged to `/var/log/twingate-gateway-setup.log` with timestamps
- Script aborts immediately on any failure and reports the exact line number
- Subnet parameter is now optional (defaults to `0.0.0.0/0`)
- Handles re-runs safely — skips steps that are already complete rather than failing
- Automatically resolves `systemctl enable` issues with alias unit names (e.g. `bind9` on Ubuntu)
- Disables `systemd-resolved` stub listener on Ubuntu/Debian to avoid port 53 conflicts

## Supported Systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 13
- Fedora (current)
- CentOS Stream 9

## Setup

The script will install and configure a number of services on the machine:

- [Twingate Headless Client](https://www.twingate.com/docs/services) (for accessing protected Resources)
- Bind9 / named (for providing DNS resolution)
- iptables (for NAT forwarding)

Prior to running the script you will need to log in to the Twingate Admin Console for your network, and create a Service Account. You can find the page to do this under the Teams section, and the Services tab. Create the Service Account, and then generate a new Service Key with whatever expiration period you want. When the screen comes up with the JSON for the key, copy it to notepad and save it.

On a fresh install of one of the supported Linux distributions above, create a `servicekey.json` file in a working folder, and paste the JSON for the service key in to it.

Also make sure that this system is set up with a static IP and has access to the Internet currently.

## Usage

In the working folder, run the following command to pull down the script:

`curl https://raw.githubusercontent.com/Twingate-Solutions/general-scripts/main/twingate-headless-client-gateway/twingate-headless-client-gateway-v2.sh -o gateway_config.sh`

When you run the script, you'll need to provide the following parameters:

- **Path to the servicekey.json you saved** (required)
- **Your network's subnet range in CIDR format** (optional — defaults to `0.0.0.0/0` to NAT all traffic)

To run the script simply execute with the parameters:

`sudo bash ./gateway_config.sh ./servicekey.json`

Or with a specific subnet:

`sudo bash ./gateway_config.sh ./servicekey.json 10.0.0.0/24`

If there's an error or issue with the parameters the script will output it, otherwise it should run through a set of steps:

1. Detect the Linux distribution and select the appropriate packages and config paths
2. `apt update` / `dnf update` and install bind9/named, iptables, and curl
3. Install and configure the Twingate Headless Client with the servicekey.json
4. Enable IPv4 forwarding
5. Configure bind9/named as a DNS server pointing at the four Twingate Client resolvers
6. Create an iptables rule to NAT traffic through `sdwan0` (the Twingate Client interface)
7. Save iptables rules to persist beyond reboots

## Testing

Once the script completes, test in this order — first on the gateway machine itself, then from a client device.

### On the gateway machine

**Check all services are running:**

```bash
twingate status
systemctl status twingate
systemctl status named       # Fedora/CentOS
systemctl status bind9       # Ubuntu/Debian
```

**Confirm DNS is listening on the right interfaces:**

```bash
ss -tulnp | grep :53
```

You should see named/bind9 listening on both `127.0.0.1:53` and your LAN IP. If it's only on `127.0.0.1`, the bind config didn't apply correctly.

**Test DNS resolution locally:**

```bash
# General internet
dig @127.0.0.1 google.com

# A Twingate resource (replace with a hostname from your network)
dig @127.0.0.1 your-resource.your-network.twingate.com
```

**Confirm the Twingate interface is up:**

```bash
ip link show sdwan0
ip addr show sdwan0
```

**Confirm IPv4 forwarding is active:**

```bash
cat /proc/sys/net/ipv4/ip_forward
```

Should return `1`. If it returns `0`, run `sudo sysctl -w net.ipv4.ip_forward=1` and check `/etc/sysctl.conf`.

**Check the iptables NAT rule is in place:**

```bash
sudo iptables -t nat -L POSTROUTING -v -n
```

Should show a MASQUERADE rule for your subnet on `sdwan0`.

### From a client device

Point the client's gateway and DNS server at the gateway machine's IP, then:

```bash
# DNS lookups should work
nslookup google.com <gateway-ip>
nslookup your-resource.your-network.twingate.com <gateway-ip>

# Internet reachability by IP (no DNS involved)
ping -c 3 8.8.8.8

# Internet reachability by name
ping -c 3 google.com

# Try loading an actual site
curl -s --max-time 10 https://example.com | head -5
```

If ping works but HTTPS sites load slowly or fail, see the MTU note in the Troubleshooting section below.

## Troubleshooting

### Script failed mid-run

Check the log file — it includes timestamps and the exact line number where the failure occurred:

```bash
cat /var/log/twingate-gateway-setup.log
```

The script is designed to be re-run safely after fixing the underlying issue. Steps that are already complete (Twingate installed, iptables rule exists, etc.) will be detected and skipped.

### DNS queries refused

If clients get `REFUSED` responses when querying the gateway:

The bind config uses an ACL to restrict which source IPs are allowed to query. If you ran the script with a specific subnet (e.g. `10.0.0.0/24`) and your clients are on a different subnet, they'll be refused.

Check the current ACL in the bind config:

```bash
cat /etc/bind/named.conf.options   # Ubuntu/Debian
cat /etc/named.conf                # Fedora/CentOS
```

To allow all clients, replace the subnet in the ACL with `any`:

```bash
# Ubuntu/Debian
sudo sed -i 's|<your-subnet>|any|g' /etc/bind/named.conf.options
sudo systemctl restart bind9

# Fedora/CentOS
sudo sed -i 's|<your-subnet>|any|g' /etc/named.conf
sudo systemctl restart named
```

Using `any` in the ACL is safe here because bind9 is already limited to listening only on specific interfaces via `listen-on`, so it is not reachable from the internet.

### Port 53 conflict on Ubuntu/Debian

On Ubuntu/Debian, `systemd-resolved` runs a stub listener on `127.0.0.53:53` by default. The script disables this automatically, but if bind9 still fails to start:

```bash
ss -tulnp | grep :53
```

If `systemd-resolved` appears on your LAN IP (not just `127.0.0.53`), the stub was not fully disabled. Check and fix:

```bash
grep DNSStubListener /etc/systemd/resolved.conf
# Should show: DNSStubListener=no
# If missing or set to yes:
echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo systemctl restart bind9
```

### Twingate client won't install

If the Twingate installer fails with `gpg: dearmoring failed: File exists`, there are leftover files from a previous failed install attempt. Clean them up and re-run:

```bash
sudo rm -f /etc/apt/trusted.gpg.d/twingate*.gpg
sudo rm -f /usr/share/keyrings/twingate*.gpg
sudo rm -f /etc/apt/sources.list.d/twingate*.list
```

Then re-run the script. The v2 script does this cleanup automatically before each install attempt.

### Twingate service key issues

If `twingate setup --headless` fails, verify:

- The JSON file is present and readable: `cat ./servicekey.json`
- The key has not expired in the Twingate Admin Console (Teams → Services → your service account)
- The machine has internet access: `curl -s https://www.twingate.com`

### iptables NAT rule missing

If Twingate resources are unreachable but DNS resolves correctly, check the NAT rule:

```bash
sudo iptables -t nat -L POSTROUTING -v -n
```

If the MASQUERADE rule for `sdwan0` is missing, add it manually (replace `0.0.0.0/0` with your subnet if you used one):

```bash
sudo iptables -t nat -A POSTROUTING -s 0.0.0.0/0 -o sdwan0 -j MASQUERADE
sudo iptables-save > /etc/iptables/rules.v4   # Ubuntu/Debian
sudo iptables-save > /etc/sysconfig/iptables  # Fedora/CentOS
```

### Pings work but HTTPS sites are slow or fail

This is typically an MTU/MSS issue. When packets travel through the Twingate tunnel (`sdwan0`), the tunnel adds overhead that reduces the effective MTU. TCP connections that negotiate a segment size larger than the tunnel can carry will stall.

Test with a small explicit MTU first to confirm:

```bash
ping -c 3 -M do -s 1400 8.8.8.8   # Should succeed
ping -c 3 -M do -s 1472 8.8.8.8   # May fail if MTU is the issue
```

If the larger size fails, add an MSS clamping rule:

```bash
sudo iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
sudo iptables-save > /etc/iptables/rules.v4   # Ubuntu/Debian
sudo iptables-save > /etc/sysconfig/iptables  # Fedora/CentOS
```

### General internet traffic not forwarding

If Twingate resources work but regular internet traffic doesn't reach the upstream router:

```bash
# Confirm forwarding is on
cat /proc/sys/net/ipv4/ip_forward   # Should be 1

# Check the FORWARD chain policy
sudo iptables -L FORWARD -v -n
```

If the FORWARD policy is `DROP`, set it to `ACCEPT`:

```bash
sudo iptables -P FORWARD ACCEPT
sudo iptables-save > /etc/iptables/rules.v4
```

If the policy is already `ACCEPT` and traffic still isn't flowing, confirm the upstream router is configured to accept forwarded packets from this machine's IP and that there is a valid default route:

```bash
ip route show default
```
