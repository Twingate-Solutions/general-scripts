#!/bin/bash

# This script is designed to install or update the Twingate MacOS client application.

# Note: This script is provided as-is, and is intended to be used as a starting point for your own deployment scripts.
# It is meant to be run on MacOS 15 Sequoia, and may require modification to work in your environment.  
# It is recommended to test this script in a lab environment before deploying to production machines.


###################################
##  IMPORTANT NOTES BEFORE USE   ##
###################################
# Before running this script it is expected that you've already pushed a profile to the device via your MDM
# that allows the system extension to be installed without user intervention.  This is important if
# your users do not have local admin permissions, as it's a required step in order for the Twingate client to 
# install and run correctly.

# You can find a sample mobileconfig profile at https://www.twingate.com/docs/macos-standalone-client#pre-enabling-the-system-extension

# Make sure to push this profile out prior to the script being run, so that the Twingate client can be installed
# and run without the user having to approve the system extension.


# The script has a couple of optional features:
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

  # Create a plist file to configure the Twingate client according to https://www.twingate.com/docs/macos-and-ios#configuring-twingate-with-custom-configuration-profiles
  sudo tee "/Library/Preferences/com.twingate.macos.plist" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDisplayName</key>
			<string>Twingate VPN</string>
			<key>PayloadIdentifier</key>
			<string>com.apple.vpn.managed.F5473AE0-B40B-4518-A060-4D6922142916</string>
			<key>PayloadType</key>
			<string>com.apple.vpn.managed</string>
			<key>PayloadUUID</key>
			<string>F5473AE0-B40B-4518-A060-4D6922142916</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>UserDefinedName</key>
			<string>Twingate</string>
			<key>VPN</key>
			<dict>
				<key>AuthenticationMethod</key>
				<string>Password</string>
				<key>ProviderBundleIdentifier</key>
				<string>com.twingate.macos.tunnelprovider</string>
				<key>ProviderDesignatedRequirement</key>
				<string>anchor apple generic and identifier "com.twingate.macos.tunnelprovider" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "6GX8KVTR9H")</string>
				<key>RemoteAddress</key>
				<string>null</string>
			</dict>
			<key>VPNSubType</key>
			<string>com.twingate.macos</string>
			<key>VPNType</key>
			<string>VPN</string>
		</dict>
		<dict>
			<key>PayloadDisplayName</key>
			<string>Twingate</string>
			<key>PayloadIdentifier</key>
			<string>com.twingate.macos.E5640205-1048-4E95-82C0-13FF9D7168CB</string>
			<key>PayloadType</key>
			<string>com.twingate.macos</string>
			<key>PayloadUUID</key>
			<string>E5640205-1048-4E95-82C0-13FF9D7168CB</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>automaticallyInstallSystemExtension</key>
			<true/>
			<key>SUEnableAutomaticChecks</key>
			<false/>
      <key>startAtLogin</key>
      <true/>      
			<key>PresentedDataPrivacy</key>
			<true/>
			<key>PresentedEducation</key>
			<true/>
			<key>network</key>
			<string>$twingateNetworkName</string> <!-- Use the network name from the main script settings -->
		</dict>
		<dict>
			<key>NotificationSettings</key>
			<array>
				<dict>
					<key>BundleIdentifier</key>
					<string>com.twingate.macos</string>
					<key>NotificationsEnabled</key>
					<true/>
				</dict>
			</array>
			<key>PayloadDisplayName</key>
			<string>Notifications</string>
			<key>PayloadIdentifier</key>
			<string>com.apple.notificationsettings.23668A72-3BD2-458F-9A90-D91A332985DF</string>
			<key>PayloadType</key>
			<string>com.apple.notificationsettings</string>
			<key>PayloadUUID</key>
			<string>23668A72-3BD2-458F-9A90-D91A332985DF</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
		<dict>
			<key>PayloadDisplayName</key>
			<string>Background Items</string>
			<key>PayloadIdentifier</key>
			<string>com.apple.servicemanagement.634A0CE2-4A0B-49CB-B73E-9337DC6F5E69</string>
			<key>PayloadType</key>
			<string>com.apple.servicemanagement</string>
			<key>PayloadUUID</key>
			<string>634A0CE2-4A0B-49CB-B73E-9337DC6F5E69</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>Rules</key>
			<array>
				<dict>
					<key>RuleType</key>
					<string>TeamIdentifier</string>
					<key>RuleValue</key>
					<string>6GX8KVTR9H</string>
				</dict>
			</array>
		</dict>
		<dict>
			<key>AllowUserOverrides</key>
			<true/>
			<key>AllowedSystemExtensions</key>
			<dict>
				<key>6GX8KVTR9H</key>
				<array><string>com.twingate.macos.tunnelprovider</string></array>
			</dict>
			<key>PayloadDisplayName</key>
			<string>System Extension Policy</string>
			<key>PayloadIdentifier</key>
			<string>com.apple.system-extension-policy.60145087-607E-428B-9B3E-831856156D78</string>
			<key>PayloadType</key>
			<string>com.apple.system-extension-policy</string>
			<key>PayloadUUID</key>
			<string>60145087-607E-428B-9B3E-831856156D78</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>This Payload is used to allow a full silent install of the Twingate client.</string>
	<key>PayloadDisplayName</key>
	<string>Twingate Full Silent Install</string>
	<key>PayloadIdentifier</key>
	<string>com.twingate.macos.52104CA3-6289-47D7-A852-635A78CA69B5</string>
	<key>PayloadOrganization</key>
	<string>Twingate</string>
	<key>PayloadRemovalDisallowed</key>
	<true/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>044B0908-E76F-4B15-BADD-2547C290781D</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
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
