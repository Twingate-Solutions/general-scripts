<#
.SYNOPSIS
    Deploys and manages Twingate Connectors on Windows Server via Hyper-V.

.DESCRIPTION
    Automates the full lifecycle of Twingate Connectors running on Ubuntu 24.04 VMs
    in Hyper-V. Uses the Twingate GraphQL API for connector management and cloud-init
    (NoCloud ISO datasource) for zero-touch guest provisioning. No SSH during initial
    deployment. No external module dependencies.

    VMs are created as Generation 2 (UEFI, SCSI) with Secure Boot disabled.
    Requires Windows Server 2022/2025 with Hyper-V and administrator privileges.
    qemu-img.exe is downloaded automatically. No Windows ADK required.

.PARAMETER Action
    The lifecycle action to perform.
    - Deploy:           Create N connectors and their Hyper-V VMs end-to-end.
    - Remove:           Stop/delete VMs and their API connector records.
    - UpdateConnector:  SSH into each VM and apt-install the latest twingate-connector.
    - UpdateOS:         SSH into each VM and apt-upgrade the full OS.
    - List:             Display all TG-Connector-* VMs and their status.

.PARAMETER TwingateNetwork
    Your Twingate network slug (e.g., "acme" for acme.twingate.com).
    Prompted interactively if not provided.

.PARAMETER ApiToken
    Twingate API token with "Read, Write & Provision" scope.
    Prompted securely (no echo) if not provided.
    Accepts a plain string (-ApiToken "token") or a SecureString for better security:
    -ApiToken (ConvertTo-SecureString 'token-value' -AsPlainText -Force)

.PARAMETER RemoteNetwork
    Remote Network display name from the Twingate Admin Console (e.g., "Office").
    Required for Deploy and Remove. Prompted if not provided.

.PARAMETER ConnectorCount
    Number of connectors (and VMs) to create. Default: 2. Deploy only.

.PARAMETER VMPath
    Root directory for VM files, cached images, and tools. Default: C:\TwingateConnectors.

.PARAMETER VMCpu
    vCPUs per VM. Default: 1. Deploy only.

.PARAMETER VMMemory
    RAM per VM in bytes. Default: 2GB (2147483648). Deploy only.

.PARAMETER VSwitch
    Hyper-V external vSwitch name. Auto-detects an existing external switch if omitted.

.EXAMPLE
    .\Deploy-TwingateConnector.ps1 -Action Deploy -TwingateNetwork "acme" -RemoteNetwork "Office"

    Deploys 2 connectors (default) into the "Office" Remote Network on acme.twingate.com.
    Prompts for API token.

.EXAMPLE
    .\Deploy-TwingateConnector.ps1 -Action Deploy -TwingateNetwork "acme" -RemoteNetwork "Office" -ConnectorCount 4 -VMPath D:\VMs

    Deploys 4 connectors, storing VM files in D:\VMs.

.EXAMPLE
    .\Deploy-TwingateConnector.ps1 -Action List

    Lists all TG-Connector-* VMs and their Hyper-V status.

.EXAMPLE
    .\Deploy-TwingateConnector.ps1 -Action Remove -TwingateNetwork "acme" -RemoteNetwork "Office"

    Removes all connectors in the "Office" Remote Network and their VMs.

.EXAMPLE
    .\Deploy-TwingateConnector.ps1 -Action UpdateConnector -TwingateNetwork "acme"

    Updates the twingate-connector package on all running TG-Connector-* VMs.

.NOTES
    Author:  Twingate Solutions
    License: Apache 2.0
    Requires: PowerShell 5.1+, Windows Server 2022/2025, Hyper-V, Run as Administrator
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive console script. Write-Host is intentional for colored, prefixed console output.')]
[CmdletBinding(SupportsShouldProcess)]  # -WhatIf/-Confirm support; action handlers must call $PSCmdlet.ShouldProcess() for destructive ops
param(
    [Parameter(Mandatory)]
    [ValidateSet('Deploy', 'Remove', 'UpdateConnector', 'UpdateOS', 'List', 'FixVM')]
    [string]$Action,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TwingateNetwork,

    [Parameter()]
    [object]$ApiToken,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RemoteNetwork,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$ConnectorCount = 2,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMPath = 'C:\TwingateConnectors',

    [Parameter()]
    [ValidateRange(1, 32)]
    [int]$VMCpu = 1,

    [Parameter()]
    [ValidateRange(536870912, 34359738368)]  # 512 MiB to 32 GiB
    [long]$VMMemory = 2GB,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VSwitch,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Speeds up Invoke-WebRequest significantly

#region Helper Functions

# Tracks connector records orphaned by FixVM reprovision, surfaced at end of run.
$script:OrphanedConnectors = [System.Collections.Generic.List[object]]::new()

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Action')]
        [string]$Type = 'Info'
    )
    $prefix = switch ($Type) {
        'Info'    { '[+]' }
        'Warning' { '[-]' }
        'Error'   { '[!]' }
        'Action'  { '[*]' }
    }
    $color = switch ($Type) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Action'  { 'Green' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Read-SecurePrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [switch]$AsSecureString
    )
    if ($AsSecureString) {
        # Returns SecureString directly - caller must convert to plain text only at point of use
        return Read-Host -Prompt $Prompt -AsSecureString
    }
    else {
        # Non-secret inputs (e.g., network slug, Remote Network name) - plain string is fine
        return Read-Host -Prompt $Prompt
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Prerequisites {
    # Admin check
    if (-not (Test-IsAdministrator)) {
        Write-Status 'This script must be run as Administrator.' -Type Error
        throw 'This script must be run as Administrator.'
    }
    Write-Status 'Running as Administrator.'

    # OS check (must be Server - ProductType 1 = Workstation, 2 = Domain Controller, 3 = Server)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.ProductType -eq 1) {
        Write-Status 'This script targets Windows Server. Windows Desktop is not supported in v1.' -Type Error
        throw 'This script targets Windows Server. Windows Desktop is not supported in v1.'
    }
    Write-Status "OS: $($os.Caption)"

    # Hyper-V check
    $hvFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    if ($null -eq $hvFeature) {
        Write-Status 'Cannot query Windows Features. Ensure this is running on Windows Server.' -Type Error
        throw 'Cannot query Windows Features. Ensure this is running on Windows Server.'
    }
    if (-not $hvFeature.Installed) {
        Write-Status 'Hyper-V is not installed.' -Type Warning
        Install-HyperV
        return  # Install-HyperV always exits; this return makes the intent explicit
    }
    Write-Status 'Hyper-V is installed.'

    # ssh.exe check
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) {
        Write-Status 'ssh.exe not found. Enable OpenSSH Client in Windows Optional Features.' -Type Error
        throw 'ssh.exe not found. Enable OpenSSH Client in Windows Optional Features.'
    }
    Write-Status "ssh.exe found: $($ssh.Source)"

    # ssh-keygen.exe check
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if (-not $sshKeygen) {
        Write-Status 'ssh-keygen.exe not found. Enable OpenSSH Client in Windows Optional Features.' -Type Error
        throw 'ssh-keygen.exe not found. Enable OpenSSH Client in Windows Optional Features.'
    }
    Write-Status "ssh-keygen.exe found: $($sshKeygen.Source)"
}

function Install-HyperV {
    # Check CPU virtualization capability before attempting install
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    if (-not $cpu.VirtualizationFirmwareEnabled) {
        $inVm = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
        Write-Status 'Cannot install Hyper-V: CPU virtualization extensions are not available.' -Type Error
        if ($inVm) {
            Write-Status 'This machine is running inside a hypervisor with nested virtualization disabled.' -Type Error
            Write-Status 'Enable nested virtualization on the host before running this script.' -Type Info
            Write-Status 'For Hyper-V hosts, run this on the HOST machine (not inside the VM):' -Type Info
            Write-Status "  Set-VMProcessor -VMName '<this-vm-name>' -ExposeVirtualizationExtensions `$true" -Type Info
            Write-Status 'The VM must be powered off before running that command.' -Type Info
        }
        else {
            Write-Status 'Enable VT-x (Intel) or AMD-V (AMD) in the system BIOS/UEFI settings.' -Type Info
        }
        throw 'Cannot install Hyper-V: CPU virtualization extensions are not available.'
    }

    Write-Status 'Hyper-V is not installed. Install now? This requires a reboot.' -Type Warning
    $confirm = Read-Host 'Install Hyper-V? (Y/N)'
    if ($confirm.Trim().ToUpper() -ne 'Y') {
        Write-Status 'Hyper-V is required. Exiting.' -Type Error
        throw 'Hyper-V is required. Exiting.'
    }
    Write-Status 'Installing Hyper-V...' -Type Action
    try {
        Install-WindowsFeature -Name Hyper-V -IncludeManagementTools | Out-Null
    }
    catch {
        Write-Status "Hyper-V installation failed: $_" -Type Error
        Write-Status 'Common causes:' -Type Info
        Write-Status '  - Nested virtualization not enabled (if this is a VM)' -Type Info
        Write-Status '  - VT-x/AMD-V not enabled in BIOS/UEFI (if physical hardware)' -Type Info
        throw "Hyper-V installation failed: $_"
    }
    Write-Status 'Hyper-V installed. A reboot is required before running this script again.'
    Write-Status 'Save all open work, then press Enter to reboot.'
    Read-Host 'Press Enter to reboot' | Out-Null
    Restart-Computer -Force
    exit 0
}

