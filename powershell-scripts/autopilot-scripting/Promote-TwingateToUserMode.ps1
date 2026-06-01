#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Promotes an existing headless (service-mode) Twingate Windows install to
    interactive user mode by reinstalling the full client from the EXE and
    launching the tray app in the logged-in user's session.

.DESCRIPTION
    Headless installs (service_secret=) do NOT lay down the Twingate UI, so the
    only supported way to move headless -> user mode is a fresh install from the
    EXE installer (which bundles the .NET 8 runtime). This script:

      1. Logs a transcript to an admin-only path
      2. (Optional) skips the reinstall if the UI is already present
      3. Downloads the latest Windows EXE installer
      4. Stops the running service/process
      5. Reinstalls in user mode (network=, no service_secret)
      6. Forces the service start type to Automatic
      7. Launches Twingate.exe in the interactive user's session
      8. Promotes the tray notification icon
      9. Removes its own login-triggered scheduled task (and helper task)

    Intended to run ELEVATED, triggered by a per-machine scheduled task on user
    logon. Because it runs elevated it cannot itself launch the tray app in the
    user's session, so it uses a transient BUILTIN\Users scheduled task to do so.

    Tested target: Windows 10/11, Windows PowerShell 5.1.

.NOTES
    Store this script in an admin-only location. It contains no secrets or keys.
#>

[CmdletBinding()]
param(
    # Twingate network subdomain, i.e. the "<network>" in <network>.twingate.com.
    # REQUIRED so the reinstalled client is pre-configured and the user is not
    # prompted to type the network name.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TwingateNetworkName,

    # Name of the scheduled task that triggers THIS script on user logon.
    # This task is removed at the end of a successful run.
    [Parameter()]
    [string]$LoginTaskName = "Twingate Promote To User Mode",

    # If set, the reinstall is skipped when the user-mode UI (Twingate.exe) is
    # already present. The script still launches the app, promotes the icon, and
    # cleans up. Lets the login task fire harmlessly on every subsequent logon
    # until it removes itself.
    [Parameter()]
    [switch]$SkipIfAlreadyUserMode
)

###################################
##         Configuration         ##
###################################

$ErrorActionPreference = "Stop"
$ProgressPreference     = "SilentlyContinue"  # speeds up Invoke-WebRequest downloads

$twingateInstallDir   = "C:\Program Files\Twingate"
$twingateClientExe    = Join-Path $twingateInstallDir "Twingate.exe"
$twingateServiceName  = "twingate.service"
$installerPath        = "C:\Windows\Temp\TwingateInstaller.exe"

$logDir               = "C:\ProgramData\Twingate"
$logPath              = Join-Path $logDir "promote-to-user.log"

# Transient task used to launch the tray app in the interactive user session.
$launchTaskName       = "Twingate Client Launch (transient)"

# Primary download: api.twingate.com redirects to the current Windows installer.
$primaryDownloadUrl   = "https://api.twingate.com/download/windows"
# Fallback: resolve the latest Windows EXE from the public clients changelog RSS.
$changelogRssUrl      = "https://www.twingate.com/changelog-clients.rss.xml"

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

# Promote the Twingate tray icon for every user whose NotifyIconSettings contain
# a twingate.exe entry. The icon's registry key only exists AFTER the app has run
# in that user's session at least once, so this runs after the in-session launch.
function Set-TwingateNotifyIconPromoted {
    $results  = @()
    $userSIDs = Get-ChildItem -Path "registry::HKEY_USERS\"

    foreach ($userSID in $userSIDs) {
        $notifyIconPath = "registry::HKEY_USERS\$($userSID.PSChildName)\Control Panel\NotifyIconSettings"
        if (-not (Test-Path -Path $notifyIconPath)) { continue }

        foreach ($subKey in (Get-ChildItem -Path $notifyIconPath)) {
            $subKeyPath = "$notifyIconPath\$($subKey.PSChildName)"
            $exe = Get-ItemProperty -Path $subKeyPath -Name "ExecutablePath" -ErrorAction SilentlyContinue
            if ($exe -and $exe.ExecutablePath -like "*twingate.exe*") {
                Set-ItemProperty -Path $subKeyPath -Name "IsPromoted" -Value 1
                Write-Host "[+] Promoted tray icon for $subKeyPath"
                $results += [PSCustomObject]@{
                    UserSID        = $userSID.PSChildName
                    SubKeyPath     = $subKeyPath
                    ExecutablePath = $exe.ExecutablePath
                }
            }
        }
    }
    return $results
}

