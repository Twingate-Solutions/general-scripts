# This script is designed to install or update the Twingate Windows client application.
# It can be run locally as a scheduled task, or pushed remotely via a tool like Intune.

# Note: This script is provided as-is, and is intended to be used as a starting point for your own deployment scripts.
# It is meant to be run via Powershell 5.x on Windows 10 or 11, and parts may not function on other versions of Windows
# or Powershell.  It is recommended to test this script in a lab environment before deploying to production.

# The script has a couple of optional features:
# - It can first uninstall the client app before re-installing it from scratch
# - It can install a machinekey.conf to enforce always-on connectivity (mostly for Twingate Internet Security)
# - It can create a scheduled task to auto-start the Twingate client application if it's ever quit by the user

# By default the script will always check to see if the Twingate client application is running, and kill it.  It will
# also check to see if the .NET Desktop Runtime 6.0 is installed, and install it if it is not.

###################################
##  Configure Optional Features  ##
###################################

# To uninstall the client app before re-installing, set to true.  This can be useful if you want to ensure a clean install.
# This will also trigger the initial "Join Network" dialog to appear, unless you also include a machinekey.conf in which case
# the client will automatically join the network and the dialog will be suppressed. 
$uninstallFirst = $false

# A machine key is used to enforce "always on" for the client, and is typically used for Twingate Internet Security.  It will
# remote the ability for the user to log out or quit the client application.  This is optional, and should only be used if you
# are sure you want to enforce always-on connectivity.  If you are unsure, please reach out to Twingate support for guidance.

# To create a machinekey.conf file, set $createMachineKey to true, and paste the contents of the file in the $machineKey variable.
# The machinekey.conf contents are found in your Twingate Admin Console, under the Internet Security section.
# When you go to Client Configuration you can create a new machine key, and copy the contents to paste in the variable below.
# Ex:
# $machineKeyContent = @'
# {
#   "version": "2",
#   "network": "test.twingate.com",
#   "private_key": "-----BEGIN PRIVATE KEY-----\PRIVATEKEYGOESHERE\n-----END PRIVATE KEY-----",
#   "id": "IDGOESHERE"
# }
# '@
#
# Make sure to paste the contents of the machinekey.conf file replacing `machinekey`, such that it matches the format above.

$createMachineKey = $false
$machineKeyTargetFolder = "C:\ProgramData\Twingate" # Don't touch this
$machineKeyContent = @"
machinekey
"@

# To create a scheduled task to auto-start the Twingate client application if it's ever quit by the user, set to true.
# You can also choose how often to check if the Twingate client is running, and how often to restart it.
$createScheduledTask = $false
$taskName = "Twingate Client Restart"
$taskDescription = "This task will check every 5 minutes to see if the Twingate client is running, and restart it if it is not."
$taskMinutes = 5

# If you want to run a scheduled task to check if the user is logged out of the Twingate client, set to true.  
# This will download a secondary script `user_not_logged_in_notification.ps1` and schedule it to run based on the configuration below. 
# The source of this script can be found in the https://github.com/Twingate-Solutions/general-scripts/ repository.
$checkUserLoggedIn = $false
$checkUserTaskName = "Twingate User Logged Out Notification"
$checkUserTaskDescription = "This task will periodically check to see if the user is logged out of the Twingate client."
$checkUserFrequency = 30 # How often to check if the user is logged in, in minutes
$checkUserResourceURL = "http://internal.domain.com" # The Resource URL to check if the user is logged in, see the user_not_logged_in_notification.ps1 script for more details
$checkUserResourceMethod = "get" # The method to use to check the Resource URL, either 'get' or 'ping'

# If you need to add a DNS search domain to the Twingate TAP adapter, enable the option below and add it to the variable.
# This is useful if you have internal DNS domains that need to be resolved by the Twingate client.
$addDNSSearchDomain = $false
$dnsSearchDomain = "test.domain.com"

###################################
##         Set Variables         ##
###################################

# Twingate network subnet name, ie the subdomain part of networkname.twingate.com when you log in to the Admin Console
# It's important to change this to your network subnet name if you want to auto-populate it.
# If you are installing a machinekey.conf then that will override this.
$twingateNetworkName = "networkname" 

# Path to the Twingate client executable post-installation
$twingateClientPath = "C:\Program Files\Twingate"

# Twingate Windows service name
$twingateServiceName = "twingate.service"

# Disable the WebRequest progress bar, speeds up downloads
$ProgressPreference = "SilentlyContinue"

###################################
##         Functions             ##
###################################

