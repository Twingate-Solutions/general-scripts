# This script is meant to be run as a scheduled task on a Windows machine
# in order to initially install the Twingate Client and necessary .NET Desktop Runtime
# as well as to update the Client if necessary.  It's not necessary to know if there's
# a new version of the Client available, this can be scheduled to run on a monthly 
# basis and will simply update to the most recent version.

# If there's a concern about older versions of the Client still out in your deployed
# machines then push this via your MDM solution and it will immediately update any
# old versions.

# Set the variables
$twingateClientPath = "C:\Program Files\Twingate\Twingate.exe"
$twingateNetworkName = "networkname" #this is the name of the network in Twingate, ie networkname.twingate.com when you log in to the Admin Console

# Check to see if the .NET Desktop Runtime 6.0 is already installed
Write-Host [+] Checking if .NET Desktop Runtime 6.0 is already installed
$dotnetRuntime = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE '%.NET%Runtime%6.%.%'"
if ($dotnetRuntime -ne $null) {
    Write-Host [+] .NET Desktop Runtime 6.0 is already installed
} else {
    # Installing the .NET Desktop Runtime
    Write-Host [+] .NET Desktop Runtime 6.0 is not installed
    Write-Host [+] Downloading .NET Desktop Runtime
    $AgentURI = 'https://download.visualstudio.microsoft.com/download/pr/a1da19dc-d781-4981-84e9-ffa0c05e00e9/46f3cd2015c27a0e93d7c102a711577e/windowsdesktop-runtime-6.0.31-win-x64.exe'
    $AgentDest = 'C:\Windows\Temp\windowsdesktop-runtime-6.0.31-win-x64.exe'
    Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
    Write-Host [+] Installing the .NET Desktop Runtime
    cmd /c "C:\Windows\Temp\windowsdesktop-runtime-6.0.31-win-x64.exe /install /quiet /norestart"
    Write-Host [+] Finished installing .NET Desktop Runtime
}

# Installing the Twingate Client
Write-Host [+] Downloading Twingate Client
$AgentURI = 'https://api.twingate.com/download/windows?installer=msi'
$AgentDest = 'C:\Windows\Temp\TwingateInstaller.msi'
Invoke-WebRequest $AgentURI -OutFile $AgentDest -UseBasicParsing
Write-Host [+] Installing the Twingate Client
cmd /c "msiexec.exe /i C:\Windows\Temp\TwingateInstaller.msi /qn network=$twingateNetworkName.twingate.com no_optional_updates=true"
Write-Host [+] Finished installing Twingate Client
Write-Host [+] Starting Twingate Client
Start-Process -FilePath $twingateClientPath