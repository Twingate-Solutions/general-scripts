# Headless Client Gateway
The purpose of this script is to help automate the setup of a whole network Internet Gateway, utilizing the Twingate Headless Client.  This type of setup would be useful in a situation where there's a number of IoT devices that cannot have the traditional Client installed, and need to use either a proxy or a simple gateway in order to access remote Resources.

The resulting system that this script will configure can be used as the gateway and DNS server for such devices, and by running the Headless Client on it those devices will be able to access both general Internet sites as well as Twingate protected Resources.

# Setup
The script will install and configure a number of services on the machine:
- Twingate Headless Client ()
- Bind9 (for providing DNS resolution)
- iptables (for NAT forwarding)

Prior to running the script you will need to log in to the Twingate Admin Console for your network, and create a Service Account.  You can find the page to do this under the Teams section, and the Services tab.  Create the Service Account, and then generate a new Service Key with whatever expiration period you want.  When the screen comes up with the JSON for the key, copy it to notepad and save it.

In a fresh install of Ubuntu or another Debian based Linux distro (for now, some support for RHEL and others will come) create a `servicekey.json` file in a working folder, and paste the JSON for the service key in to it.

Also make sure that this system is set up with a static IP and has access to the Internet currently.

# Usage
In the working folder, run the following command to pull down the script:
`curl https://raw.githubusercontent.com/Twingate-Solutions/general-scripts/main/twingate-headless-client-gateway/twingate-headless-client-gateway.sh -o gateway_config.sh`

When you run the script, you'll need to provide two parameters:
- Path to the servicekey.json you saved
- Your network's subnet range in CIDR format, ie 10.0.0.0/24 or 192.168.1.0/24

To run the script simply execute with the two parameters:
`sudo bash ./gateway_config.sh ./servicekey.json 10.0.0.0/24`

If there's an error or issue with the parameters the script will output it, otherwise it should run through a set of steps:
1. `apt update` and `apt upgrade`
2. Installing bind9, Twingate Headless Client, and `iptables-persistent`
3. Configuring the Twingate Headless Client to use the servicekey.json and starting it
4. Configuring bind9 as a DNS server and pointing it at the four Twingate Client based DNS resolvers
5. Creating an iptables rule to forward all incoming traffic through `sdwan0` which is the Twingate Client interface
6. Saving that rule so that it persists beyond future reboots

# Testing

Since the goal of this is to allow devices on a network to use this machine as a sort of gateway to access both the Internet and private Resources hosted in other networks, you'll want to test both.

You'll need to add a few Resources to the Service Account, something hosted in a remote network so you can verify that you can get to them through the gateway.

Once you have Resources added, do some pings from the gateway machine itself, ensure that they go through.

Then go to a different machine on the network and update its network settings so that both the gateway and DNS server are pointing at this machine's IP address.  You should be able to access the Resources on that machine, as well as public Internet sites like Google or Microsoft or Twingate.com.
