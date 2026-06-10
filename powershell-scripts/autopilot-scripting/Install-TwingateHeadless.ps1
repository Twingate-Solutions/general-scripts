#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Performs the initial HEADLESS (service-mode) install of the Twingate Windows
    client using a service account key. Intended to run during Autopilot
    provisioning, before any user logs in.

.DESCRIPTION
    Headless installs (service_secret=) give a machine Twingate connectivity with
    no UI and without a logged-in user - ideal during imaging/provisioning where
    the device must reach internal resources before anyone signs in. This script:

      1. Logs a transcript to an admin-only path
      2. Validates the supplied service key is well-formed JSON
      3. Force-uninstalls any existing Twingate client (safety check)
      4. Writes the key to a temporary service-key file (no BOM)
      5. Downloads the latest Windows EXE installer
      6. Installs in headless mode (service_secret=<file>)
      7. Forces the service start type to Automatic and starts it (so the
         headless connection comes up on every boot)
      8. Stages the follow-up promote script to an admin-only path
      9. Registers the login-triggered task that promotes the machine to user
         mode on first logon (runs the promote script elevated, as SYSTEM,
         after a configurable post-logon delay)
     10. Deletes the temporary key file and the installer

    Promote-TwingateToUserMode.ps1 must ship ALONGSIDE this script (same Autopilot
    payload / same folder). This script copies it to a persistent admin-only
    directory, locks that directory down, and wires up the first-logon task that
    runs it.

    Tested target: Windows 10/11, Windows PowerShell 5.1.

.PARAMETER ServiceKey
    The Twingate service account key as a raw JSON string (the contents of the
    service_key.json generated in the Admin Console). OPTIONAL: if not supplied,
    the script uses the inline $inlineServiceKey value defined in the
    Configuration section. The parameter wins when both are present. Whichever is
    used is written to a temporary file, passed to the installer's service_secret=
    argument, and deleted afterward.

.PARAMETER TwingateNetworkName
    Network subdomain (the "<network>" in <network>.twingate.com) baked into the
    follow-up promote task. Optional: if omitted, it is derived from the "network"
    field of the service key. Pass it explicitly if the key has no network field.

.PARAMETER DeployDir
    Persistent admin-only directory the promote script is staged into and run
    from by the login task. Default: C:\ProgramData\TwingateDeploy. The script
    removes inheritance and grants only SYSTEM + Administrators, so a standard
    user cannot tamper with a script that later runs as SYSTEM.

.PARAMETER LoginTaskName
    Name of the login-triggered task that runs the promote script. Default:
    "Twingate Promote To User Mode". MUST match the promote script's own
    -LoginTaskName default so the promote script can self-remove it.

.PARAMETER PromoteDelayMinutes
    Minutes to wait after logon before the promote task fires, so it does not run
    the instant the user signs in (lets the network and session settle). Default:
    10. Set to 0 to fire immediately.

.PARAMETER RetryUntilOnline
    Switch. Makes the login task repeat until promotion fully succeeds: the
    promote script probes the internet and skips (without removing the task) when
    offline, so it retries on an interval and removes itself once everything
    works. Without this switch the task fires once per logon and any failure
    simply retries on the next logon.

.PARAMETER RetryIntervalMinutes
    With -RetryUntilOnline: minutes between retry attempts. Default: 5.

.PARAMETER RetryDurationHours
    With -RetryUntilOnline: how long each per-logon retry window lasts before
    giving up until the next logon. Default: 24.

.PARAMETER ConnectivityTestUrl
    With -RetryUntilOnline: the URL the promote script probes (expects HTTP 200).
    Default: the Microsoft NCSI endpoint. Point it at an internal resource only
    reachable through Twingate if you want to validate the tunnel specifically.

.PARAMETER ConnectivityExpectedText
    With -RetryUntilOnline: substring the probe response body must contain to
    count as real internet (defeats captive portals). Default matches the NCSI
    endpoint; set to '' to check the HTTP 200 status only.

.EXAMPLE
    PS> .\Install-TwingateHeadless.ps1 -ServiceKey (Get-Content .\service_key.json -Raw)
    Installs in headless mode using a key read from a local file; network name is
    derived from the key and the first-logon promote task is registered.

.EXAMPLE
    PS> .\Install-TwingateHeadless.ps1 -ServiceKey $json -TwingateNetworkName acme
    Same, but with the promote task's network name supplied explicitly.

.EXAMPLE
    PS> .\Install-TwingateHeadless.ps1
    Uses the service key pasted into the inline $inlineServiceKey variable (no
    parameter needed); the network name is derived from the key.