# Function to promote the Twingate icon in the Windows registry, Windows 11 only
function Set-TwingateNotifyIconPromoted {
    $results = @()  
    $userSIDs = Get-ChildItem -Path "registry::HKEY_USERS\"
    foreach ($userSID in $userSIDs) {
        $notifyIconPath = "registry::HKEY_USERS\$($userSID.PSChildName)\Control Panel\NotifyIconSettings"
        if (Test-Path -Path $notifyIconPath) {
            $notifyIconSubKeys = Get-ChildItem -Path $notifyIconPath
            foreach ($subKey in $notifyIconSubKeys) {
                $subKeyPath = "registry::HKEY_USERS\$($userSID.PSChildName)\Control Panel\NotifyIconSettings\$($subKey.PSChildName)"
                $executablePath = Get-ItemProperty -Path $subKeyPath -Name "ExecutablePath" -ErrorAction SilentlyContinue
                if ($executablePath -and $executablePath.ExecutablePath -like "*twingate.exe*") {
                    Set-ItemProperty -Path $subKeyPath -Name "IsPromoted" -Value 1
                    Write-Host [+] Updated IsPromoted for $subKeyPath
                    $result = [PSCustomObject]@{
                        UserSID       = $userSID.PSChildName
                        SubKeyPath    = $subKeyPath
                        ExecutablePath = $executablePath.ExecutablePath
                    }
                    $results += $result
                }
            }
        }
    }
    return $results
}

###################################
##         Main Script           ##
###################################

# Start transcription
Start-Transcript -path c:\client-install.log -append

# Check to see if Twingate is already running, if so kill it
Write-Host [+] Checking for existing Twingate install
if ((Get-Process -Name "Twingate" -ErrorAction SilentlyContinue) -And (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue)) {
	Stop-Service -Name $twingateServiceName -Force -ErrorAction SilentlyContinue
	Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue
}

# If the uninstallFirst variable is set to true, then uninstall the Twingate client
# This is useful if you want to ensure a clean install
if ($uninstallFirst) {
    Write-Host [+] Uninstall flag set, uninstalling Twingate Client application
    $twingateApp = Get-WmiObject -Class Win32_Product -Filter 'Name LIKE "%Twingate%"'
    if ($twingateApp) {
        $twingateApp.Uninstall()
    }
}

# Check to see if the .NET Desktop Runtime 6.0 is already installed
Write-Host [+] Checking if .NET Desktop Runtime 6.0 is already installed
$dotnetRuntime = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE '%.NET%Runtime%6.%.%'"
if ($null -ne $dotnetRuntime) {
    Write-Host [+] .NET Desktop Runtime 6.0 is already installed
} else {
    # Installing the .NET Desktop Runtime
    Write-Host [+] .NET Desktop Runtime 6.0 is not installed
    Write-Host [+] Downloading .NET 6.0 Desktop Runtime
    $AgentURI = 'https://download.visualstudio.microsoft.com/download/pr/a1da19dc-d781-4981-84e9-ffa0c05e00e9/46f3cd2015c27a0e93d7c102a711577e/windowsdesktop-runtime-6.0.31-win-x64.exe'
    $AgentDest = 'C:\Windows\Temp\windowsdesktop-runtime-6.0.31-win-x64.exe'
    Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
    Write-Host [+] Installing the .NET 6.0 Desktop Runtime
    cmd /c "C:\Windows\Temp\windowsdesktop-runtime-6.0.31-win-x64.exe /install /quiet /norestart"
    Write-Host [+] Finished installing .NET 6.0 Desktop Runtime
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

# Installing the Twingate Client
Write-Host [+] Downloading Twingate Client
$AgentURI = 'https://api.twingate.com/download/windows?installer=msi'
$AgentDest = 'C:\Windows\Temp\TwingateInstaller.msi'
Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
Write-Host [+] Installing the Twingate Client
cmd /c "msiexec.exe /i C:\Windows\Temp\TwingateInstaller.msi /qn network=$twingateNetworkName.twingate.com no_optional_updates=true"
Write-Host [+] Finished installing Twingate Client

# If the createMachineKey variable is set to true, then create the machinekey.conf file
if ($createMachineKey) {
    Write-Host [+] Machinekey.conf flag set, creating machinekey.conf
    Write-Host [+] Checking for target machinekey.conf folder
    if (-not (Test-Path $machineKeyTargetFolder)) {
        Write-Host [+] Creating Twingate folder
        New-Item -ItemType Directory -Path $machineKeyTargetFolder
    }

    # Check to see if the file exists already, if so delete and recreate
    if (-not (Get-Item -Path "$machineKeyTargetFolder\machinekey.conf" -ErrorAction SilentlyContinue)) {
        Write-Host [+] Creating machinekey.conf
        New-Item "$machineKeyTargetFolder\machinekey.conf" -ItemType File -Value $machineKeyContent
    } else {
        Write-Host [+] machinekey.conf already exists, deleting and recreating
        Remove-Item "$machineKeyTargetFolder\machinekey.conf" -Force
        New-Item "$machineKeyTargetFolder\machinekey.conf" -ItemType File -Value $machineKeyContent
    }
    Write-Host [+] Finished installing machinekey.conf
}

# If the createScheduledTask variable is set to true, then create the scheduled task
if ($createScheduledTask) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Write-Host [+] Scheduled Task already exists, removing and recreating
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Write-Host [+] Scheduled Task flag set, creating scheduled task
    Write-Host [+] Creating scheduled task
    $action = New-ScheduledTaskAction -Execute "$twingateClientPath\twingate.exe"
    $taskTrigger = @(
        $(New-ScheduledTaskTrigger -Once -At 12:01AM -RepetitionInterval (New-TimeSpan -Minutes $taskMinutes)),
        $(New-ScheduledTaskTrigger -Daily -At 12:01AM),
        $(New-ScheduledTaskTrigger -AtStartup)
    )
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users"
    Register-ScheduledTask -TaskName $taskName -Description $taskDescription -Action $action -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal
    Write-Host [+] Finished creating scheduled task

    # Since a scheduled task has been created, start it and the Twingate service
    Write-Host [+] Starting Task, starting Twingate Client
    Start-ScheduledTask -TaskName $taskName
    Start-Service -Name $twingateServiceName -ErrorAction SilentlyContinue
} else {
    Write-Host [+] Scheduled Task flag not set, skipping scheduled task creation

    # Start the Twingate service and application
    Write-Host [+] Starting Twingate Client
    Start-Process -FilePath "$twingateClientPath\twingate.exe"
    Start-Service -Name $twingateServiceName -ErrorAction SilentlyContinue
}