function Resolve-QemuImgAssetUrl {
    [CmdletBinding()]
    param()
    $apiUrl = 'https://api.github.com/repos/fdcastel/qemu-img-windows-x64/releases/latest'
    try {
        # GitHub requires TLS 1.2 and a User-Agent header.
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'twingate-deploy-script'; 'Accept' = 'application/vnd.github+json' }
        $asset = $release.assets |
            Where-Object { $_.name -match '^qemu-img-windows-x64.*\.zip$' } |
            Select-Object -First 1
        if ($asset) { return $asset.browser_download_url }
        return $null
    }
    catch {
        Write-Status "Could not query GitHub API for qemu-img asset: $_" -Type Warning
        return $null
    }
}

function Install-QemuImg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolsPath
    )

    $exePath = Join-Path $ToolsPath 'qemu-img.exe'
    if (Test-Path $exePath) {
        Write-Status "qemu-img.exe found: $exePath"
        return $exePath
    }

    Write-Status 'qemu-img.exe not found. It is required to convert the Ubuntu cloud image to VHDX.' -Type Warning
    $confirm = Read-Host 'Download qemu-img.exe automatically? (Y/N)'
    if ($confirm.Trim().ToUpper() -ne 'Y') {
        Write-Status 'qemu-img.exe is required. Exiting.' -Type Error
        Write-Status "Manual download: https://github.com/fdcastel/qemu-img-windows-x64/releases" -Type Info
        Write-Status "Place qemu-img.exe in: $ToolsPath" -Type Info
        throw 'qemu-img.exe is required. Exiting.'
    }

    if (-not (Test-Path $ToolsPath)) {
        New-Item -ItemType Directory -Path $ToolsPath -Force | Out-Null
    }

    # Primary: resolve the current versioned asset from the GitHub API.
    $releaseUrl = Resolve-QemuImgAssetUrl
    $zipPath = Join-Path $ToolsPath 'qemu-img.zip'

    if (-not $releaseUrl) {
        Write-Status 'Could not resolve the latest qemu-img release; using fallback.' -Type Warning
    }

    try {
        if (-not $releaseUrl) { throw 'No primary qemu-img URL resolved.' }
        Write-Status "Downloading from: $releaseUrl" -Type Action
        Invoke-WebRequest -Uri $releaseUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $ToolsPath -Force
        Remove-Item $zipPath -Force

        # The zip may extract qemu-img.exe directly or inside a subfolder
        $found = Get-ChildItem -Path $ToolsPath -Filter 'qemu-img.exe' -Recurse | Select-Object -First 1
        if ($null -eq $found) {
            throw 'qemu-img.exe not found after extraction.'
        }
        if ($found.FullName -ne $exePath) {
            Move-Item $found.FullName $exePath -Force
        }
    }
    catch {
        Write-Status "Primary download failed: $_" -Type Warning
        Write-Status 'Trying fallback (Cloudbase qemu-img v2.3.0)...' -Type Action

        $fallbackUrl = 'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip'
        try {
            Invoke-WebRequest -Uri $fallbackUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $ToolsPath -Force
            Remove-Item $zipPath -Force

            $found = Get-ChildItem -Path $ToolsPath -Filter 'qemu-img.exe' -Recurse | Select-Object -First 1
            if ($null -eq $found) {
                throw 'qemu-img.exe not found after fallback extraction.'
            }
            if ($found.FullName -ne $exePath) {
                Move-Item $found.FullName $exePath -Force
            }
        }
        catch {
            Write-Status "Could not download qemu-img.exe. $_" -Type Error
            Write-Status "Manual download: https://github.com/fdcastel/qemu-img-windows-x64/releases" -Type Info
            Write-Status "Place qemu-img.exe in: $ToolsPath" -Type Info
            throw "Could not download qemu-img.exe. $_"
        }
    }

    Write-Status "qemu-img.exe ready: $exePath"
    return $exePath
}

function Get-OrCreateExternalSwitch {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PreferredName  # If provided, look for this specific switch first
    )

    # If caller specified a switch name, validate it exists
    if ($PreferredName) {
        $sw = Get-VMSwitch -Name $PreferredName -ErrorAction SilentlyContinue
        if ($sw -and $sw.SwitchType -eq 'External') {
            Write-Status "Using specified vSwitch: $($sw.Name)"
            return $sw.Name
        }
        Write-Status "Specified vSwitch '$PreferredName' not found or is not External type." -Type Warning
    }

    # Find any existing external switch
    $existing = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        Write-Status "Using existing external vSwitch: $($existing.Name)"
        return $existing.Name
    }

    # No external switch - create one
    Write-Status 'No external vSwitch found. Creating one...' -Type Action
    $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
    if ($null -eq $adapters -or @($adapters).Count -eq 0) {
        Write-Status 'No physical network adapters with link-up status found. Cannot create external vSwitch.' -Type Error
        throw 'No physical network adapters with link-up status found. Cannot create external vSwitch.'
    }

    $selected = $null
    if (@($adapters).Count -eq 1) {
        $selected = $adapters
        Write-Status "Using adapter: $($selected.Name) ($($selected.InterfaceDescription))"
    }
    else {
        Write-Status 'Multiple physical adapters found:'
        $i = 0
        foreach ($a in $adapters) {
            Write-Host "  [$i] $($a.Name) - $($a.InterfaceDescription)"
            $i++
        }
        $choice = Read-Host 'Enter the number of the adapter to use for the external vSwitch'
        $idx = 0
        if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 0 -or $idx -ge @($adapters).Count) {
            Write-Status 'Invalid selection.' -Type Error
            throw 'Invalid selection.'
        }
        $selected = @($adapters)[$idx]
    }

    $switchName = 'TwingateExternalSwitch'
    Write-Status "Creating vSwitch '$switchName' on adapter '$($selected.Name)'..." -Type Action
    New-VMSwitch -Name $switchName -NetAdapterName $selected.Name -AllowManagementOS $true | Out-Null
    Write-Status "vSwitch '$switchName' created."
    return $switchName
}

function ConvertFrom-SecureStringToPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SecureString]$SecureString
    )
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
    }
}

function Invoke-TwingateApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Network,
        [Parameter(Mandatory)]
        [SecureString]$Token,
        [Parameter(Mandatory)]
        [string]$Query,
        [Parameter()]
        [hashtable]$Variables = @{}
    )

    $uri         = "https://$Network.twingate.com/api/graphql/"
    $plainToken  = ConvertFrom-SecureStringToPlainText -SecureString $Token
    $body        = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 10 -Compress
    $headers     = @{ 'X-API-KEY' = $plainToken; 'Content-Type' = 'application/json' }

    $attempt    = 0
    $maxAttempts = 4
    $baseDelay   = 2

    try {
        while ($attempt -lt $maxAttempts) {
            $attempt++
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -UseBasicParsing
                if ($response.PSObject.Properties['errors'] -and $response.errors) {
                    $msg = ($response.errors | ForEach-Object { $_.message }) -join '; '
                    throw "Twingate API GraphQL error: $msg"
                }
                return $response.data
            }
            catch {
                $statusCode = 0
                if ($_.Exception -is [System.Net.WebException] -and $null -ne $_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                if ($statusCode -eq 401 -or $statusCode -eq 403) {
                    Write-Status "API token is invalid or lacks required permissions (HTTP $statusCode)." -Type Error
                    throw "API token is invalid or lacks required permissions (HTTP $statusCode)."
                }
                if ($statusCode -eq 0 -and ($_.Exception.Message -match 'Unable to connect|name.*could not be resolved')) {
                    Write-Status "Cannot reach Twingate API at $uri. Check your TwingateNetwork slug and network connectivity." -Type Error
                    throw "Cannot reach Twingate API at $uri. Check your TwingateNetwork slug and network connectivity."
                }
                if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt $maxAttempts) {
                    $jitter = (Get-Random -Maximum 1000) / 1000
                    $delay  = $baseDelay * [Math]::Pow(2, $attempt - 1) + $jitter
                    Write-Status "API returned HTTP $statusCode. Retrying in $([Math]::Round($delay, 1))s (attempt $attempt/$maxAttempts)..." -Type Warning
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw $_
            }
        }
        throw "Twingate API: max retry attempts ($maxAttempts) exceeded."
    }
    finally {
        # Best-effort cleanup: remove references to the plain-text token from memory
        if ($headers -and $headers.ContainsKey('X-API-KEY')) { $headers['X-API-KEY'] = $null }
        Remove-Variable -Name plainToken -ErrorAction SilentlyContinue
    }
}

