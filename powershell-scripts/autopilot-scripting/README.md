# Twingate Headless → User Mode Promotion — Admin Primer

A workflow for shipping pre-provisioned Windows machines that already have Twingate
connectivity (headless/service mode), then automatically promoting each machine to
the interactive user-mode client the first time its end user logs in.

Pairs with `Promote-TwingateToUserMode.ps1`.

---

## Why this exists

Headless installs (`service_secret=`) give a machine Twingate access **without a UI**
and without a logged-in user — ideal during imaging, provisioning, and Autopilot, where
the device needs to reach internal resources before anyone signs in.

But headless mode never installs the tray client, and the only supported way to move
headless → user mode is a **full reinstall from the EXE**. This script automates that
reinstall and launches the tray app in the user's session, so the transition happens
silently on first logon with no manual touch.

---

## The lifecycle

```
[ Admin images a reference machine ]
        │  Twingate installed in HEADLESS mode (service_secret)
        │  Login-triggered scheduled task created (runs the script elevated)
        │  Script staged in an admin-only path
        ▼
[ Capture image → hand to vendor (e.g. CDW) / Autopilot ]
        │
        ▼
[ New machine built from image, shipped to user ]
        │  Device already has Twingate connectivity (headless service running)
        ▼
[ User receives machine, powers on, logs in for the first time ]
        │  Login task fires → script runs ELEVATED
        ▼
[ Script: download latest EXE → stop service → reinstall in user mode →
  force service Automatic → launch tray app in user session →
  promote tray icon → remove its own login task ]
        ▼
[ User now has the full Twingate tray client; service auto-starts going forward ]
```

---

## Requirements

- Windows 10 / 11, Windows PowerShell 5.1.
- A Twingate **Service account + Service Key** for the headless install (Enterprise plan).
- The target **network subdomain** (`<network>.twingate.com`).
- Outbound HTTPS to `api.twingate.com`, `binaries.twingate.com`, and `www.twingate.com`
  (installer download + changelog fallback).
- The script staged where standard users can't read or alter it
  (e.g. `C:\ProgramData\TwingateDeploy\` with restricted ACLs). It holds **no secrets**.

---

## Assumptions

- The reference image ships with Twingate in **headless mode**; `Twingate.exe` is absent
  until the script reinstalls (the script uses that absence as its mode signal).
- Exactly one interactive user logs in (standard single-user device model). The tray app
  launches into the active session via a `BUILTIN\Users` task.
- The login task runs **elevated** (SYSTEM / highest privileges) — required to
  uninstall/reinstall Twingate. It cannot itself launch the tray app in the user session,
  which is why the script hands that off to a transient user-context task.
- "Always auto-start" is desired; the script forces the service to **Automatic** after
  reinstall.

---

## One-time setup on the reference machine

**1. Install Twingate headless** (elevated):

```powershell
TwingateWindowsInstaller.exe service_secret=C:\path\to\service_key.json /qn
```

Confirm the `Twingate Service` is running and reaching internal resources.

**2. Stage the script** in an admin-only directory, e.g.:

```
C:\ProgramData\TwingateDeploy\Promote-TwingateToUserMode.ps1
```

**3. Create the login-triggered scheduled task** (elevated, runs as SYSTEM). The task
name **must match** the script's `-LoginTaskName` value (default below):

```powershell
$taskName = "Twingate Promote To User Mode"
$script   = "C:\ProgramData\TwingateDeploy\Promote-TwingateToUserMode.ps1"
$network  = "acme"   # <network>.twingate.com — set per environment

$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -TwingateNetworkName $network"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings
```

**4. Capture the image.** Hand off to the vendor / Autopilot pipeline.

---

## What happens on the user's first logon

1. Login task fires, runs the script elevated.
2. Script downloads the latest Windows EXE (redirect, with changelog RSS fallback).
3. Stops the headless service/process.
4. Reinstalls in user mode: `/quiet network=<network>.twingate.com no_optional_updates=true auto_update=true`. The installer's exit code is **not** inspected — the script just waits for it to finish.
5. Forces the service start type to **Automatic** and starts it. **This is the real success signal:** if the reinstall failed, the service won't start, the run is treated as failed, and the login task is left in place to retry on the next logon.
6. Launches `Twingate.exe` in the user's session via a transient `BUILTIN\Users` task.
7. Promotes the Twingate tray icon.
8. **Removes its own login task** — the reinstall runs once and won't repeat.

Transcript is written to `C:\ProgramData\Twingate\promote-to-user.log`.

---

## Script parameters

| Parameter | Required | Purpose |
|---|---|---|
| `-TwingateNetworkName` | Yes | Subdomain only (`acme`), not the FQDN. Pre-configures the client. |
| `-LoginTaskName` | No | Name of the login task to self-remove. Default: `Twingate Promote To User Mode`. Must match the task you registered. |
| `-SkipIfAlreadyUserMode` | No | Skip the reinstall if `Twingate.exe` is already present; still launches + cleans up. |

---

## Validate before fleet rollout

- **Run once on a test machine** and read the transcript end-to-end.
- **Success is judged by the service, not the installer:** the script does not check the
  installer's exit code. It waits for the installer to finish, then tries to start the
  service — a failure to start is what marks the run as failed (and leaves the login task
  in place to retry next logon). Confirm the service comes up in the transcript.
- **Icon promotion timing:** the tray icon's registry key only exists after the app has
  run in-session. The script waits 10s; if the icon isn't reliably promoted on first
  logon, increase that delay.
- **Confirm the login task self-removed** after a successful run.
