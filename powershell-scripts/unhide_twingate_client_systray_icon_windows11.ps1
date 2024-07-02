<#
.SYNOPSIS
Unhides the Twingate Client Application icon.  Currently only tested on Windows 11 Pro.  Can be run via MDM after the Twingate Client Application has been installed.

.REFERENCES
Original script by @satnix - https://github.com/satnix/Windows11/blob/main/PermanentSystemTrayIcon.ps1
#>

# Main function
Function Search-RegistryKey {
    Param (
        [string]$Path
    )

    $results = @()

    # Get all subkeys
    $subkeys = Get-ChildItem -Path $Path

    # Iterate through each subkey
    foreach ($subkey in $subkeys) {
        $subkeyPath = $subkey.PSPath

        # Check if the subkey has an "ExecutablePath" value
        if (Test-Path $subkeyPath) {
            $key = Get-Item -LiteralPath $subkeyPath
            if ($key.GetValue("ExecutablePath")) {
                $executablePath = $key.GetValue("ExecutablePath")

                # Check if the executable path contains "twingate.exe"
                if ($executablePath -like "*twingate.exe") {
                    $results += [PSCustomObject]@{
                        "RegistryKey" = $subkeyPath
                        "ExecutablePath" = $executablePath
                    }
                    # Create the "IsPromoted" DWORD value with data "1"
                    Set-ItemProperty -Path $subkeyPath -Name "IsPromoted" -Value 1 -Type DWord
                }
            }
        }
    }
    return $results
}
# Search for the Twingate Client Application registry key
Search-RegistryKey "HKCU:\Control Panel\NotifyIconSettings"

# Output the results
foreach ($result in $results) {
    Write-Host "Registry Key: $($result.RegistryKey)"
    Write-Host "ExecutablePath: $($result.ExecutablePath)"
    Write-Host ""
}