function Get-TwingateRemoteNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$Name
    )

    $query = @'
query RemoteNetworkByName($name: String!) {
  remoteNetwork(name: $name) {
    id
    name
    isActive
  }
}
'@
    $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $query -Variables @{ name = $Name }
    if ($null -eq $data.remoteNetwork) {
        Write-Status "Remote Network '$Name' not found. Check the name in your Twingate Admin Console." -Type Error
        throw "Remote Network '$Name' not found. Check the name in your Twingate Admin Console."
    }
    Write-Status "Found Remote Network: $($data.remoteNetwork.name) (ID: $($data.remoteNetwork.id))"
    return $data.remoteNetwork.id
}

function New-TwingateConnector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$RemoteNetworkId,
        [Parameter(Mandatory)] [string]$ConnectorName
    )

    $mutation = @'
mutation ConnectorCreate($remoteNetworkId: ID!, $name: String!, $hasStatusNotificationsEnabled: Boolean) {
  connectorCreate(
    remoteNetworkId: $remoteNetworkId
    name: $name
    hasStatusNotificationsEnabled: $hasStatusNotificationsEnabled
  ) {
    ok
    error
    entity {
      id
      name
    }
  }
}
'@
    $vars = @{
        remoteNetworkId               = $RemoteNetworkId
        name                          = $ConnectorName
        hasStatusNotificationsEnabled = $true
    }
    $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $mutation -Variables $vars
    if (-not $data.connectorCreate.ok) {
        throw "connectorCreate failed: $($data.connectorCreate.error)"
    }
    Write-Status "Created connector: $($data.connectorCreate.entity.name) (ID: $($data.connectorCreate.entity.id))"
    return $data.connectorCreate.entity.id
}

function New-TwingateConnectorTokens {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$ConnectorId
    )

    $mutation = @'
mutation ConnectorGenerateTokens($connectorId: ID!) {
  connectorGenerateTokens(connectorId: $connectorId) {
    ok
    error
    connectorTokens {
      accessToken
      refreshToken
    }
  }
}
'@
    $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $mutation -Variables @{ connectorId = $ConnectorId }
    if (-not $data.connectorGenerateTokens.ok) {
        throw "connectorGenerateTokens failed: $($data.connectorGenerateTokens.error)"
    }
    # CRITICAL: tokens returned only once - caller must use immediately
    return @{
        AccessToken  = $data.connectorGenerateTokens.connectorTokens.accessToken
        RefreshToken = $data.connectorGenerateTokens.connectorTokens.refreshToken
    }
}

function Get-TwingateConnectorStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$ConnectorId
    )

    $query = @'
query ConnectorStatus($id: ID!) {
  connector(id: $id) {
    id
    name
    state
    lastHeartbeatAt
    version
  }
}
'@
    $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $query -Variables @{ id = $ConnectorId }
    if ($null -eq $data.connector) {
        return $null
    }
    return $data.connector.state
}

function Remove-TwingateConnector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$ConnectorId
    )

    $mutation = @'
mutation ConnectorDelete($id: ID!) {
  connectorDelete(id: $id) {
    ok
    error
  }
}
'@
    try {
        $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $mutation -Variables @{ id = $ConnectorId }
        if (-not $data.connectorDelete.ok) {
            Write-Status "connectorDelete API call failed for $ConnectorId`: $($data.connectorDelete.error). Manual cleanup may be needed in the Admin Console." -Type Warning
            return $false
        }
        Write-Status "Deleted connector $ConnectorId from Twingate."
        return $true
    }
    catch {
        Write-Status "Exception deleting connector $ConnectorId`: $_. Manual cleanup may be needed in the Admin Console." -Type Warning
        return $false
    }
}

function Wait-ConnectorOnline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$ConnectorId,
        [Parameter(Mandatory)] [string]$ConnectorName,
        [Parameter()] [int]$TimeoutSeconds = 300,
        [Parameter()] [int]$PollIntervalSeconds = 15
    )

    Write-Status "Waiting for connector '$ConnectorName' to come online (timeout: ${TimeoutSeconds}s)..." -Type Action
    $startTime = Get-Date
    $deadline  = $startTime.AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $state = Get-TwingateConnectorStatus -Network $Network -Token $Token -ConnectorId $ConnectorId
        Write-Status "  $ConnectorName state: $state (${elapsed}s elapsed)"

        if ($state -eq 'ALIVE') {
            Write-Status "$ConnectorName is ALIVE." -Type Action
            return $true
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Status "Timeout waiting for '$ConnectorName' to come online." -Type Warning
    Write-Status 'Troubleshooting: open the VM console in Hyper-V Manager and check cloud-init logs:' -Type Info
    Write-Status '  sudo journalctl -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final' -Type Info
    return $false
}

function Get-FixVMPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool]$IsAlive,
        [Parameter(Mandatory)] [bool]$PackageInstalled
    )
    if ($IsAlive)          { return 'none' }
    if ($PackageInstalled) { return 'start' }
    return 'reprovision'
}

function Get-SshErrorHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Output)
    switch -Regex ($Output) {
        'Unable to locate package twingate-connector' {
            return 'Twingate apt repo missing - the connector was never bootstrapped. Repair with: -Action FixVM -VMName <name>'
        }
        'Temporary failure in name resolution|Could not resolve host' {
            return 'DNS resolution failed inside the VM. Check the VM network/DNS, then retry.'
        }
        'Connection timed out|Connection refused|Permission denied' {
            return 'SSH/network connectivity problem reaching the VM. Confirm the VM is running and reachable.'
        }
        default { return $null }
    }
}

function Write-OrphanCallout {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param()
    if ($script:OrphanedConnectors.Count -eq 0) { return }
    Write-Host ''
    Write-Status '================ ACTION REQUIRED ================' -Type Error
    Write-Status 'FixVM created net-new connector(s). The OLD connector record(s) below are now orphaned' -Type Error
    Write-Status 'and should be reviewed/removed in the Twingate Admin Console (Remote Network > Connectors):' -Type Error
    foreach ($o in $script:OrphanedConnectors) {
        Write-Status "  - $($o.VMName): old ConnectorId $($o.OldConnectorId)" -Type Warning
    }
    Write-Status '=================================================' -Type Error
}

function Get-ConnectorRemoteNetworkId {
    [CmdletBinding()]
    param([Parameter()] [string]$ConnectorId)
    if (-not $ConnectorId) {
        Write-Status 'No existing ConnectorId on this VM; cannot infer Remote Network for reprovision.' -Type Error
        throw 'Cannot determine Remote Network for reprovision.'
    }
    $query = @'
query ConnectorRemoteNetwork($id: ID!) {
  connector(id: $id) {
    remoteNetwork { id }
  }
}
'@
    $data = Invoke-TwingateApi -Network $TwingateNetwork -Token $ApiToken -Query $query -Variables @{ id = $ConnectorId }
    if ($null -eq $data.connector -or $null -eq $data.connector.remoteNetwork) {
        throw "Could not resolve Remote Network for connector $ConnectorId."
    }
    return $data.connector.remoteNetwork.id
}

function Get-TwingateRemoteNetworkConnectors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Network,
        [Parameter(Mandatory)] [SecureString]$Token,
        [Parameter(Mandatory)] [string]$RemoteNetworkId
    )

    $query = @'