.EXAMPLE
    PS> .\Install-TwingateHeadless.ps1 -RetryUntilOnline -RetryIntervalMinutes 5
    Installs headless and registers a login task that, on first logon, retries
    every 5 minutes until the internet is reachable and the promotion succeeds,
    then removes itself.

.NOTES
    The service key is a SECRET (it contains a private key). It is written to a
    restricted temp path and removed in the finally block, and is never written
    to the transcript. Stage this script in an admin-only location.

    If you paste the key into the inline $inlineServiceKey variable, the SCRIPT
    FILE itself then holds the secret - keep it in an admin-only path with
    restricted ACLs and do NOT commit it to source control.
#>

[CmdletBinding()]
param(
    # The Twingate service account key as a raw JSON string. Optional: if not
    # supplied, the script falls back to the inline $inlineServiceKey value in
    # the Configuration section. The parameter takes precedence over the inline
    # value when both are present.
    [Parameter()]
    [string]$ServiceKey,

    # --- Optional overrides ------------------------------------------------
    # Every parameter below is an OPTIONAL override. Their defaults live in the
    # "Editable defaults" block in the Configuration section, so they can be
    # baked into the staged script; anything passed on the CLI wins over that.

    # Network subdomain baked into the follow-up promote task. Blank/omitted =
    # derive from the "network" field of the service key.
    [Parameter()]
    [string]$TwingateNetworkName,

    # Persistent admin-only directory the promote script is staged into and run
    # from by the login task. Survives Autopilot provisioning cleanup.
    [Parameter()]
    [string]$DeployDir,

    # Name of the login-triggered task that runs the promote script. MUST match
    # the promote script's -LoginTaskName default so it can self-remove.
    [Parameter()]
    [string]$LoginTaskName,

    # Minutes to wait after logon before the promote task fires. 0 = immediate.
    [Parameter()]
    [int]$PromoteDelayMinutes,

    # Repeat the login task until promotion succeeds (connectivity-gated retry
    # that removes itself once everything works). Without it, the task fires once
    # per logon and any failure simply retries on the next logon.
    [Parameter()]
    [switch]$RetryUntilOnline,

    # When RetryUntilOnline: minutes between retry attempts.
    [Parameter()]
    [int]$RetryIntervalMinutes,

    # When RetryUntilOnline: per-logon retry window, in hours.
    [Parameter()]
    [int]$RetryDurationHours,

    # When RetryUntilOnline: URL the promote script probes for connectivity.
    [Parameter()]
    [string]$ConnectivityTestUrl,

    # When RetryUntilOnline: substring the probe body must contain ('' = 200 only).
    [Parameter()]
    [string]$ConnectivityExpectedText
)

###################################
##         Configuration         ##
###################################

$ErrorActionPreference = "Stop"
$ProgressPreference     = "SilentlyContinue"  # speeds up Invoke-WebRequest downloads

# ---------------------------------------------------------------------------
# Editable defaults
# ---------------------------------------------------------------------------
# Edit these to bake behaviour into the staged script (handy for Autopilot,
# where passing CLI args is awkward). Anything supplied on the command line
# OVERRIDES the matching default below.
if (-not $PSBoundParameters.ContainsKey('TwingateNetworkName'))      { $TwingateNetworkName      = "" }                                                  # "" = derive from the service key
if (-not $PSBoundParameters.ContainsKey('DeployDir'))                { $DeployDir                = "C:\ProgramData\TwingateDeploy" }
if (-not $PSBoundParameters.ContainsKey('LoginTaskName'))            { $LoginTaskName            = "Twingate Promote To User Mode" }
if (-not $PSBoundParameters.ContainsKey('PromoteDelayMinutes'))      { $PromoteDelayMinutes      = 10 }                                                  # minutes after logon; 0 = immediate
if (-not $PSBoundParameters.ContainsKey('RetryUntilOnline'))         { $RetryUntilOnline         = $false }                                              # $true = repeat the login task until promotion succeeds
if (-not $PSBoundParameters.ContainsKey('RetryIntervalMinutes'))     { $RetryIntervalMinutes     = 5 }                                                   # minutes between retries (when RetryUntilOnline)
if (-not $PSBoundParameters.ContainsKey('RetryDurationHours'))       { $RetryDurationHours       = 24 }                                                  # per-logon retry window, hours (when RetryUntilOnline)
if (-not $PSBoundParameters.ContainsKey('ConnectivityTestUrl'))      { $ConnectivityTestUrl      = "http://www.msftconnecttest.com/connecttest.txt" }
if (-not $PSBoundParameters.ContainsKey('ConnectivityExpectedText')) { $ConnectivityExpectedText = "Microsoft Connect Test" }                            # "" = check HTTP 200 only

