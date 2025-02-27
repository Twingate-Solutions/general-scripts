# This script is designed to uninstall the Twingate Windows client application.
# It will stop any currently running Twingate processes and services, and then uninstall the application.
# It also checks for any leftover program data folders and removes them.

###################################
##         Set Variables         ##
###################################

# Programdata location
$twingateProgramData = "%ProgramData%\Twingate"

# Twingate Windows service name
$twingateServiceName = "twingate.service"

###################################
##         Main Script           ##
###################################

# Start transcription
Start-Transcript -path c:\client-install.log -append

# Check to see if Twingate is already running, if so kill it
Write-Host [+] Checking for Twingate installation
if ((Get-Process -Name "Twingate" -ErrorAction SilentlyContinue) -And (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue)) {
	Stop-Service -Name $twingateServiceName -Force -ErrorAction SilentlyContinue
	Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue
} else {
    Write-Host [+] Twingate is not running
}

# Check to see if the TG client app is installed and if so remove it
Write-Host [+] Uninstalling Twingate
Write-Host [+] Uninstall flag set, uninstalling Twingate Client application
$twingateApp = Get-WmiObject -Class Win32_Product -Filter 'Name LIKE "%Twingate%"'
if ($twingateApp) {
    $twingateApp.Uninstall()
} else {
    Write-Host [+] Twingate is not installed
}

# Check for and remove any of the scheduled tasks
Write-Host [+] Checking for scheduled tasks
if (Get-ScheduledTask -TaskName "Twingate Client Auto Update" -ErrorAction SilentlyContinue) {
    Write-Host [+] Auto update task exists, removing it
    Unregister-ScheduledTask -TaskName "Twingate Client Auto Update" -Confirm:$false
}

if (Get-ScheduledTask -TaskName "Twingate Client Restart" -ErrorAction SilentlyContinue) {
    Write-Host [+] Scheduled Task exists, removing it
    Unregister-ScheduledTask -TaskName "Twingate Client Restart" -Confirm:$false
}

if (Get-ScheduledTask -TaskName "Twingate User Logged Out Notification" -ErrorAction SilentlyContinue) {
    Write-Host [+] User Logged In scheduled task exists, removing it
    Unregister-ScheduledTask -TaskName "Twingate User Logged Out Notification" -Confirm:$false
}

# Check if the Twingate ProgramData folder exists
if (Test-Path $twingateProgramData) {
    Write-Host [+] Removing Twingate ProgramData folder
    Remove-Item -Path $twingateProgramData -Recurse -Force
} else {
    Write-Host [+] Twingate ProgramData folder does not exist
}

# Remove the NextDNS Root Cert if it exists
Write-Host [+] Removing the NextDNS Root Cert
certutil –delstore Root d47605fc0736802cee4153dda032d276cf2c81c7

# Finished running the script
Write-Host [+] Finished running Twingate Client uninstaller script

Stop-Transcript | Out-Null

Exit 0
