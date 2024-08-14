# This script is meant to check to see if the Twingate user is logged in 
# to the network, through a simple test against a Resource assigned to
# the Everyone group.

# If the test succeeds then nothing happens, if it fails then it will
# trigger a system notification to alert the user that they should log in.

# The seprate twingate-client-installer.ps1 script can be used to install this
# and create the scheduled task to run this script.

###########################
#  Twingate Setup Steps   #
###########################

# In order for this script to work properly, and to be able to detect whether a user is
# logged in to the Client application or not, you need to have a universal Resource 
# that is available to all users.

# Inside of the Twingate Admin Console, create a new Resource and assign it to the Everyone
# group.  This Resource should be accessible by all users, and should be a simple HTTP or HTTPS
# URL that can be tested by this script.

# Ideally using the `ping` method works best, as it will be checked to resolve to a CGNAT IP
# as well as that a connection goes through, but if your network doesn't support pings
# then use the `get` method instead, which will attempt to load the page and get a HTTP 200
# response code.

###########################
#  Script Usage Example   #
###########################

# Example usage:
# powershell -ExecutionPolicy Bypass -File user-not-logged-in-notification.ps1 "internal.domain.com" "get"

# The first parameter is the Resource URL to test, and the second parameter
# is the test method to use, either 'get' or 'ping'.

# The 'get' method will try to make a GET request to the Resource URL and
# check for a 200 HTTP response code.

# The 'ping' method will try to ping the Resource URL and check for a response
# time of less than 5000ms.

# The script will also check to see if the Twingate service is running before
# attempting to test the Resource URL.

# The script will also check to see if the IP address of the Resource URL is
# within the Twingate CGNAT CIDR range before attempting to test the Resource URL.

###########################
# Deployment Instructions #
###########################

# This script needs to be run with elevated permissions, so it is recommended to
# create a scheduled task that runs this script with elevated permissions.

# There's therefore two options:
# 1. Deploy via MDM directly, create a scheduled task, and have it run this script using the example above
# 2. Deploy via the twingate_client_installer.ps1 or similar script, which will download this script as well
# as create the scheduled task to run this script.  Configure that script with the necessary parameters.

###########################
# Configuration Variables #
###########################

# Get first command line parameter which should be the Resource URL to test.
$resourceUrl = $args[0]

# Get the second command line parameter which should be the test method, ie 'get' or 'ping'.
# This will control how the script tries to test the Resource, and whether it will look
# for a specific HTTP response of 200 or just a successful ping under < 5000ms.
$testMethod = $args[1]

# Main Twingate service name
$twingateServiceName = "twingate.service"

# Disable the WebRequest progress bar, speeds up downloads
$ProgressPreference = "SilentlyContinue"

###########################
#        Functions        #
###########################

# Function to trigger the system notification
# Credit: https://den.dev/blog/powershell-windows-notification/
function Show-Notification {
    [cmdletbinding()]
    Param (
        [string]
        $ToastTitle,
        [string]
        [parameter(ValueFromPipeline)]
        $ToastText
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $Template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)

    $RawXml = [xml] $Template.GetXml()
    ($RawXml.toast.visual.binding.text|where {$_.id -eq "1"}).AppendChild($RawXml.CreateTextNode($ToastTitle)) > $null
    ($RawXml.toast.visual.binding.text|where {$_.id -eq "2"}).AppendChild($RawXml.CreateTextNode($ToastText)) > $null

    $SerializedXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $SerializedXml.LoadXml($RawXml.OuterXml)

    $Toast = [Windows.UI.Notifications.ToastNotification]::new($SerializedXml)
    $Toast.Tag = "PowerShell"
    $Toast.Group = "PowerShell"
    $Toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(1)

    $Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Twingate")
    $Notifier.Show($Toast);
}