# Fixed paths / endpoints (not exposed as parameters)
$twingateServiceName  = "twingate.service"
$installerPath        = "C:\Windows\Temp\TwingateInstaller.exe"
$serviceKeyPath       = "C:\Windows\Temp\twingate_service_key.json"

$logDir               = "C:\ProgramData\Twingate"
$logPath              = Join-Path $logDir "headless-install.log"

# Primary download: api.twingate.com redirects to the current Windows installer.
$primaryDownloadUrl   = "https://api.twingate.com/download/windows"
# Fallback: resolve the latest Windows EXE from the public clients changelog RSS.
$changelogRssUrl      = "https://www.twingate.com/changelog-clients.rss.xml"

# ---------------------------------------------------------------------------
# Inline service key (fallback when -ServiceKey is not supplied)
# ---------------------------------------------------------------------------
# If you are NOT passing the key via -ServiceKey, paste the full contents of
# service_key.json between the @' and '@ markers below, replacing the placeholder
# line. Leave it as-is to require the -ServiceKey parameter instead. The single-
# quoted here-string keeps the JSON verbatim (no PowerShell variable expansion).
#
# SECURITY: pasting the key here puts a SECRET in this file - keep it admin-only
# and out of source control. The -ServiceKey parameter always takes precedence.
$inlineServiceKey = @'
PASTE_SERVICE_KEY_JSON_HERE
'@

###################################
##          Functions           ##
###################################

# Resolve the latest Windows client EXE URL from the changelog RSS as a fallback
# when the api.twingate.com redirect is unavailable or serves the wrong artifact.
function Get-TwingateClientDownloadUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChangelogRssUrl
    )

    $rssResponse = Invoke-WebRequest -Uri $ChangelogRssUrl -UseBasicParsing
    [xml]$rss = $rssResponse.Content

    $changelogUrl = $null
    foreach ($item in $rss.rss.channel.item) {
        if ($item.link -match "windows") {
            $changelogUrl = $item.link
            break
        }
    }
    if (-not $changelogUrl) {
        throw "Could not find a Windows client entry in the changelog RSS feed."
    }

    # Fragment format: {os}-{year}-{build}-release e.g. windows-2025-330-release
    $uri      = [System.Uri]$changelogUrl
    $baseUrl  = $uri.GetLeftPart([System.UriPartial]::Path)
    $fragment = $uri.Fragment.TrimStart('#')
    $parts    = $fragment -split '-'
    if ($parts.Count -lt 4) {
        throw "Unexpected changelog fragment format: '$fragment'"
    }
    $os            = $parts[0]
    $year          = $parts[1]
    $build         = $parts[2]
    $versionPrefix = "$year.$build"

    $page = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing
    $link = $page.Links |
        Where-Object { $_.href -like "https://binaries.twingate.com/client/$os/versions/$versionPrefix.*" } |
        Select-Object -First 1
    if (-not $link) {
        throw "No matching download link found for '$os' version prefix '$versionPrefix'."
    }

    # The changelog links to the MSI; the EXE bundles the .NET runtime.
    return ($link.href -replace "\.msi$", ".exe")
}

# Download the latest installer EXE, preferring the redirect and falling back to
# the changelog RSS resolution.
function Get-TwingateInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Destination
    )

    try {
        Write-Host "[+] Downloading installer via $primaryDownloadUrl"
        Invoke-WebRequest -Uri $primaryDownloadUrl -OutFile $Destination -UseBasicParsing
        Write-Host "[+] Download complete (primary)"
        return
    }
    catch {
        Write-Warning "[!] Primary download failed: $($_.Exception.Message)"
        Write-Host  "[+] Falling back to changelog RSS resolution"
    }

    $resolvedUrl = Get-TwingateClientDownloadUrl -ChangelogRssUrl $changelogRssUrl
    Write-Host "[+] Resolved installer URL: $resolvedUrl"
    Invoke-WebRequest -Uri $resolvedUrl -OutFile $Destination -UseBasicParsing
    Write-Host "[+] Download complete (fallback)"
}

