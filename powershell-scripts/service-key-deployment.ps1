# This script is designed to install or update the Twingate Windows client application in headless mode.

# Note: This script is provided as-is, and is intended to be used as a starting point for your own deployment scripts.
# It is meant to be run via Powershell 5.x on Windows 10 or 11 or Server 2022, and parts may not function on other versions of Windows
# or Powershell.  It is recommended to test this script in a lab environment before deploying to production.

# By default the script will always check to see if the Twingate client application is running, and kill it.  It will
# also check to see if the .NET Desktop Runtime 8.0 is installed, and install it if it is not.

###################################
##       Configure Variables     ##
###################################

# In order to deploy a client in headless mode you need a service key, which is generated in the Twingate Admin Console by
# going to Teams -> Service Accounts, creating a new Service Account and then a key for it.  Service Accounts need to be
# deployed 1:1 meaning a single deployed headless client can only be associated with a single Service Account.  Trying to
# deploy the same Service Account (not key, but the entire account) to multiple clients will cause issues.

# After you generate the service key copy the contents and paste into the variable below the comments, as shown in the 
# example below.

# Ex:
# $serviceKeyContent = @'
# {
#    "version": "1",
#    "network": "network.twingate.com",
#    "service_account_id": "bba5acb5-XXXX-XXXX-XXXX-c08df5f66602",
#    "private_key": "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCC...56Cf7StRPNfBU\n-----END PRIVATE KEY-----",
#    "key_id": "qkGJfLoCGB...OFjpNzmM1T8",
#    "expires_at": "2024-12-10T17:59:12+00:00",
#    "login_path": "/api/v4/headless/login"
#  }
# '@
#
# Make sure to paste the contents of the service key file replacing `serviceKey`, such that it matches the format above.

$serviceKeyFolder = "C:\Windows\Temp" # Don't touch this
$serviceKeyContent = @"
serviceKey
"@

# If you need to add a DNS search domain to the Twingate TAP adapter, enable the option below and add it to the variable.
# This can be useful if you have internal DNS domains in your remote networks that need to be resolved by the Twingate client.
$addDNSSearchDomain = $false
$dnsSearchDomain = "test.domain.com"

###################################
##       Static Variables        ##
###################################

# Don't change anything in this section, these are used by the script and need to left as is.

# Twingate Windows service name
$twingateServiceName = "twingate.service"

# Disable the WebRequest progress bar, speeds up downloads
$ProgressPreference = "SilentlyContinue"

###################################
##         Main Script           ##
###################################

# Start transcription
Start-Transcript -path c:\headless-client-install.log -append

# Check to see if Twingate is already running, if so kill it
Write-Host [+] Checking for existing Twingate install
if ((Get-Process -Name "Twingate" -ErrorAction SilentlyContinue) -And (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue)) {
	Stop-Service -Name $twingateServiceName -Force -ErrorAction SilentlyContinue
	Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue
}

# If Twingate is already installed let's remove it first, to be safe
Write-Host [+] Checking for existing Twingate client installation
$twingateApp = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name Like '%Twingate%'"
if ($twingateApp) {
    Write-Host [+] Uninstalling Twingate client
    $twingateApp.Uninstall()
}

# Check to see if the .NET Desktop Runtime 8.0 is already installed
Write-Host [+] Checking if .NET Desktop Runtime 8.0 is already installed
$dotnetRuntime = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE '%.NET%Runtime%8.%.%'"
if ($null -ne $dotnetRuntime) {
    Write-Host [+] .NET Desktop Runtime 8.0 is already installed
} else {
    # Installing the .NET Desktop Runtime
    Write-Host [+] .NET Desktop Runtime 8.0 is not installed
    Write-Host [+] Downloading .NET 8.0 Desktop Runtime
    $AgentURI = 'https://download.visualstudio.microsoft.com/download/pr/f398d462-9d4e-4b9c-abd3-86c54262869a/4a8e3a10ca0a9903a989578140ef0499/windowsdesktop-runtime-8.0.10-win-x64.exe'
    $AgentDest = 'C:\Windows\Temp\windowsdesktop-runtime-8.0.10-win-x64.exe'
    Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
    Write-Host [+] Installing the .NET 8.0 Desktop Runtime
    cmd /c "C:\Windows\Temp\windowsdesktop-runtime-8.0.10-win-x64.exe /install /quiet /norestart"
    Write-Host [+] Finished installing .NET 8.0 Desktop Runtime
}

# Create the temporary servicekey.json file
# Check to see if the file exists already, if so delete and recreate
if (-not (Get-Item -Path "$serviceKeyFolder\twingate-service-key.json" -ErrorAction SilentlyContinue)) {
    Write-Host [+] Creating twingate-service-key.json
    New-Item "$serviceKeyFolder\twingate-service-key.json" -ItemType File -Value $serviceKeyContent
} else {
    Write-Host [+] twingate-service-key.json already exists, deleting and recreating
    Remove-Item "$serviceKeyFolder\twingate-service-key.json" -Force
    New-Item "$serviceKeyFolder\twingate-service-key.json" -ItemType File -Value $serviceKeyContent
}
Write-Host [+] Finished installing twingate-service-key.json

# Installing the Twingate Client
Write-Host [+] Downloading Twingate Client
$AgentURI = 'https://api.twingate.com/download/windows?installer=msi'
$AgentDest = 'C:\Windows\Temp\TwingateInstaller.msi'
Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
Write-Host [+] Installing the Twingate Client using the twingate-service-key.json
cmd /c "msiexec.exe /i C:\Windows\Temp\TwingateInstaller.msi service_secret=c:\Windows\Temp\twingate-service-key.json /qn"
Write-Host [+] Finished installing Twingate Client
Write-Host [+] Setting the Twingate Service to auto-start
cmd /c "sc config $twingateServiceName start= auto"
Write-Host [+] Starting the Twingate Client Service
cmd /c "sc start $twingateServiceName"

# Set the DNS search domain for the Twingate TAP adapter
if ($addDNSSearchDomain) {
    Write-Host [+] Adding DNS search domains to the Twingate TAP adapter
    $tapAdapter = Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "*Twingate*"}
    if ($tapAdapter) {
        Set-DnsClient -InterfaceAlias 'Twingate' -ConnectionSpecificSuffix $dnsSearchDomain
        Write-Host [+] Finished adding DNS search domains to the Twingate TAP adapter
    } else {
        Write-Host [+] Twingate TAP adapter not found, skipping DNS search domain addition
    }
}

# Finished running the script
Write-Host [+] Finished running Twingate Client installer script

Stop-Transcript | Out-Null

Exit 0