query RemoteNetworkConnectors($id: ID!) {
  remoteNetwork(id: $id) {
    connectors {
      edges {
        node {
          id
          name
          state
        }
      }
    }
  }
}
'@
    $data = Invoke-TwingateApi -Network $Network -Token $Token -Query $query -Variables @{ id = $RemoteNetworkId }
    if ($null -eq $data.remoteNetwork -or $null -eq $data.remoteNetwork.connectors) {
        return @()
    }
    return $data.remoteNetwork.connectors.edges | ForEach-Object { $_.node }
}

function Get-UbuntuCloudImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImagesPath
    )

    if (-not (Test-Path $ImagesPath)) {
        New-Item -ItemType Directory -Path $ImagesPath -Force | Out-Null
    }

    $imgName = 'noble-server-cloudimg-amd64.img'
    $imgPath = Join-Path $ImagesPath $imgName
    $baseUrl = 'https://cloud-images.ubuntu.com/noble/current'
    $imgUrl  = "$baseUrl/$imgName"
    $sumsUrl = "$baseUrl/SHA256SUMS"

    if (-not (Test-Path $imgPath)) {
        Write-Status "Downloading Ubuntu 24.04 (Noble) cloud image (~600 MB)..." -Type Action
        Write-Status "Source: $imgUrl"
        try {
            Invoke-WebRequest -Uri $imgUrl -OutFile $imgPath -UseBasicParsing
        }
        catch {
            Write-Status "Failed to download Ubuntu cloud image: $_" -Type Error
            Write-Status "Manual download URL: $imgUrl" -Type Info
            Write-Status "Place the file at: $imgPath" -Type Info
            throw "Failed to download Ubuntu cloud image: $_"
        }
        Write-Status 'Download complete. Verifying SHA256...' -Type Action
    }
    else {
        Write-Status "Cached Ubuntu image found: $imgPath"
        Write-Status 'Verifying SHA256...' -Type Action
    }

    # Download and parse SHA256SUMS for verification
    try {
        $sumsContent = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
    }
    catch {
        Write-Status "Could not download SHA256SUMS for verification. Skipping hash check." -Type Warning
        return $imgPath
    }

    $expectedHash = $null
    foreach ($line in ($sumsContent -split "`n")) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ge 2 -and ($parts[1] -eq "*$imgName" -or $parts[1] -eq $imgName)) {
            $expectedHash = $parts[0].ToUpper()
            break
        }
    }

    if ($null -eq $expectedHash) {
        Write-Status "Could not find $imgName in SHA256SUMS. Skipping hash check." -Type Warning
        return $imgPath
    }

    $actualHash = (Get-FileHash -Path $imgPath -Algorithm SHA256).Hash.ToUpper()
    if ($actualHash -ne $expectedHash) {
        Write-Status "SHA256 mismatch for $imgName!" -Type Error
        Write-Status "  Expected: $expectedHash" -Type Error
        Write-Status "  Actual:   $actualHash" -Type Error
        Remove-Item $imgPath -Force
        Write-Status 'Corrupt file removed. Re-run to download again.' -Type Info
        throw "SHA256 mismatch for $imgName. Corrupt file removed. Re-run to download again."
    }

    Write-Status "SHA256 verified: $imgName"
    return $imgPath
}

function Convert-CloudImageToVhdx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$QemuImgExe,
        [Parameter(Mandatory)] [string]$SourceImg,
        [Parameter(Mandatory)] [string]$ImagesPath
    )

    $vhdxPath = Join-Path $ImagesPath 'ubuntu-24.04-base.vhdx'

    if (Test-Path $vhdxPath) {
        Write-Status "Cached base VHDX found: $vhdxPath"
        return $vhdxPath
    }

    Write-Status 'Converting qcow2 image to VHDX (this may take a few minutes)...' -Type Action
    $convertArgs = @('convert', '-f', 'qcow2', '-O', 'vhdx', '-o', 'subformat=dynamic', $SourceImg, $vhdxPath)

    & $QemuImgExe @convertArgs 2>&1 | ForEach-Object { Write-Status "  qemu-img: $_" }

    if ($LASTEXITCODE -ne 0) {
        Write-Status "qemu-img conversion failed (exit code $LASTEXITCODE)." -Type Error
        if (Test-Path $vhdxPath) { Remove-Item $vhdxPath -Force }
        throw "qemu-img conversion failed (exit code $LASTEXITCODE)."
    }

    Write-Status "Base VHDX created: $vhdxPath"
    return $vhdxPath
}

function New-SshKeyPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmDir
    )

    $keyPath    = Join-Path $VmDir 'ssh_key'
    $pubKeyPath = "$keyPath.pub"

    if (-not (Test-Path $keyPath)) {
        Write-Status 'Generating Ed25519 SSH keypair...' -Type Action
        # PowerShell 5.1 drops '' (empty string) when splatting to native executables,
        # causing -N to consume the next flag as its value. Route through cmd.exe /c so
        # that "" is parsed as an empty string by the Windows C runtime as expected.
        # -C overrides the default user@hostname comment so the public key is host-independent.
        $cmdLine = "ssh-keygen.exe -t ed25519 -f `"$keyPath`" -N `"`" -C twingate-connector -q"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $keygenOutput = & cmd.exe /c $cmdLine 2>&1
        $keygenExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($keygenExit -ne 0) {
            $keygenDetail = ($keygenOutput | Out-String).Trim()
            Write-Status "ssh-keygen failed (exit code $keygenExit): $keygenDetail" -Type Error
            throw "ssh-keygen failed (exit code $keygenExit): $keygenDetail"
        }
    }
    else {
        Write-Status "SSH keypair already exists: $keyPath"
    }

    # Restrict private key to owner read-only
    try {
        $acl = Get-Acl $keyPath
        $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance, remove inherited rules
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, 'Read', 'Allow'
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl
    }
    catch {
        Write-Status "Could not restrict SSH key permissions: $_. Continuing." -Type Warning
    }

    $publicKey = (Get-Content $pubKeyPath -Raw).Trim()
    Write-Status "SSH keypair ready: $keyPath"
    return @{
        PrivateKeyPath = $keyPath
        PublicKeyPath  = $pubKeyPath
        PublicKey      = $publicKey
    }
}

function Get-ConnectorBootstrapScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$RefreshToken,
        [Parameter(Mandatory)] [string]$TwingateNetwork,
        [Parameter()] [ValidateRange(1, 10)] [int]$MaxAttempts = 5,
        [Parameter()] [string]$DeployedByLabel = 'hyperv-deploy-script-v2'
    )

    # NOTE: PowerShell interpolates $var in @"..."@ here-strings. Every bash
    # variable reference is escaped as `$ so it survives to the guest verbatim.
    $bash = @"
#!/bin/bash
# Twingate connector bootstrap with bounded retry.
# Generated by Deploy-TwingateConnector.ps1 - do not edit on the host.
set -u

TG_ACCESS_TOKEN='$AccessToken'
TG_REFRESH_TOKEN='$RefreshToken'
TG_NETWORK='$TwingateNetwork'
TG_MAX_ATTEMPTS=$MaxAttempts
TG_LABEL='$DeployedByLabel'

log() { echo "[twingate-bootstrap] `$1"; }

install_once() {
  curl -fsSL 'https://binaries.twingate.com/connector/setup.sh' -o /tmp/twingate-setup.sh || return 1
  TWINGATE_ACCESS_TOKEN="`$TG_ACCESS_TOKEN" \
  TWINGATE_REFRESH_TOKEN="`$TG_REFRESH_TOKEN" \
  TWINGATE_NETWORK="`$TG_NETWORK" \
  bash /tmp/twingate-setup.sh || return 1
  return 0
}

connector_installed() {
  dpkg -s twingate-connector >/dev/null 2>&1
}

attempt=1
while [ "`$attempt" -le "`$TG_MAX_ATTEMPTS" ]; do
  log "install attempt `$attempt of `$TG_MAX_ATTEMPTS"
  install_once
  if connector_installed; then
    log "connector package present after attempt `$attempt"
    break
  fi
  if [ "`$attempt" -eq "`$TG_MAX_ATTEMPTS" ]; then
    log "ERROR: connector not installed after `$TG_MAX_ATTEMPTS attempts; giving up"
    exit 1
  fi
  backoff=`$(( 10 * (2 ** (attempt - 1)) ))
  if [ "`$backoff" -gt 60 ]; then backoff=60; fi
  log "attempt `$attempt failed; retrying in `${backoff}s"
  sleep "`$backoff"
  attempt=`$(( attempt + 1 ))
done

systemctl enable twingate-connector
systemctl start twingate-connector
echo "TWINGATE_LABEL_DEPLOYED_BY=`$TG_LABEL" >> /etc/twingate/connector.conf
systemctl restart twingate-connector
log "bootstrap complete"
"@

    return ($bash -replace "`r`n", "`n")
}

