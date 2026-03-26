<#
.SYNOPSIS
    Removes all Hyper-V resources created by Deploy-TwingateConnector.ps1.

.DESCRIPTION
    Cleans up a failed or unwanted Twingate Connector deployment by removing:
      - All Hyper-V VMs matching TG-Connector-*
      - The TwingateExternalSwitch vSwitch (only if created by the deploy script)
      - All VM subdirectories under VMPath (TG-Connector-* folders)

    The Ubuntu cloud image cache (VMPath\images) and tools (VMPath\tools) are
    intentionally left behind so a subsequent Deploy run does not need to
    re-download them.

    Does NOT make any Twingate API calls. Any connector records in the Twingate
    Admin Console must be removed manually if needed.

.PARAMETER VMPath
    Root directory used by Deploy-TwingateConnector.ps1. Default: C:\TwingateConnectors.

.PARAMETER Force
    Skip the confirmation prompt and remove everything immediately.

.EXAMPLE
    .\Reset-TwingateConnectorEnvironment.ps1

    Shows what will be removed and prompts for confirmation.

.EXAMPLE
    .\Reset-TwingateConnectorEnvironment.ps1 -Force

    Removes everything without prompting.

.EXAMPLE
    .\Reset-TwingateConnectorEnvironment.ps1 -VMPath D:\VMs

    Cleans up a non-default deployment path.

.NOTES
    Author:  Twingate Solutions
    License: Apache 2.0
    Requires: PowerShell 5.1+, Hyper-V management tools, Run as Administrator
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMPath = 'C:\TwingateConnectors',

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Message,
        [Parameter()] [ValidateSet('Info', 'Warning', 'Error', 'Action')] [string]$Type = 'Info'
    )
    $prefix = switch ($Type) { 'Info' { '[+]' } 'Warning' { '[-]' } 'Error' { '[!]' } 'Action' { '[*]' } }
    $color  = switch ($Type) { 'Info' { 'Cyan' } 'Warning' { 'Yellow' } 'Error' { 'Red' } 'Action' { 'Green' } }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Admin check
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Status 'This script must be run as Administrator.' -Type Error
    exit 1
}

# -------------------------------------------------------------------------
# Discover what will be removed
# -------------------------------------------------------------------------

$vmsToRemove     = @(Get-VM -Name 'TG-Connector-*' -ErrorAction SilentlyContinue)
$switchToRemove  = Get-VMSwitch -Name 'TwingateExternalSwitch' -ErrorAction SilentlyContinue
$foldersToRemove = @()

if (Test-Path $VMPath) {
    $foldersToRemove = @(Get-ChildItem -Path $VMPath -Directory -Filter 'TG-Connector-*' -ErrorAction SilentlyContinue)
}

if ($vmsToRemove.Count -eq 0 -and $null -eq $switchToRemove -and $foldersToRemove.Count -eq 0) {
    Write-Status 'Nothing to clean up. No TG-Connector-* VMs, no TwingateExternalSwitch, no TG-Connector-* folders found.'
    exit 0
}

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------

Write-Host ''
Write-Status '--- The following will be permanently removed ---' -Type Warning
Write-Host ''

if ($vmsToRemove.Count -gt 0) {
    Write-Host '  Hyper-V VMs:' -ForegroundColor Yellow
    foreach ($vm in $vmsToRemove) {
        Write-Host "    - $($vm.Name)  [$($vm.State)]" -ForegroundColor Yellow
    }
}

if ($null -ne $switchToRemove) {
    Write-Host '  Virtual Switch:' -ForegroundColor Yellow
    Write-Host "    - TwingateExternalSwitch" -ForegroundColor Yellow
}

if ($foldersToRemove.Count -gt 0) {
    Write-Host '  Folders:' -ForegroundColor Yellow
    foreach ($folder in $foldersToRemove) {
        Write-Host "    - $($folder.FullName)" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Status 'The following will NOT be touched (cached downloads):' -Type Info
Write-Host "    $VMPath\images   (Ubuntu cloud image)" -ForegroundColor Cyan
Write-Host "    $VMPath\tools    (qemu-img.exe)" -ForegroundColor Cyan
Write-Host ''

# -------------------------------------------------------------------------
# Confirmation
# -------------------------------------------------------------------------

if (-not $Force) {
    $confirm = Read-Host 'Proceed with removal? (Y/N)'
    if ($confirm.Trim().ToUpper() -ne 'Y') {
        Write-Status 'Aborted. Nothing was removed.' -Type Warning
        exit 0
    }
}

# -------------------------------------------------------------------------
# Remove VMs
# -------------------------------------------------------------------------

foreach ($vm in $vmsToRemove) {
    if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Stop and Remove VM')) { continue }
    Write-Status "Removing VM: $($vm.Name)..." -Type Action
    try {
        if ($vm.State -ne 'Off') {
            Write-Status "  Stopping $($vm.Name)..."
            Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction SilentlyContinue
        }
        Remove-VM -Name $vm.Name -Force
        Write-Status "  Removed VM: $($vm.Name)"
    }
    catch {
        Write-Status "  Failed to remove VM '$($vm.Name)': $_" -Type Warning
    }
}

# -------------------------------------------------------------------------
# Remove vSwitch
# -------------------------------------------------------------------------

if ($null -ne $switchToRemove) {
    if ($PSCmdlet.ShouldProcess('TwingateExternalSwitch', 'Remove Virtual Switch')) {
        Write-Status 'Removing virtual switch: TwingateExternalSwitch...' -Type Action
        try {
            Remove-VMSwitch -Name 'TwingateExternalSwitch' -Force
            Write-Status '  Removed virtual switch.'
        }
        catch {
            Write-Status "  Failed to remove virtual switch: $_" -Type Warning
        }
    }
}

# -------------------------------------------------------------------------
# Remove VM folders
# -------------------------------------------------------------------------

foreach ($folder in $foldersToRemove) {
    if (-not $PSCmdlet.ShouldProcess($folder.FullName, 'Remove Folder')) { continue }
    Write-Status "Removing folder: $($folder.FullName)..." -Type Action
    try {
        Remove-Item -Path $folder.FullName -Recurse -Force
        Write-Status "  Removed: $($folder.FullName)"
    }
    catch {
        Write-Status "  Failed to remove folder '$($folder.FullName)': $_" -Type Warning
    }
}

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------

Write-Host ''
Write-Status 'Cleanup complete. You can now re-run Deploy-TwingateConnector.ps1.' -Type Action