# If the checkUserLoggedIn variable is set to true, then create the scheduled task to check if the user is logged in
if ($checkUserLoggedIn) {
    if (Get-ScheduledTask -TaskName $checkUserTaskName -ErrorAction SilentlyContinue) {
        Write-Host [+] User Logged In scheduled task already exists, removing and recreating
        Unregister-ScheduledTask -TaskName $checkUserTaskName -Confirm:$false
    }
    Write-Host [+] User Logged In flag set, creating scheduled task

    # Download the script file and put in the new Twingate Client folder
    Write-Host [+] Downloading user_not_logged_in_notification.ps1
    $AgentURI = 'https://raw.githubusercontent.com/Twingate-Solutions/general-scripts/main/powershell-scripts/user_not_logged_in_notification.ps1'
    $AgentDest = "$twingatePath\user_not_logged_in_notification.ps1"
    Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing

    # Create the vbscript file that's used to run the Powershell script
    
    # This is super hacky, but the scheduled task needs to run as the logged in user
    # in order for the toast notification to work, and also Powershell scripts 
    # cause a shell window to spawn so you get a nasty flash of a window coming up.
    
    # Having the task run wscript and a vbs file that runs the ps1 file is a roundabout
    # way of avoiding all of that while still running the script in the user space.

    $checkUserVbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -File ""$twingateClientPath\user_not_logged_in_notification.ps1"" $checkUserResourceURL $checkUserResourceMethod", 0, False
"@

    if (-not (Get-Item -Path "$twingateClientPath\user_not_logged_in_notification.vbs" -ErrorAction SilentlyContinue)) {
        Write-Host [+] Creating VBS script
        New-Item "$twingateClientPath\user_not_logged_in_notification.vbs" -ItemType File -Value $checkUserVbsContent
    } else {
        Write-Host [+] VBS script already exists, deleting and recreating
        Remove-Item "$twingateClientPath\user_not_logged_in_notification.vbs" -Force
        New-Item "$twingateClientPath\user_not_logged_in_notification.vbs" -ItemType File -Value $checkUserVbsContent
    }
    Write-Host [+] Finished installing VBS script

    # Create the scheduled task to run the script
    Write-Host [+] Creating scheduled task to check if user is logged in
    $checkUserTaskAction = New-ScheduledTaskAction -Execute "wscript" -Argument """$twingateClientPath\user_not_logged_in_notification.vbs"""
    $checkUserTaskTrigger = @(
        $(New-ScheduledTaskTrigger -Once -At 12:01AM -RepetitionInterval (New-TimeSpan -Minutes $checkUserFrequency)),
        $(New-ScheduledTaskTrigger -Daily -At 12:01AM),
        $(New-ScheduledTaskTrigger -AtStartup)
    )
    $checkUserTaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $checkUserTaskPrincipal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Highest
    Register-ScheduledTask -TaskName $checkUserTaskName -Description $checkUserTaskDescription -Action $checkUserTaskaction -Trigger $checkUserTaskTrigger -Settings $checkUserTaskSettings -Principal $checkUserTaskPrincipal
    Write-Host [+] Finished creating scheduled task to check if user is logged in

    # Start the scheduled task
    Write-Host [+] Starting Task to check if user is logged in
    Start-ScheduledTask -TaskName $checkUserTaskName
} else {
    Write-Host [+] User Logged in flag not set, skipping scheduled task creation
}

# Promote the Twingate icon in the Windows registry, Windows 11 only
Write-Host [+] Trying to promote Twingate icon in the Windows registry
Set-TwingateNotifyIconPromoted
foreach ($result in $results) {
    Write-Host "Registry Key: $($result.RegistryKey)"
    Write-Host "ExecutablePath: $($result.ExecutablePath)"
    Write-Host ""
}

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