function New-CloudInitUserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$SshPublicKey,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$RefreshToken,
        [Parameter(Mandatory)] [string]$TwingateNetwork
    )

    # Generate a random admin username and password for the VM
    $chars    = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $suffix   = -join ((1..4) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    $username = "tgadm$suffix"
    $pwChars  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $password = -join ((1..24) | ForEach-Object { $pwChars[(Get-Random -Maximum $pwChars.Length)] })
    $hostname = ($VmName.ToLower() -replace '[^a-z0-9-]', '-').TrimEnd('-')

    $bootstrap = Get-ConnectorBootstrapScript -AccessToken $AccessToken `
        -RefreshToken $RefreshToken -TwingateNetwork $TwingateNetwork
    # Indent every line by 6 spaces to sit under the YAML "content: |" block.
    $bootstrapIndented = ($bootstrap -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"

    $userdata = @"
#cloud-config

hostname: $hostname
manage_etc_hosts: true

# ssh_authorized_keys at top level injects into the default user (ubuntu)
# without relying on the users module
ssh_authorized_keys:
  - $SshPublicKey

chpasswd:
  users:
    - name: ubuntu
      password: '*'
      type: text
  expire: false

write_files:
  - path: /etc/initramfs-tools/modules
    content: |
      hv_vmbus
      hv_storvsc
      hv_blkvsc
      hv_netvsc
    append: true
  - path: /var/lib/twingate-bootstrap.sh
    permissions: '0700'
    content: |
$bootstrapIndented

package_update: true
package_upgrade: true

packages:
  - curl
  - unattended-upgrades
  - apt-transport-https

runcmd:
  - useradd -m -s /bin/bash -G sudo $username || true
  - echo '${username}:${password}' | chpasswd
  - echo '$username ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$username
  - mkdir -p /home/$username/.ssh
  - echo '$SshPublicKey' >> /home/$username/.ssh/authorized_keys
  - chmod 700 /home/$username/.ssh
  - chmod 600 /home/$username/.ssh/authorized_keys
  - chown -R ${username}:${username} /home/$username/.ssh
  - bash /var/lib/twingate-bootstrap.sh
  - DEBIAN_FRONTEND=noninteractive apt-get install -y linux-virtual linux-cloud-tools-virtual linux-tools-virtual
  - update-initramfs -u

apt:
  conf: |
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Unattended-Upgrade "1";
    APT::Periodic::AutocleanInterval "7";

ssh_pwauth: false

power_state:
  mode: reboot
  condition: true
  timeout: 30
  message: "Cloud-init complete, rebooting"
"@

    # Normalize to LF-only line endings - PowerShell heredocs produce CRLF on Windows.
    # CRLF in the chpasswd list block embeds \r in the password string, causing silent failure.
    $userdata = $userdata -replace "`r`n", "`n"

    return @{
        UserData = $userdata
        Username = $username
        Password = $password
    }
}

function New-CloudInitIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VmDir,
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$UserData,
        [Parameter(Mandatory)] [string]$Username
    )

    $isoPath = Join-Path $VmDir 'cloud-init.iso'
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cloud-init-$VmName-$(Get-Random)"

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $hostname = ($VmName.ToLower() -replace '[^a-z0-9-]', '-').TrimEnd('-')

        $metaData = "instance-id: $VmName`nlocal-hostname: $hostname`n"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $tempDir 'meta-data'), $metaData, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $tempDir 'user-data'), $UserData, $utf8NoBom)

        Write-Status "Creating cloud-init ISO (IMAPI2FS): $isoPath" -Type Action

        # Use the Windows-native IMAPI2FS COM object to create an ISO 9660 disc.
        # This avoids oscdimg entirely and lets us set the volume label to exactly
        # 'cidata' (lowercase) as required by cloud-init's NoCloud datasource blkid check.
        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $image.VolumeName = 'cidata'
        $image.FileSystemsToCreate = 3  # FsiFileSystemISO9660 (1) | FsiFileSystemJoliet (2)
        # Joliet preserves lowercase filenames with hyphens (meta-data, user-data).
        # Pure ISO9660 Level 1 mangles them to 8.3 uppercase, which cloud-init cannot find.
        # The cidata volume label lives in the ISO9660 PVD and is unaffected by Joliet.

        # AddTree($path, $false) adds the CONTENTS of $tempDir to the ISO root,
        # so meta-data and user-data land at / inside the ISO.
        $image.Root.AddTree($tempDir, $false)

        $result      = $image.CreateResultImage()
        $blockSize   = $result.BlockSize
        $totalBlocks = $result.TotalBlocks

        # PowerShell cannot cast System.__ComObject to ComTypes.IStream directly - that cast
        # requires C# RCW infrastructure. Define a one-shot C# helper via Add-Type that accepts
        # the raw COM object as [object], performs the cast internally, and writes to a file.
        if (-not ([System.Management.Automation.PSTypeName]'Twingate.IStreamHelper').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace Twingate {
    public static class IStreamHelper {
        public static void WriteToFile(object comIStream, string path, int blockSize, int totalBlocks) {
            IStream stream = (IStream)comIStream;
            byte[]  buf    = new byte[blockSize];
            IntPtr  cbPtr  = Marshal.AllocHGlobal(4);
            try {
                using (var fs = File.Create(path)) {
                    for (int i = 0; i < totalBlocks; i++) {
                        stream.Read(buf, blockSize, cbPtr);
                        int cb = Marshal.ReadInt32(cbPtr);
                        fs.Write(buf, 0, cb);
                    }
                }
            } finally {
                Marshal.FreeHGlobal(cbPtr);
            }
        }
    }
}
'@
        }
        [Twingate.IStreamHelper]::WriteToFile($result.ImageStream, $isoPath, $blockSize, $totalBlocks)

        Write-Status "cloud-init ISO created: $isoPath ($totalBlocks blocks, label: cidata)"
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
    }

    # Store username for day-2 SSH operations
    [System.IO.File]::WriteAllText((Join-Path $VmDir 'ssh_user.txt'), $Username, [System.Text.Encoding]::UTF8)

    return $isoPath
}

