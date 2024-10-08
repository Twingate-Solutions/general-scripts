# This script is meant to install a Twingate Connector via a Hyper-V hosted Ubuntu machine.
#
# In order for the script to work you will first need to create a Connector within your Twingate
# Admin Console and export the Access and Refresh tokens.
#
# Note: This script assumes that the VM archive contains the necessary files for the VM to run properly.
#
# Before running the script, ensure that you have the necessary permissions to install Hyper-V and run PowerShell scripts.

###################################
##         Set Variables         ##
###################################

# Set your network name below.  This is the subdomain part of your log in to the website, ie if you
# log in at https://companyname.twingate.com then your network name is companyname
$networkName = "companyname"  # Your Twingate network name

# Copy and paste the Access Token from the Connector deployment screen in the Admin Console below, it'll be very long but it's important to do it properly
$accessToken = "eyJhbGciOiJFUzI1NiIsIm...pPyRTuSTj-DymF8mmEaQqasJauB-5KMQ"  

# Copy and paste the Refresh Token from the Connector deployment screen in the Admin Console below, it's shorter than the Access Token but still important
$refreshToken = "80zwhsC-EdzaB...JoXkTM4dau10g"  # Your Twingate refresh token

# The variables below don't need to be changed, as the script will automatically download the archive and put it into the path below
$vmName = "Ubuntu_Twingate_Connector-22_04"
$archiveURI = "https://github.com/Twingate-Solutions/general-scripts/releases/download/hyperv-image/Ubuntu_Twingate_Connector-22_04.zip" # URL of the current VM archive
$archivePath = "C:\windows\temp\Ubuntu_Twingate_Connector-22_04.zip"  # Path to your ZIP archive
$vmExtractPath = "C:\twingate-connector-hyperv"  # Path to extract the VM files

# Disable the WebRequest progress bar, speeds up downloads
$ProgressPreference = "SilentlyContinue"

###################################
##          Main Script          ##
###################################



# ********************TO DO********************
# The check below doesn't fully work, it seems the Install-WindowsFeature cmdlet is available on W11
# but it doesn't work since it's not a server OS, so I need to find a better way to check for the OS type
# ********************************************

# Check to see if the script is running on Windows Desktop or Server
if (Get-Command -Name Install-WindowsFeature -ErrorAction SilentlyContinue) {
    Write-Host "[+] Windows Server detected..."
    $osType = "Server"
} elseif (Get-Command -Name Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    Write-Host "[+] Windows Desktop detected..."
    $osType = "Desktop"
}

# Check for Hyper-V 
if ($osType -eq "Server") {
    if (-not (Get-WindowsFeature -Name Hyper-V)) {
        $installHyperV = Read-Host "[-] Hyper-V is not installed. Do you want to install Hyper-V? (WARNING: This will initiate a restart) (Y/N)"

        # Install Hyper-V if it's not already installed
        if ($installHyperV -eq "Y") {
            Write-Host "[+] Installing Hyper-V..."
            Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
            Write-Host "[+] Hyper-V has been installed. In order to continue with the installation a system reboot needs to be performed."
            Write-Host "[+] Please save your data in all other programs before continuing.  Once the system has rebooted please run this script again."
            Write-Host " "
            Write-Host " "
            Read-Host "******WHEN READY TO REBOOT PRESS ENTER******"
            Restart-Computer
        } else {
            Write-Host "[-] Hyper-V is required for this script to run. Exiting script."
            Exit
        }
    } else {
        Write-Host "[+] Hyper-V is already installed. Continuing installation..."
    }
    
} elseif ($osType -eq "Desktop") {
    if (-not (Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online)) {
        $installHyperV = Read-Host "[-] Hyper-V is not installed. Do you want to install Hyper-V? (WARNING: This will initiate a restart) (Y/N)"

        # Install Hyper-V if it's not already installed
        if ($installHyperV -eq "Y") {
            Write-Host "[+] Installing Hyper-V..."
            Enable-WindowsOptionalFeature -FeatureName "Microsoft-Hyper-V-All" -All -Online
            Write-Host "[+] Hyper-V has been installed. In order to continue with the installation a system reboot needs to be performed."
            Write-Host "[+] Please save your data in all other programs before continuing.  Once the system has rebooted please run this script again."
            Write-Host " "
            Write-Host " "
            Read-Host "******WHEN READY TO REBOOT PRESS ENTER******"
            Restart-Computer
        } else {
            Write-Host "[-] Hyper-V is required for this script to run. Exiting script."
            Exit
        }
    } else {
        Write-Host "[+] Hyper-V is already installed. Continuing installation..."
    } 
} else {
    Write-Host "[-] Unable to determine OS type. Exiting script."
    Exit
}

