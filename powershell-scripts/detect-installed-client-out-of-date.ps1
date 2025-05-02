# This script is designed to look at the local version of the Twingate client and to
# compare it to the last Windows version listed in the Client changelog RSS feed.

# Based on the two values matching or not, additional script could be triggered to
# remediate.

# Note: This script is provided as-is, and is intended to be used as a starting point for your own deployment scripts.
# It is meant to be run via Powershell 5.x on Windows 10 or 11, and parts may not function on other versions of Windows
# or Powershell.  It is recommended to test this script in a lab environment before deploying to production.

# Disable the WebRequest progress bar, speeds up downloads
$ProgressPreference = "SilentlyContinue"

# Step 1: Grab the Twingate RSS feed for the client changelog and parse it for the latest Windows client version
$twingateClientChangelogRSS = "https://www.twingate.com/changelog-clients.rss.xml"
$changeLogContent = Invoke-WebRequest -Uri $twingateClientChangelogRSS -UseBasicParsing
[xml]$RSS = $changeLogContent.Content

# Loop through the RSS feed items to find the latest Windows client version which should be the first match
foreach ($item in $RSS.rss.channel.item) {
    if ($item.link -match "windows") {
        $changeLogVersion = $item.link -replace ".*#windows-(\d+-\d+)-release.*",'$1'
        $changeLogVersion = $changeLogVersion -replace "-","."
        break
    }
}

# Step 2: Check the registry for a Twingate client installation version
# For this we're going to look for installations matching the Twingate product name
# and extract the version number from the product name

# Note: If for some reason there's more than one we may get the wrong result or an inaccurate one
# so it's best to run the uninstall first option on any remediation script.
$appPath = Get-ChildItem -Path "registry::HKEY_CLASSES_ROOT\Installer\Products"
foreach ($app in $appPath) {
    #Write-Output $app.GetValue("ProductName")
    if ($app.GetValue("ProductName") -match "Twingate") {
        $registryVersion = $app.GetValue("ProductName")
        $registryVersion = $registryVersion -replace ".*(\d{4}.\d{2}).*",'$1'
        break 
    }
}

# Display the versions in case you want to log them via transcript or other logging
Write-Output "RSS Changelog Version: $changeLogVersion"
Write-Output "Registry Version: $registryVersion"

# Step 3: Compare the two versions and alert if the client is out of date
if ($changeLogVersion -eq $registryVersion) {
    # Do nothing in this case, the versions match meaning the installed client is up to date
    Write-Output "Client is up to date"
    exit 0
} else {
    # If you're doing Intune remediation then this is where you'd exit code 1
    # and Intune would run the remediation script, if not then you can trigger
    # whatever code you want here
    Write-Output "Client is out of date"
    exit 1
} 