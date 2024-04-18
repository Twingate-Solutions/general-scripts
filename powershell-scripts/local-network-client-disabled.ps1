# This script can be run as a scheduled task on a Windows machine, to check if
# the device is on a specific network.  The goal is to identify that the device
# is on the same network as the bulk of your Twingate Resources, and then to
# disconnect the Client and service so that the user can access the Resources
# locally instead of through Twingate.

# Set variables
$twingateClientPath = "C:\Program Files\Twingate\Twingate.exe"
$twingateClientService = "twingate.service"

# These two are what it checks for on the network.  Because the TG Client
# intercepts DNS when it's running, it's not possible to use a Resolve-DnsName
# command to check for the presence of the key system to determine if the
# device is on the network.  Instead, we're using the key system's IP address
# and NetBios name to determine if the device is on the network.

# This in theory could just be a ping against the IP address, or a check for 
# an open port, whatever works for your network.
$routerIP = "xxx.xxx.xxx.xxx" # <--- Replace with the IP address of the key system
$routerNetBiosName = "NetBIOSName" # <--- Replace with the NetBios name of the key system


# Check for Twingate Client service
$service = Get-Service -Name $twingateClientService -ErrorAction SilentlyContinue

# Check for Twingate Client process
$process = Get-Process -Name "Twingate" -ErrorAction SilentlyContinue

# Check if device is on network
$netBiosLookup = nbtstat -A $routerIP
if ($netBiosLookup) {
    if ($netBiosLookup -match $routerNetBiosName) { # Device is on the network
        Write-Host "Device is on network."
        Stop-Service -Name $twingateClientService -Force -ErrorAction SilentlyContinue
        Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue
    } else { # Device is not on the network
        Write-Host "Device is not on network."
        if ($service -And $process){ # Twingate Client is already running, no need to do anything
            Write-Host "Twingate Client is already running."
        } else { # Twingate Client is not running, start it along with the service, this should trigger an auth prompt
            Start-Process -FilePath $twingateClientPath
            Start-Sleep -Seconds 5
            Start-Service -Name $twingateClientService 
        }           
    }
}