# Launch the tray app in the interactive user's session by registering a
# transient scheduled task running as BUILTIN\Users, starting it, then removing
# it. An elevated/SYSTEM process cannot otherwise reach the user's session.
function Start-TwingateInUserSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ClientExePath,
        [Parameter(Mandatory)] [string]$TaskName
    )

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host "[+] Removing stale launch task '$TaskName'"
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Write-Host "[+] Registering transient launch task '$TaskName'"
    $action    = New-ScheduledTaskAction -Execute $ClientExePath
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)  # never auto-fires; we start it manually
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users"

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal | Out-Null

    Write-Host "[+] Starting launch task in user session"
    Start-ScheduledTask -TaskName $TaskName

    # Give the app a moment to start and register its tray icon before promotion.
    Start-Sleep -Seconds 10

    Write-Host "[+] Removing transient launch task"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

###################################
##          Main Script          ##
###################################

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Host "[+] Twingate headless -> user mode promotion starting"
    Write-Host "[+] Target network: $TwingateNetworkName.twingate.com"

    # ---- Idempotency guard -------------------------------------------------
    # Headless installs do not deploy Twingate.exe, so its presence is a
    # reasonable signal that the box is already in user mode.
    $alreadyUserMode = Test-Path $twingateClientExe
    if ($alreadyUserMode -and $SkipIfAlreadyUserMode) {
        Write-Host "[+] User-mode client already present and -SkipIfAlreadyUserMode set; skipping reinstall"
    }
    else {
        if ($alreadyUserMode) {
            Write-Host "[+] User-mode client already present; reinstalling anyway (no -SkipIfAlreadyUserMode)"
        }

        # ---- Download ------------------------------------------------------
        Get-TwingateInstaller -Destination $installerPath

        # ---- Stop existing service/process --------------------------------
        Write-Host "[+] Stopping existing Twingate service and process (if running)"
        if (Get-Service -Name $twingateServiceName -ErrorAction SilentlyContinue) {
            Stop-Service -Name $twingateServiceName -Force -ErrorAction SilentlyContinue
        }
        Stop-Process -Name "Twingate" -Force -ErrorAction SilentlyContinue

        # ---- Reinstall in user mode ---------------------------------------
        # No service_secret => full client + UI. network= pre-configures it.
        # We deliberately do NOT inspect the installer's exit code: just wait
        # for it to finish. Whether the reinstall actually succeeded is judged
        # by whether the service can be started below.
        Write-Host "[+] Reinstalling Twingate client in user mode"
        $installArgs = "/quiet network=$TwingateNetworkName.twingate.com no_optional_updates=true auto_update=true"
        Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait
        Write-Host "[+] Installer finished"

        # ---- Start the service (this is our real success signal) ----------
        # Force the start type to Automatic and start it. If the reinstall
        # failed, the service won't exist or won't start, and the error
        # propagates to the main catch -> the run is treated as failed and the
        # login task is left in place to retry on the next logon.
        Write-Host "[+] Setting '$twingateServiceName' to Automatic and starting it"
        try {
            Set-Service -Name $twingateServiceName -StartupType Automatic
            Start-Service -Name $twingateServiceName
            Write-Host "[+] Service '$twingateServiceName' started"
        }
        catch {
            throw "Twingate service '$twingateServiceName' could not be started after reinstall; treating promotion as failed: $($_.Exception.Message)"
        }
    }

    # ---- Launch in the user's session -------------------------------------
    if (Test-Path $twingateClientExe) {
        Start-TwingateInUserSession -ClientExePath $twingateClientExe -TaskName $launchTaskName
    }
    else {
        Write-Warning "[!] $twingateClientExe not found after install; cannot launch in user session."
    }

    # ---- Promote the tray icon --------------------------------------------
    Write-Host "[+] Promoting Twingate tray icon"
    $iconResults = Set-TwingateNotifyIconPromoted
    if (-not $iconResults -or $iconResults.Count -eq 0) {
        Write-Warning "[!] No twingate.exe tray icon found to promote yet (app may need another moment in-session)."
    }

    # ---- Clean up the installer -------------------------------------------
    if (Test-Path $installerPath) {
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    }

    # ---- Self-removal: drop the login-triggered task ----------------------
    if (Get-ScheduledTask -TaskName $LoginTaskName -ErrorAction SilentlyContinue) {
        Write-Host "[+] Removing login-triggered task '$LoginTaskName'"
        Unregister-ScheduledTask -TaskName $LoginTaskName -Confirm:$false
    }
    else {
        Write-Host "[+] Login task '$LoginTaskName' not found; nothing to remove."
    }

    Write-Host "[+] Promotion complete."
    $exitCode = 0
}
catch {
    Write-Error "[!] Promotion failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    $exitCode = 1
}
finally {
    Stop-Transcript | Out-Null
}

exit $exitCode
