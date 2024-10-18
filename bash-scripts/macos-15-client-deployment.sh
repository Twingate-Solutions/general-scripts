#!/bin/bash

# This script is designed to install or update the Twingate MacOS client application.

# Note: This script is provided as-is, and is intended to be used as a starting point for your own deployment scripts.
# It is meant to be run on MacOS 15 Sequoia, and may require modification to work in your environment.  
# It is recommended to test this script in a lab environment before deploying to production machines.

# THe script has a couple of optional features:
# - Uninstall Twingate client before reinstalling
# - Set machine key configuration for always-on connectivity
# - Create a LaunchDaemon to auto-restart the Twingate client

# By default the script will always check to see if the Twingate client application is running, and kill it.

###################################
##  Configure Optional Features  ##
###################################

# To uninstall the client app before re-installing, set to true.  This can be useful if you want to ensure a clean install.
# This will also trigger the initial "Join Network" dialog to appear, unless you also include a machinekey.conf in which case
# the client will automatically join the network and the dialog will be suppressed. 
uninstallFirst=false

# A machine key is used to enforce "always on" for the client, and is typically used for Twingate Internet Security.  It will
# remote the ability for the user to log out or quit the client application.  This is optional, and should only be used if you
# are sure you want to enforce always-on connectivity.  If you are unsure, please reach out to Twingate support for guidance.

# To create a machinekey.conf file, set createMachineKey to true, and paste the contents of the file in the machineKey variable.
# The machinekey.conf contents are found in your Twingate Admin Console, under the Internet Security section.
# When you go to Client Configuration you can create a new machine key, and copy the contents to paste in the variable below.
# Ex:
# machineKeyContent = '{
#   "version": "2",
#   "network": "test.twingate.com",
#   "private_key": "-----BEGIN PRIVATE KEY-----\PRIVATEKEYGOESHERE\n-----END PRIVATE KEY-----",
#   "id": "IDGOESHERE"
# }'
#
# Make sure to paste the contents of the machinekey.conf file replacing `machinekey`, such that it matches the format above.
createMachineKey=false
machineKeyTargetFolder="/Library/Application Support/Twingate"
machineKeyContent='
machinekey 
'

# If you want to check that the Twingate client app is running and if not then start it
# then set the flag below to true.  This will create a LaunchDaemon that will check every 5 minutes
# if the Twingate client is running, and if not it will start it.
autoRestartTwingate=false

# Set variables for Twingate installation and configuration
twingateNetworkName="networkname" # Replace with your Twingate network name, e.g. if you log in to "companyabc.twingate.com" then it would be "companyabc"
twingateClientPath="/Applications/Twingate.app"
twingateServiceName="com.twingate.client"

# URL for downloading the Twingate Client
twingateInstallerURL="https://api.twingate.com/download/darwin?installer=pkg"

###################################
##         Functions             ##
###################################

# Function to check if Twingate is running and kill it
check_and_kill_twingate() {
  echo "[+] Checking for existing Twingate install"
  if pgrep "Twingate" > /dev/null; then
    echo "[+] Twingate is running, stopping..."
    pkill "Twingate"
  fi
}

# Function to uninstall Twingate if necessary
uninstall_twingate() {
  if $uninstallFirst; then
    echo "[+] Uninstalling Twingate client..."
    # check for the plist for the service restart and unload it
    if [ -f "/Library/LaunchDaemons/com.twingate.restart.plist" ]; then
      sudo launchctl unload "/Library/LaunchDaemons/com.twingate.restart.plist"
      sudo rm -f "/Library/LaunchDaemons/com.twingate.restart.plist"
      echo "[+] LaunchDaemon removed"
    fi    
    rm -rf "$twingateClientPath"
  fi
}

# Function to install Twingate
install_twingate() {
  echo "[+] Downloading Twingate Client..."
  curl -L -o /tmp/TwingateInstaller.pkg "$twingateInstallerURL"
  
  echo "[+] Installing Twingate Client..."
  sudo installer -pkg /tmp/TwingateInstaller.pkg -target /

  # Create a plist file to configure the Twingate client
  sudo tee "/Library/Preferences/com.twingate.macos.plist" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>startAtLogin</key>
    <true/>
    <key>network</key>
    <string>$twingateNetworkName</string> <!-- Use the network name from the main script settings -->
    <key>SUEnableAutomaticChecks</key> <!-- Disable automatic updates -->
    <false/>
</dict>
</plist>
EOF

  echo "[+] Twingate Client installed"
}

# Function to create machinekey.conf if enabled
create_machinekey() {
  if $createMachineKey; then
    echo "[+] Creating machinekey.conf..."
    if [ ! -d "$machineKeyTargetFolder" ]; then
      sudo mkdir -p "$machineKeyTargetFolder"
    fi
    echo "$machineKeyContent" | sudo tee "$machineKeyTargetFolder/machinekey.conf" > /dev/null
    echo "[+] machinekey.conf created at $machineKeyTargetFolder"
  fi
}

# Function to create a MacOS LaunchDaemon to auto-restart Twingate only if it's not running
create_launch_daemon() {
    if ! $autoRestartTwingate; then
        echo "[+] Auto-restart disabled, skipping..."
        return
    fi

    # Check to see if both the launch daemon and script already exist
    if [ -f "/Library/LaunchDaemons/com.twingate.restart.plist" ] -a [ -f "/usr/local/bin/start_twingate.sh" ] ; then
        echo "[+] LaunchDaemon and start script already exist, skipping..."
        return
    fi

    local script="/usr/local/bin/start_twingate.sh"
    local plist="/Library/LaunchDaemons/com.twingate.start.plist"

    # Create a script to start Twingate if it's not running
    echo "[+] Creating script to start Twingate client..."
    sudo tee "$script" > /dev/null <<EOF
    #!/bin/bash
    if ! pgrep "Twingate" > /dev/null; then
        open twingateClientPath
    fi
EOF

    sudo chmod +x "$script"
    echo "[+] Start script created"

    # Create a LaunchDaemon to run the script
    echo "[+] Creating LaunchDaemon to check if Twingate is running..."
    sudo tee "$plist" > /dev/null <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.twingate.start</string>

        <key>ProgramArguments</key>
        <array>
            <string>/bin/bash</string>
            <string>/usr/local/bin/start_twingate.sh</string>
        </array>

        <key>RunAtLoad</key>
        <true/>

        <key>StartInterval</key>
        <integer>300</integer><!-- Check every 5 minutes -->
    </dict>
    </plist>
EOF

    sudo launchctl load -w "$plist"
    echo "[+] LaunchDaemon created and loaded"
    }

###################################
##         Main Script           ##
###################################

# Check if Twingate is running and stop it
check_and_kill_twingate

# Uninstall Twingate if uninstallFirst is true
uninstall_twingate

# Install the Twingate Client
install_twingate

# Create the machinekey.conf if enabled
create_machinekey

# Create a LaunchDaemon to auto-restart the Twingate client if needed
create_launch_daemon

echo "[+] Twingate Client installation and configuration complete!"