# Force-uninstall any existing Twingate client as a safety check before the
# fresh headless install. Stops the service/process first so files aren't
# locked, then removes every "Twingate" entry found in the uninstall registry.
# (Uses the registry rather than Win32_Product, which is slow and triggers an
# MSI consistency check across every installed product.)
function Uninstall-ExistingTwingate {
    Write-Host "[+] Checking for an existing Twingate install to remove"

    if (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue) {
        Write-Host "[+] Stopping Twingate service"
        Stop-Service -Name $twingateServiceName -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue

    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entries = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Twingate*" }

    if (-not $entries) {
        Write-Host "[+] No existing Twingate install found"
        return
    }

    foreach ($entry in $entries) {
        Write-Host "[+] Uninstalling existing install: $($entry.DisplayName)"
        if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            # MSI product: uninstall by product code, silently.
            Start-Process -FilePath "msiexec.exe" `
                -ArgumentList "/x $($entry.PSChildName) /quiet /norestart" -Wait
        }
        elseif ($entry.QuietUninstallString) {
            cmd /c $entry.QuietUninstallString
        }
        elseif ($entry.UninstallString) {
            cmd /c $entry.UninstallString
        }
    }
    Write-Host "[+] Existing Twingate install removed"
}

# Stage the follow-up promote script to a persistent admin-only directory and
# register the login-triggered task that runs it (elevated, as SYSTEM) on the
# user's first logon. The promote script is expected to ship ALONGSIDE this one
# (same payload); it is copied to a stable location so it survives Autopilot
# provisioning cleanup.
function Register-PromoteLoginTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceDir,
        [Parameter(Mandatory)] [string]$DeployDir,
        [Parameter(Mandatory)] [string]$LoginTaskName,
        [Parameter(Mandatory)] [string]$NetworkName,
        [Parameter()] [int]$DelayMinutes = 10,
        [Parameter()] [switch]$RetryUntilOnline,
        [Parameter()] [int]$RetryIntervalMinutes = 5,
        [Parameter()] [int]$RetryDurationHours = 24,
        [Parameter()] [string]$ConnectivityTestUrl,
        [Parameter()] [string]$ConnectivityExpectedText
    )

    $scriptName   = "Promote-TwingateToUserMode.ps1"
    $sourceScript = Join-Path $SourceDir $scriptName
    $stagedScript = Join-Path $DeployDir $scriptName

    if (-not (Test-Path $sourceScript)) {
        throw "Promote script '$scriptName' not found next to this script ($SourceDir). Ship both scripts in the same folder so the current version is staged."
    }

    # Create the deploy dir and lock it down: remove inheritance and grant only
    # SYSTEM + Administrators. This stops a standard user from altering a script
    # that the login task later runs as SYSTEM (privilege-escalation guard).
    if (-not (Test-Path $DeployDir)) {
        New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
    }
    $acl = Get-Acl -Path $DeployDir
    $acl.SetAccessRuleProtection($true, $false)   # protect from inheritance, drop inherited ACEs
    foreach ($identity in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $DeployDir -AclObject $acl

    # Always overwrite the staged copy with the current source, so the staged
    # script can never drift out of sync with the task arguments built below.
    Write-Host "[+] Staging promote script to $stagedScript (overwriting any existing copy)"
    Copy-Item -Path $sourceScript -Destination $stagedScript -Force

    # Register (or re-register) the login-triggered task.
    if (Get-ScheduledTask -TaskName $LoginTaskName -ErrorAction SilentlyContinue) {
        Write-Host "[+] Removing existing login task '$LoginTaskName'"
        Unregister-ScheduledTask -TaskName $LoginTaskName -Confirm:$false
    }

    Write-Host "[+] Registering login task '$LoginTaskName' (runs promote script as SYSTEM on logon)"

    # Build the promote invocation; add the connectivity gate when retrying.
    $promoteArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$stagedScript`" -TwingateNetworkName $NetworkName"
    if ($RetryUntilOnline) {
        # Double quotes (not single): the Win32 command-line splitter that runs
        # before PowerShell only honours double quotes, and the expected text
        # contains spaces.
        $promoteArgs += " -WaitForConnectivity -ConnectivityTestUrl `"$ConnectivityTestUrl`""
        if ($ConnectivityExpectedText) {
            $promoteArgs += " -ConnectivityExpectedText `"$ConnectivityExpectedText`""
        }
    }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $promoteArgs

    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($DelayMinutes -gt 0) {
        # -AtLogOn has no -Delay parameter; set the trigger's Delay property
        # directly. ISO 8601 duration, e.g. PT10M = 10 minutes after logon.
        $trigger.Delay = "PT${DelayMinutes}M"
        Write-Host "[+] Login task will fire $DelayMinutes minute(s) after logon"
    }
    if ($RetryUntilOnline) {
        # -AtLogOn triggers have no repetition parameter; borrow a Repetition
        # definition from a throwaway -Once trigger and graft it on so the task
        # retries on an interval. The promote script removes the task once it
        # fully succeeds, which stops the repetition.
        $rep = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $RetryIntervalMinutes) `
            -RepetitionDuration (New-TimeSpan -Hours $RetryDurationHours)
        $trigger.Repetition = $rep.Repetition
        Write-Host "[+] Login task will retry every $RetryIntervalMinutes min (up to $RetryDurationHours h) until promotion succeeds"
    }

    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $LoginTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
    Write-Host "[+] Login task registered."
}

###################################
##          Main Script          ##
###################################

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Host "[+] Twingate headless install starting"

    # ---- Resolve the service key (parameter or inline fallback) -----------
    # The -ServiceKey parameter wins; otherwise fall back to the inline value,
    # provided it has actually been filled in (not the placeholder).
    if (-not $ServiceKey) {
        if ($inlineServiceKey.Trim() -and $inlineServiceKey.Trim() -ne 'PASTE_SERVICE_KEY_JSON_HERE') {
            Write-Host "[+] No -ServiceKey supplied; using the inline service key"
            $ServiceKey = $inlineServiceKey
        }
        else {
            throw "No service key provided. Pass -ServiceKey, or paste the JSON into the `$inlineServiceKey variable in the script."
        }
    }

    # ---- Validate the service key is well-formed JSON ---------------------
    # Fail fast on a malformed key rather than letting the installer choke on it.
    try {
        $keyObject = $ServiceKey | ConvertFrom-Json
    }
    catch {
        throw "The -ServiceKey value is not valid JSON: $($_.Exception.Message)"
    }

    # ---- Resolve the network name for the follow-up promote task ----------
    # Prefer the explicit parameter; otherwise derive it from the key. Done up
    # front so we fail before installing if we can't determine it.
    if (-not $TwingateNetworkName) {
        if ($keyObject.network) {
            $TwingateNetworkName = ($keyObject.network -replace '\.twingate\.com$', '')
            Write-Host "[+] Derived network name from service key: $TwingateNetworkName"
        }
        else {
            throw "Network name not supplied via -TwingateNetworkName and no 'network' field found in the service key."
        }
    }

    # ---- Safety check: remove any existing Twingate install ---------------
    Uninstall-ExistingTwingate

    # ---- Write the service key to a temp file -----------------------------
    # WriteAllText avoids the UTF-8 BOM that Set-Content emits on PS 5.1, which
    # can trip up the installer's JSON parser.
    Write-Host "[+] Writing service key to $serviceKeyPath"
    [System.IO.File]::WriteAllText($serviceKeyPath, $ServiceKey)

    # ---- Download the installer -------------------------------------------
    Get-TwingateInstaller -Destination $installerPath

    # ---- Install in headless mode -----------------------------------------
    # service_secret=<file> => no UI, machine-level connectivity, no user needed.
    # The key file carries the network, so no network= argument is required.
    Write-Host "[+] Installing Twingate client in headless mode"
    $installArgs = "service_secret=$serviceKeyPath /quiet"
    Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait
    Write-Host "[+] Installer finished"

    # ---- Force service start type to Automatic and start it ---------------
    # The installer can leave the service set to Manual; force Automatic so the
    # headless connection comes up on every boot (before anyone logs in). A
    # failure to start means the headless install did not really succeed, so let
    # it propagate to the main catch.
    Write-Host "[+] Setting '$twingateServiceName' to Automatic and starting it"
    try {
        Set-Service -Name $twingateServiceName -StartupType Automatic
        Start-Service -Name $twingateServiceName
        Write-Host "[+] Service '$twingateServiceName' started"
    }
    catch {
        throw "Twingate service '$twingateServiceName' could not be set to Automatic / started after install: $($_.Exception.Message)"
    }

    # ---- Prime the first-logon promotion ----------------------------------
    # Stage the promote script and register the login task that runs it.
    Register-PromoteLoginTask -SourceDir $PSScriptRoot -DeployDir $DeployDir `
        -LoginTaskName $LoginTaskName -NetworkName $TwingateNetworkName `
        -DelayMinutes $PromoteDelayMinutes -RetryUntilOnline:$RetryUntilOnline `
        -RetryIntervalMinutes $RetryIntervalMinutes -RetryDurationHours $RetryDurationHours `
        -ConnectivityTestUrl $ConnectivityTestUrl -ConnectivityExpectedText $ConnectivityExpectedText

    Write-Host "[+] Headless install complete."
    $exitCode = 0
}
catch {
    Write-Error "[!] Headless install failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    # Always remove the service key file (it contains a private key) and the
    # downloaded installer, whether the run succeeded or failed.
    if (Test-Path $serviceKeyPath) {
        Remove-Item $serviceKeyPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $installerPath) {
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    }
    Stop-Transcript | Out-Null
}

exit $exitCode