# Check to see if Posh-SSH is installed, this is used to send SSH commands to the running VM
if (-not (Get-Module -Name Posh-SSH)) {
    Write-Host " "
    Write-Host " "
    Write-Host "[+] Posh-SSH is not installed. Installing Posh-SSH..."
    Install-Module -Name Posh-SSH -Force
    Import-Module Posh-SSH
} else {
    Write-Host " "
    Write-Host " "
    Write-Host "[+] Posh-SSH is already installed. Continuing installation..."
}

# Download and unpack the VM archive
Write-Host " "
Write-Host " "
Write-Host "[+] Checking for the VM archive..."
if (-not (Test-Path $archivePath)) {
    Write-Host "[-] VM archive not found. Downloading a fresh copy..."
    Invoke-WebRequest $archiveURI -OutFile $archivePath -UseBasicParsing
} else {
    Write-Host "[+] VM archive found. Continuing with the installation..."
}
Write-Host "[+] Time to unpack the VM archive"
Write-Host "[+] Archive Path: $archivePath"
Write-Host "[+] Extract Path: $vmExtractPath"
Write-Host "[+] Please wait, this may take some time..."
Expand-Archive -Path $archivePath -DestinationPath $vmExtractPath -Force

# Check for an existing external type vmswitch
$existingSwitch = Get-VMSwitch -SwitchType External
if ($existingSwitch) {
    Write-Host " "
    Write-Host " "
    Write-Host "[+] Found an existing external virtual switch: $($existingSwitch.Name)"
    Write-Host "[+] Using this existing switch for the VM..."
    $vmSwitchName = $existingSwitch.Name
} else { # Create a new external switch if none exists
    Write-Host " "
    Write-Host " "
    Write-Host "[+] No existing external virtual switch found. Creating a new one..."
    New-VMSwitch -Name "TwingateExternalSwitch" -NetAdapterName "Ethernet"
    Set-VMSwitch -Name "TwingateExternalSwitch" -AllowManagementOS $true
    $vmSwitchName = "TwingateExternalSwitch"
}

# Import the existing VM
Write-Host " "
Write-Host " "
Write-Host "[+] Importing the existing VM..."

# Go through the extracted files and find the VM configuration file
$vmConfigFiles = Get-ChildItem -Path $vmExtractPath -Recurse -Filter "*.vmcx"
if ($vmConfigFiles.Count -eq 0) {
    Write-Host "[-] No VM configuration files found. Exiting script."
    Exit
} elseif ($vmConfigFiles.Count -gt 1) {
    Write-Host "[-] Multiple VM configuration files found. Exiting script."
    Exit
}

# Import the VM
Write-Host $vmConfigFiles.FullName
Import-VM -Path $vmConfigFiles.FullName

# Attach the VM to the external switch
Write-Host " "
Write-Host " "
Write-Host "[+] Attaching the VM to the external switch..."
Get-VM $vmName | Get-VMNetworkAdapter | Connect-VMNetworkAdapter -SwitchName $vmSwitchName

# Start the VM
Write-Host "[+] Starting VM..."
Start-VM -Name $vmName

# Wait for the VM to be fully booted (simple sleep as a placeholder)
Write-Host "[+] Waiting for the VM to boot up..."
Start-Sleep -Seconds 120  # Adjust sleep time according to your environment

# Run the TG Connector installation script inside the VM
# Because the VM will grab an IP from DHCP, try to access it via hostname instead
$vmHostName = "twingate-connector" 
$username = "twingate"  
$password = "twingate"  | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $password)

$session = New-SSHSession -ComputerName $vmHostName -Credential $credential -AcceptKey:$true -Force:$true

(Invoke-SSHCommand -SessionId $session.SessionId -Command "sudo apt update | sudo apt upgrade -y").Output
(Invoke-SSHCommand -SessionId $session.SessionId -Command "sudo apt install -y curl").Output
(Invoke-SSHCommand -SessionId $session.SessionId -Command "curl 'https://binaries.twingate.com/connector/setup.sh' | sudo TWINGATE_ACCESS_TOKEN='$accessToken' TWINGATE_REFRESH_TOKEN='$refreshToken' TWINGATE_NETWORK='$networkName' TWINGATE_LABEL_DEPLOYED_BY='hyperv-deploy-script' bash").Output
(Invoke-SSHCommand -SessionId $session.SessionId -Command "sudo chmod -R 0777 /etc/twingate").Output
(Invoke-SSHCommand -SessionId $session.SessionId -Command "sudo echo 'TWINGATE_LABEL_DEPLOYED_BY=hyperv-deploy-script' >> /etc/twingate/connector.conf").Output
(Invoke-SSHCommand -SessionId $session.SessionId -Command "sudo systemctl restart twingate-connector").Output

# Assuming everything worked, end the script
Write-Host "[+] Bash commands executed inside the VM."