function New-ConnectorVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$VmDir,
        [Parameter(Mandatory)] [string]$BaseVhdxPath,
        [Parameter(Mandatory)] [string]$CloudInitIso,
        [Parameter(Mandatory)] [string]$SwitchName,
        [Parameter(Mandatory)] [string]$ConnectorId,
        [Parameter(Mandatory)] [string]$SshUsername,
        [Parameter()] [int]$CpuCount = 1,
        [Parameter()] [long]$MemoryBytes = 2GB
    )

    # Check if VM already exists
    $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Status "VM '$VmName' already exists. Skipping creation." -Type Warning
        return $false
    }

    # Copy base VHDX and resize to 20GB
    $diskPath = Join-Path $VmDir 'disk.vhdx'
    Write-Status "Copying base VHDX to $diskPath..." -Type Action
    Copy-Item -Path $BaseVhdxPath -Destination $diskPath -Force
    Resize-VHD -Path $diskPath -SizeBytes 20GB

    # Create Gen2 (UEFI) VM without a disk - we attach below for explicit SCSI placement
    Write-Status "Creating VM '$VmName' (Gen2)..." -Type Action
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes `
        -SwitchName $SwitchName | Out-Null

    # Configure VM
    Set-VM -Name $VmName -ProcessorCount $CpuCount `
        -AutomaticStartAction Start -AutomaticStopAction ShutDown

    # Disable dynamic memory (static RAM for cloud images)
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes

    # Attach OS disk on SCSI Controller 0, Location 0
    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI `
        -ControllerNumber 0 -ControllerLocation 0 -Path $diskPath

    # Attach cloud-init ISO on SCSI Controller 0, Location 1
    # Gen2 SCSI is reliable for block-device discovery by cloud-init's ds-identify.
    Add-VMDvdDrive -VMName $VmName -ControllerNumber 0 -ControllerLocation 1 -Path $CloudInitIso

    # Gen2 firmware: disable Secure Boot so Ubuntu cloud images boot without key enrollment,
    # then set the hard disk as the first boot device.
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    $bootDisk = Get-VMHardDiskDrive -VMName $VmName -ControllerNumber 0 -ControllerLocation 0
    Set-VMFirmware -VMName $VmName -FirstBootDevice $bootDisk

    # Store metadata in VM Notes for discovery by later actions
    $notes = "TwingateConnectorId=$ConnectorId;SshUser=$SshUsername"
    Set-VM -Name $VmName -Notes $notes

    # Enable Guest Service Interface so the host can query the VM's IP address
    # via the Hyper-V Key-Value Pair Exchange channel (hv_kvp_daemon inside the guest).
    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'

    Write-Status "VM '$VmName' created (Gen2, Secure Boot off, Guest Services on)."
    return $true
}

function Resolve-SingleConnectorVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$VMPath
    )
    if ($VMName -notlike 'TG-Connector-*') {
        Write-Status "VM name '$VMName' does not match the TG-Connector-* convention." -Type Error
        return $null
    }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        Write-Status "VM '$VMName' not found." -Type Warning
        return $null
    }
    $sshUser = $null; $connectorId = $null
    foreach ($part in ($vm.Notes -split ';')) {
        if ($part -match '^TwingateConnectorId=(.+)$') { $connectorId = $Matches[1] }
        if ($part -match '^SshUser=(.+)$')             { $sshUser     = $Matches[1] }
    }
    if (-not $sshUser) {
        $userFile = Join-Path (Join-Path $VMPath $VMName) 'ssh_user.txt'
        if (Test-Path $userFile) { $sshUser = (Get-Content $userFile -Raw).Trim() }
    }
    return @{ VM = $vm; ConnectorId = $connectorId; SshUser = $sshUser }
}

function Get-VmSshDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VmName,
        [Parameter(Mandatory)] [string]$VMPath,
        [Parameter()] [int]$TimeoutSeconds = 120
    )

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        Write-Status "VM '$VmName' not found." -Type Error
        return $null
    }

    # Parse Notes field for SshUser and ConnectorId
    $sshUser     = $null
    $connectorId = $null
    foreach ($part in ($vm.Notes -split ';')) {
        if ($part -match '^TwingateConnectorId=(.+)$') { $connectorId = $Matches[1] }
        if ($part -match '^SshUser=(.+)$')             { $sshUser    = $Matches[1] }
    }

    # Fallback: read ssh_user.txt from VM directory
    if (-not $sshUser) {
        $userFile = Join-Path (Join-Path $VMPath $VmName) 'ssh_user.txt'
        if (Test-Path $userFile) {
            $sshUser = (Get-Content $userFile -Raw).Trim()
        }
    }

    if (-not $sshUser) {
        Write-Status "Cannot determine SSH username for VM '$VmName'." -Type Warning
        return $null
    }

    # Poll for IPv4 address
    Write-Status "Waiting for IP address on '$VmName'..." -Type Action
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $ipAddress = $null

    while ((Get-Date) -lt $deadline) {
        $adapter   = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
        $ipAddress = $adapter.IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
            Select-Object -First 1
        if ($ipAddress) { break }
        Start-Sleep -Seconds 5
    }

    if (-not $ipAddress) {
        Write-Status "No IPv4 address found for VM '$VmName' after ${TimeoutSeconds}s." -Type Warning
        return $null
    }

    $keyPath = Join-Path (Join-Path $VMPath $VmName) 'ssh_key'
    return @{
        IpAddress   = $ipAddress
        Username    = $sshUser
        PrivateKey  = $keyPath
        ConnectorId = $connectorId
    }
}

function Invoke-SshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$IpAddress,
        [Parameter(Mandatory)] [string]$Username,
        [Parameter(Mandatory)] [string]$PrivateKeyPath,
        [Parameter(Mandatory)] [string]$Command,
        [Parameter()] [int]$ConnectTimeout = 30
    )

    $sshArgs = @(
        '-i', $PrivateKeyPath,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', "ConnectTimeout=$ConnectTimeout",
        '-o', 'BatchMode=yes',
        "$Username@$IpAddress",
        $Command
    )

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output   = & ssh.exe @sshArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($exitCode -ne 0) {
        Write-Status "SSH command failed (exit $exitCode): $Command" -Type Warning
        Write-Status "Output: $($output -join ' ')" -Type Warning
        return @{ Success = $false; Output = $output; ExitCode = $exitCode }
    }
    return @{ Success = $true; Output = $output; ExitCode = 0 }
}

function Resolve-InteractiveParams {
    [CmdletBinding()]
    param(
        [switch]$RequireNetwork,
        [switch]$RequireToken,
        [switch]$RequireRemoteNetwork,
        [switch]$RequireVMName
    )

    if ($RequireNetwork -and -not $script:TwingateNetwork) {
        $script:TwingateNetwork = Read-SecurePrompt -Prompt 'Enter your Twingate network slug (e.g., "acme" for acme.twingate.com)'
    }
    if ($RequireToken -and -not $script:ApiToken) {
        $script:ApiToken = Read-SecurePrompt -Prompt 'Enter your Twingate API token' -AsSecureString
    }
    if ($script:ApiToken -is [string]) {
        Write-Status 'ApiToken was provided as a plain string - converting to SecureString.' -Type Warning
        Write-Status 'For better security you can pass it as: -ApiToken (ConvertTo-SecureString "token" -AsPlainText -Force)' -Type Warning
        $script:ApiToken = ConvertTo-SecureString $script:ApiToken -AsPlainText -Force
    }
    if ($RequireToken -and $script:ApiToken -isnot [SecureString]) {
        Write-Status 'ApiToken must be a SecureString or a plain string. Use -ApiToken (ConvertTo-SecureString "token" -AsPlainText -Force).' -Type Error
        throw 'ApiToken must be a SecureString or a plain string. Use -ApiToken (ConvertTo-SecureString "token" -AsPlainText -Force).'
    }
    if ($RequireRemoteNetwork -and -not $script:RemoteNetwork) {
        $script:RemoteNetwork = Read-SecurePrompt -Prompt 'Enter the Remote Network name (as shown in Admin Console)'
    }
    if ($RequireVMName -and -not $script:VMName) {
        $script:VMName = Read-SecurePrompt -Prompt 'Enter the VM name to repair (e.g., TG-Connector-NY-1)'
    }

    # Validate network slug and API token immediately - before any expensive operations
    if ($RequireNetwork -and $RequireToken) {
        $pingQuery = @'
query ValidateCredentials {
  remoteNetworks(first: 1) {
    edges {
      node {
        id
      }
    }
  }
}
'@
        Write-Status 'Validating Twingate API credentials...' -Type Action
        Invoke-TwingateApi -Network $script:TwingateNetwork -Token $script:ApiToken -Query $pingQuery | Out-Null
        Write-Status 'API credentials validated.'
    }
}

#endregion

#region Action Handlers

function Invoke-DeployAction {
    Resolve-InteractiveParams -RequireNetwork -RequireToken -RequireRemoteNetwork

    $toolsPath  = Join-Path $VMPath 'tools'
    $imagesPath = Join-Path $VMPath 'images'

    # Prerequisites and environment setup
    Test-Prerequisites
    $qemuImg    = Install-QemuImg -ToolsPath $toolsPath
    $switchName = Get-OrCreateExternalSwitch -PreferredName $VSwitch

    # Resolve Remote Network ID via API
    $remoteNetId = Get-TwingateRemoteNetwork -Network $TwingateNetwork -Token $ApiToken -Name $RemoteNetwork

    # Cache Ubuntu image and base VHDX (downloads only if not already cached)
    $imgPath  = Get-UbuntuCloudImage -ImagesPath $imagesPath
    $baseVhdx = Convert-CloudImageToVhdx -QemuImgExe $qemuImg -SourceImg $imgPath -ImagesPath $imagesPath

    # Track created connectors for the health-check phase
    $deployedConnectors = [System.Collections.Generic.List[hashtable]]::new()

    for ($i = 1; $i -le $ConnectorCount; $i++) {
        $vmName = "TG-Connector-$RemoteNetwork-$i"
        $vmDir  = Join-Path $VMPath $vmName

        Write-Status "--- Deploying $vmName ($i of $ConnectorCount) ---" -Type Action

        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            Write-Status "VM '$vmName' already exists. Skipping." -Type Warning
            continue
        }

        New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

        # Create API connector and generate tokens
        $connectorId = $null
        try {
            $connectorId = New-TwingateConnector -Network $TwingateNetwork -Token $ApiToken `
                -RemoteNetworkId $remoteNetId -ConnectorName $vmName
            $tokens = New-TwingateConnectorTokens -Network $TwingateNetwork -Token $ApiToken `
                -ConnectorId $connectorId
        }
        catch {
            Write-Status "Failed to create connector '$vmName': $_" -Type Error
            Write-Status 'Skipping this connector and continuing to the next.' -Type Warning
            continue
        }

        # Generate SSH keypair
        $sshInfo = New-SshKeyPair -VmDir $vmDir

        # Build cloud-init userdata and ISO
        $ciInfo  = New-CloudInitUserData -VmName $vmName -SshPublicKey $sshInfo.PublicKey `
            -AccessToken $tokens.AccessToken -RefreshToken $tokens.RefreshToken `
            -TwingateNetwork $TwingateNetwork
        $isoPath = New-CloudInitIso -VmDir $vmDir -VmName $vmName `
            -UserData $ciInfo.UserData -Username $ciInfo.Username
        Write-Status "DEBUG - Console credentials for $vmName  user: $($ciInfo.Username)  password: $($ciInfo.Password)" -Type Warning

        # Create VM (does not start it yet)
        $created = New-ConnectorVM -VmName $vmName -VmDir $vmDir -BaseVhdxPath $baseVhdx `
            -CloudInitIso $isoPath -SwitchName $switchName -ConnectorId $connectorId `
            -SshUsername $ciInfo.Username -CpuCount $VMCpu -MemoryBytes $VMMemory

        if ($created) {
            Write-Status "Starting VM '$vmName'..." -Type Action
            Start-VM -Name $vmName

            $deployedConnectors.Add(@{
                VmName      = $vmName
                ConnectorId = $connectorId
            })
        }
    }

    if ($deployedConnectors.Count -eq 0) {
        Write-Status 'No connectors were deployed.' -Type Warning
        return
    }

    # Wait for all deployed connectors to report ALIVE
    Write-Status '--- Waiting for connectors to come online ---' -Type Action
    $results = [System.Collections.Generic.List[psobject]]::new()
    foreach ($c in $deployedConnectors) {
        $online = Wait-ConnectorOnline -Network $TwingateNetwork -Token $ApiToken `
            -ConnectorId $c.ConnectorId -ConnectorName $c.VmName -TimeoutSeconds 300
        $results.Add([PSCustomObject]@{
            Name   = $c.VmName
            Status = if ($online) { 'ALIVE' } else { 'TIMEOUT' }
        })
    }

    # Print summary
    Write-Host ''
    Write-Status '--- Deployment Summary ---' -Type Action
    $results | Format-Table -AutoSize | Out-String | Write-Host

    $timedOut = @($results | Where-Object { $_.Status -eq 'TIMEOUT' })
    if ($timedOut.Count -gt 0) {
        Write-Status 'One or more connectors never came ALIVE. The VM exists but has no working connector.' -Type Error
        foreach ($t in $timedOut) {
            Write-Status "  - $($t.Name): repair with -Action FixVM -VMName $($t.Name)" -Type Warning
        }
    }
}
function Invoke-RemoveAction {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($VMName) {
        Resolve-InteractiveParams -RequireNetwork -RequireToken
        $resolved = Resolve-SingleConnectorVM -VMName $VMName -VMPath $VMPath
        if ($null -eq $resolved) { return }
        $vms = @($resolved.VM)
    }
    else {
        Resolve-InteractiveParams -RequireNetwork -RequireToken -RequireRemoteNetwork
        $pattern = "TG-Connector-$RemoteNetwork-*"
        $vms = Get-VM -Name $pattern -ErrorAction SilentlyContinue
        if ($null -eq $vms -or @($vms).Count -eq 0) {
            Write-Status "No VMs matching '$pattern' found. Nothing to remove." -Type Warning
            return
        }
    }

    Write-Status "Found $(@($vms).Count) VM(s) to remove:"
    foreach ($vm in $vms) { Write-Host "  - $($vm.Name)" }

    $confirm = Read-Host 'Remove these VMs and their Twingate connectors? (Y/N)'
    if ($confirm -ne 'Y') {
        Write-Status 'Aborted.' -Type Warning
        return
    }

    $results = @()
    foreach ($vm in $vms) {
        if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Stop and Remove VM')) { continue }
        Write-Status "Removing $($vm.Name)..." -Type Action
        try {
            # Stop VM
            if ($vm.State -ne 'Off') {
                Stop-VM -Name $vm.Name -Force -TurnOff
            }

            # Extract connector ID from Notes
            $connectorId = $null
            foreach ($part in ($vm.Notes -split ';')) {
                if ($part -match '^TwingateConnectorId=(.+)$') { $connectorId = $Matches[1] }
            }

            # Delete API connector (fail-safe: log warning but continue)
            if ($connectorId) {
                Remove-TwingateConnector -Network $TwingateNetwork -Token $ApiToken -ConnectorId $connectorId | Out-Null
            } else {
                Write-Status "No ConnectorId in Notes for $($vm.Name). Skipping API deletion." -Type Warning
            }

            # Get VM path before removing
            $vmPath = $null
            $vmHdd = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vmHdd) {
                $vmPath = Split-Path $vmHdd.Path
            }

            # Remove VM from Hyper-V
            Remove-VM -Name $vm.Name -Force

            # Remove VM files
            if ($vmPath -and (Test-Path $vmPath)) {
                Remove-Item -Path $vmPath -Recurse -Force
                Write-Status "Removed files: $vmPath"
            }

            Write-Status "Removed: $($vm.Name)"
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'REMOVED' }
        }
        catch {
            Write-Status "Failed to fully remove $($vm.Name): $_" -Type Warning
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'FAILED' }
        }
    }

    Write-Host ''
    Write-Status '--- Remove Summary ---' -Type Action
    $results | Format-Table -AutoSize | Out-String | Write-Host
}

function Invoke-UpdateConnectorAction {
    Resolve-InteractiveParams -RequireNetwork -RequireToken

    $vms = Get-VM -Name 'TG-Connector-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Running' }

    if ($null -eq $vms -or @($vms).Count -eq 0) {
        Write-Status 'No running TG-Connector-* VMs found.' -Type Warning
        return
    }

    $results = @()
    foreach ($vm in $vms) {
        Write-Status "--- Updating connector on $($vm.Name) ---" -Type Action

        $sshDetails = Get-VmSshDetails -VmName $vm.Name -VMPath $VMPath -TimeoutSeconds 60
        if ($null -eq $sshDetails) {
            Write-Status "Cannot get SSH details for $($vm.Name). Skipping." -Type Warning
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'SSH_UNAVAILABLE' }
            continue
        }

        $cmd = 'sudo apt-get update -q && sudo apt-get install -y twingate-connector'
        $sshResult = Invoke-SshCommand -IpAddress $sshDetails.IpAddress -Username $sshDetails.Username `
            -PrivateKeyPath $sshDetails.PrivateKey -Command $cmd -ConnectTimeout 30

        if (-not $sshResult.Success) {
            $hint = Get-SshErrorHint -Output ($sshResult.Output -join ' ')
            Write-Status "SSH command failed on $($vm.Name)." -Type Warning
            if ($hint) { Write-Status "  Likely cause: $hint" -Type Error }
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'SSH_FAILED' }
            continue
        }

        # Verify connector comes back ALIVE
        $online = $false
        if ($sshDetails.ConnectorId) {
            $online = Wait-ConnectorOnline -Network $TwingateNetwork -Token $ApiToken `
                -ConnectorId $sshDetails.ConnectorId -ConnectorName $vm.Name -TimeoutSeconds 180
        } else {
            Write-Status "No ConnectorId for $($vm.Name). Skipping health check." -Type Warning
            $online = $true
        }

        $results += [PSCustomObject]@{
            Name   = $vm.Name
            Result = if ($online) { 'UPDATED_ALIVE' } else { 'UPDATED_NOT_ALIVE' }
        }
        if (-not $online) {
            Write-Status "Connector on $($vm.Name) is not ALIVE after update. Halting to prevent cascading failures." -Type Error
            break
        }
    }

    Write-Host ''
    Write-Status '--- Update Summary ---' -Type Action
    $results | Format-Table -AutoSize | Out-String | Write-Host
}

function Invoke-UpdateOSAction {
    Resolve-InteractiveParams -RequireNetwork -RequireToken

    $vms = Get-VM -Name 'TG-Connector-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Running' }

    if ($null -eq $vms -or @($vms).Count -eq 0) {
        Write-Status 'No running TG-Connector-* VMs found.' -Type Warning
        return
    }

    $results = @()
    foreach ($vm in $vms) {
        Write-Status "--- OS update on $($vm.Name) ---" -Type Action

        $sshDetails = Get-VmSshDetails -VmName $vm.Name -VMPath $VMPath -TimeoutSeconds 60
        if ($null -eq $sshDetails) {
            Write-Status "Cannot get SSH details for $($vm.Name). Skipping." -Type Warning
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'SSH_UNAVAILABLE' }
            continue
        }

        $cmd = 'sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'
        $sshResult = Invoke-SshCommand -IpAddress $sshDetails.IpAddress -Username $sshDetails.Username `
            -PrivateKeyPath $sshDetails.PrivateKey -Command $cmd -ConnectTimeout 30

        if (-not $sshResult.Success) {
            $results += [PSCustomObject]@{ Name = $vm.Name; Result = 'SSH_FAILED' }
            continue
        }

        $online = $false
        if ($sshDetails.ConnectorId) {
            $online = Wait-ConnectorOnline -Network $TwingateNetwork -Token $ApiToken `
                -ConnectorId $sshDetails.ConnectorId -ConnectorName $vm.Name -TimeoutSeconds 180
        } else {
            $online = $true
        }

        $results += [PSCustomObject]@{
            Name   = $vm.Name
            Result = if ($online) { 'UPGRADED_ALIVE' } else { 'UPGRADED_NOT_ALIVE' }
        }
        if (-not $online) {
            Write-Status "Connector on $($vm.Name) is not ALIVE after OS update. Halting to prevent cascading failures." -Type Error
            break
        }
    }

    Write-Host ''
    Write-Status '--- OS Update Summary ---' -Type Action
    $results | Format-Table -AutoSize | Out-String | Write-Host
}

function Invoke-FixVMAction {
    Resolve-InteractiveParams -RequireNetwork -RequireToken -RequireVMName

    $resolved = Resolve-SingleConnectorVM -VMName $VMName -VMPath $VMPath
    if ($null -eq $resolved) { throw "Cannot resolve VM '$VMName' for repair." }
    if ($resolved.VM.State -ne 'Running') {
        throw "VM '$VMName' is not running (state: $($resolved.VM.State)). Start it first."
    }

    $ssh = Get-VmSshDetails -VmName $VMName -VMPath $VMPath -TimeoutSeconds 60
    if ($null -eq $ssh) {
        throw "Cannot reach '$VMName' over SSH; cannot repair."
    }

    try {
        # Is the connector already ALIVE in the API?
        $isAlive = $false
        if ($resolved.ConnectorId) {
            $state = Get-TwingateConnectorStatus -Network $TwingateNetwork -Token $ApiToken -ConnectorId $resolved.ConnectorId
            $isAlive = ($state -eq 'ALIVE')
        }

        # Is the package installed in the guest?
        $check = Invoke-SshCommand -IpAddress $ssh.IpAddress -Username $ssh.Username `
            -PrivateKeyPath $ssh.PrivateKey -Command 'dpkg -s twingate-connector >/dev/null 2>&1 && echo INSTALLED || echo MISSING'
        $packageInstalled = ($check.Success -and (($check.Output -join '') -match 'INSTALLED'))

        $plan = Get-FixVMPlan -IsAlive $isAlive -PackageInstalled $packageInstalled
        Write-Status "FixVM plan for ${VMName}: $plan" -Type Action

        $waitTimeout = 180

        switch ($plan) {
            'none' {
                Write-Status "$VMName connector is already ALIVE. Nothing to do." -Type Action
                return
            }
            'start' {
                $r = Invoke-SshCommand -IpAddress $ssh.IpAddress -Username $ssh.Username `
                    -PrivateKeyPath $ssh.PrivateKey -Command 'sudo systemctl enable --now twingate-connector'
                if (-not $r.Success) {
                    throw "Failed to start connector on ${VMName}: $(Get-SshErrorHint -Output ($r.Output -join ' '))"
                }
            }
            'reprovision' {
                Write-Status "Connector software missing on $VMName; reprovisioning a net-new connector." -Type Action
                $remoteNetId = Get-ConnectorRemoteNetworkId -ConnectorId $resolved.ConnectorId
                $newId  = New-TwingateConnector -Network $TwingateNetwork -Token $ApiToken `
                            -RemoteNetworkId $remoteNetId -ConnectorName $VMName
                # Record the old connector as orphaned as soon as the new one is minted,
                # so it is surfaced (via the finally block) even if a later step fails.
                if ($resolved.ConnectorId) {
                    $script:OrphanedConnectors.Add([PSCustomObject]@{ VMName = $VMName; OldConnectorId = $resolved.ConnectorId })
                }
                $tokens = New-TwingateConnectorTokens -Network $TwingateNetwork -Token $ApiToken -ConnectorId $newId
                $bootstrap = Get-ConnectorBootstrapScript -AccessToken $tokens.AccessToken `
                            -RefreshToken $tokens.RefreshToken -TwingateNetwork $TwingateNetwork

                # Push the script (base64 to avoid quoting issues), run it, then remove it (it holds tokens).
                $remoteScript = '/tmp/twingate-bootstrap.sh'
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bootstrap))
                $r = Invoke-SshCommand -IpAddress $ssh.IpAddress -Username $ssh.Username `
                    -PrivateKeyPath $ssh.PrivateKey `
                    -Command "echo $b64 | base64 -d | sudo tee $remoteScript >/dev/null && sudo bash $remoteScript; rc=`$?; sudo rm -f $remoteScript; exit `$rc"
                if (-not $r.Success) {
                    throw "Bootstrap failed on ${VMName}: $(Get-SshErrorHint -Output ($r.Output -join ' '))"
                }

                # Repoint Notes to the new connector, using the authoritative SSH username.
                $newNotes = "TwingateConnectorId=$newId;SshUser=$($ssh.Username)"
                Set-VM -Name $VMName -Notes $newNotes
                $resolved = @{ VM = $resolved.VM; ConnectorId = $newId; SshUser = $ssh.Username }
                $waitTimeout = 300  # reprovision includes a full apt install
            }
        }

        if (-not $resolved.ConnectorId) {
            Write-Status "$VMName connector service was started, but the VM has no ConnectorId in Notes; cannot verify ALIVE via the API." -Type Warning
            return
        }

        $online = Wait-ConnectorOnline -Network $TwingateNetwork -Token $ApiToken `
            -ConnectorId $resolved.ConnectorId -ConnectorName $VMName -TimeoutSeconds $waitTimeout
        if ($online) {
            Write-Status "$VMName connector is ALIVE after repair." -Type Action
        } else {
            Write-Status "$VMName connector did not come ALIVE after repair." -Type Error
        }
    }
    finally {
        Write-OrphanCallout
    }
}

function Invoke-ListAction {
    $vms = Get-VM -Name 'TG-Connector-*' -ErrorAction SilentlyContinue
    if ($null -eq $vms -or @($vms).Count -eq 0) {
        Write-Status 'No TG-Connector-* VMs found.' -Type Warning
        return
    }

    $rows = foreach ($vm in $vms) {
        $adapter   = Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue
        $ipAddress = $adapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

        $connectorId = $null
        foreach ($part in ($vm.Notes -split ';')) {
            if ($part -match '^TwingateConnectorId=(.+)$') { $connectorId = $Matches[1] }
        }

        $uptime = if ($vm.State -eq 'Running' -and $vm.Uptime) {
            '{0}d {1}h {2}m' -f $vm.Uptime.Days, $vm.Uptime.Hours, $vm.Uptime.Minutes
        } else { '-' }

        [PSCustomObject]@{
            Name        = $vm.Name
            State       = $vm.State
            'IP Address' = if ($ipAddress) { $ipAddress } else { '-' }
            Uptime      = $uptime
            ConnectorId = if ($connectorId) { $connectorId } else { '-' }
        }
    }

    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

#endregion

#region Main

function Main {
    switch ($Action) {
        'Deploy'          { Invoke-DeployAction }
        'Remove'          { Invoke-RemoveAction }
        'UpdateConnector' { Invoke-UpdateConnectorAction }
        'UpdateOS'        { Invoke-UpdateOSAction }
        'List'            { Invoke-ListAction }
        'FixVM'           { Invoke-FixVMAction }
    }
}

$logPath = Join-Path $PSScriptRoot "Deploy-TwingateConnector-$Action-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append | Out-Null
Write-Status "Transcript logging to: $logPath"
try {
    Main
}
catch {
    Write-Status "Aborting '$Action': $($_.Exception.Message)" -Type Error
    $firstFrame = ($_.ScriptStackTrace -split "`n" | Select-Object -First 1)
    if ($firstFrame) { Write-Status "  at $firstFrame" -Type Info }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}

#endregion