# Function to test if an IP address is within the Twingate CGNAT CIDR range
function Test-IPInCIDR {
    param (
        [string]$IPAddress
    )

    # Split CIDR into IP and Prefix Length
    $CIDRParts = "100.64.0.0/10" -split '/'
    $CIDRIP = [System.Net.IPAddress]::Parse($CIDRParts[0])
    $PrefixLength = [int]$CIDRParts[1]

    # Convert the IP address and CIDR IP address to bytes
    $IPBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    $CIDRIPBytes = $CIDRIP.GetAddressBytes()

    # Calculate the network mask
    $NetworkMask = [System.Net.IPAddress]::Parse("255.255.255.255").GetAddressBytes()
    for ($i = 0; $i -lt $NetworkMask.Length; $i++) {
        if ($PrefixLength -gt 8) {
            $PrefixLength -= 8
        } else {
            $NetworkMask[$i] = $NetworkMask[$i] -shr (8 - $PrefixLength)
            $PrefixLength = 0
        }
    }

    # Apply the network mask to both the IP address and the CIDR IP address
    $NetworkBytes = @()
    for ($i = 0; $i -lt $IPBytes.Length; $i++) {
        $NetworkBytes += ($IPBytes[$i] -band $NetworkMask[$i])
    }
    $CIDRNetworkBytes = @()
    for ($i = 0; $i -lt $CIDRIPBytes.Length; $i++) {
        $CIDRNetworkBytes += ($CIDRIPBytes[$i] -band $NetworkMask[$i])
    }

    $ipjoined = $NetworkBytes -join '.'
    $cidrjoined = $CIDRNetworkBytes -join '.'

    Write-Host "Network Bytes:"  ($ipjoined)
    Write-Host "CIDR Network Bytes:" ($cidrjoined)

    # Check if the network addresses match
    if ($ipjoined -eq $cidrjoined) {
        Write-Host [+] "IP address is within the Twingate CGNAT CIDR range."
        return $true

    } else {
        return $false
    }
}

###########################
#        Main Script      #
###########################

# Check to see if the Twingate service is running
Write-Host [+] "Checking to see if Twingate service is running..."
if ((Get-Process -Name "Twingate" -ErrorAction SilentlyContinue) -And (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue)) {
    Write-Host [+] "Twingate service is running, continuing script."
    Write-Host [+] "Testing Resource URL: $resourceUrl"
    Write-Host [+] "Test Method: $testMethod"

    # Test the Resource URL
    if ($testMethod -eq "get") {
        $response = Invoke-WebRequest -Uri $resourceUrl -Method Get -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host [+] "Resource test successful, user is logged in."
            exit
        } else {
            Write-Host [-] "Resource test failed, user is not logged in."
            Show-Notification -ToastTitle "Twingate Status" -ToastText "Have you forgotten to log in to Twingate?  Please log in to access the network."
        }
    } elseif ($testMethod -eq "ping") {
        $ping = Test-Connection -ComputerName $resourceUrl -Count 1 -ErrorAction SilentlyContinue
        if ($ping.IPV4Address -eq $null) {
            Write-Host [-] "Resource test failed, user is not logged in."
            Show-Notification -ToastTitle "Twingate Status" -ToastText "Have you forgotten to log in to Twingate?  Please log in to access the network."
        } else {
            Write-Host "Ping Response Time: $($ping.ResponseTime)"
            Write-Host "Ping IPV4 Address: $($ping.IPV4Address)"
            if (Test-IPInCIDR -IPAddress $ping.IPV4Address) {
                if ($ping.ResponseTime -lt 5000) {
                    Write-Host [+] "Resource test successful, user is logged in."
                    exit
                } else {
                    Write-Host [-] "Resource test failed, user is not logged in."
                    Show-Notification -ToastTitle "Twingate Status" -ToastText "Have you forgotten to log in to Twingate?  Please log in to access the network."
                }
            } else {
                Write-Host [-] "Resource test failed, user is not logged in."
                Show-Notification -ToastTitle "Twingate Status" -ToastText "Have you forgotten to log in to Twingate?  Please log in to access the network."
            }
        }
    } else {
        Write-Host [-] "Invalid test method specified, exiting script."
        exit
    }
} else {
    Write-Host [+] "Twingate service is not running, exiting script."
    exit
}