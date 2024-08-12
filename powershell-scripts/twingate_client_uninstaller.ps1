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

Write-Host [+] Uninstalling Twingate
$twingateApp = Get-WmiObject -Class Win32_Product | Where-Object{$_.Name.Contains("Twingate")}
if ($twingateApp) {
    $twingateApp.Uninstall()
} else {
    Write-Host [+] Twingate is not installed
}

# Check if the Twingate ProgramData folder exists
if (Test-Path $twingateProgramData) {
    Write-Host [+] Removing Twingate ProgramData folder
    Remove-Item -Path $twingateProgramData -Recurse -Force
} else {
    Write-Host [+] Twingate ProgramData folder does not exist
}


# Finished running the script
Write-Host [+] Finished running Twingate Client uninstaller script

Stop-Transcript | Out-Null

Exit 0
