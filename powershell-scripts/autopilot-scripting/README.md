# Twingate Headless → User Mode Promotion

> ⚠️ **Experimental / lightly tested.** These scripts are a **template** for admins to
> adapt into their own provisioning scripts and processes — not a turnkey, fully
> supported product. Read them, test them on throwaway machines, and adjust to your
> environment before any fleet rollout. Treat them as a starting point.

Ship pre-provisioned Windows machines that already have Twingate connectivity
(headless / service mode), then automatically promote each one to the full
interactive tray client the first time its end user logs in.

Two scripts, shipped **together in the same folder**:

| Script | Runs | Does |
| --- | --- | --- |
| `Install-TwingateHeadless.ps1` | During Autopilot / provisioning (elevated) | Installs Twingate headless, then stages + schedules the promotion |
| `Promote-TwingateToUserMode.ps1` | On the user's first logon (as SYSTEM, via the task the installer registers) | Reinstalls in user mode and brings up the tray client |

You normally only ever **run the first script** — it wires up the second.

---

## Quickstart

1. **Get a service key.** In the Twingate Admin Console (Enterprise plan), create a
   Service Account + Service Key and download the JSON (`service_key.json`).
2. **Put both scripts in the same folder** (e.g. your Autopilot payload).
3. **Run the installer, elevated**, during provisioning:

   ```powershell
   .\Install-TwingateHeadless.ps1 -ServiceKey (Get-Content .\service_key.json -Raw)
   ```

   Or paste the key into the `$inlineServiceKey` block near the top of the script and
   run it with no arguments. The network name is derived from the key automatically.

That's it. The machine has headless Twingate connectivity **immediately**, and on the
user's **first logon** it silently promotes itself to the full tray client and cleans up.

**Recommended for real-world rollouts** — make the first-logon promotion wait for the
internet and retry until it works:

```powershell
.\Install-TwingateHeadless.ps1 -ServiceKey (Get-Content .\service_key.json -Raw) -RetryUntilOnline
```

> Both scripts target **Windows 10/11, Windows PowerShell 5.1**, and must be run elevated.

---

## `Install-TwingateHeadless.ps1`

Run once per machine during provisioning. In order, it:

1. Validates the service key is well-formed JSON.
2. **Force-uninstalls any existing Twingate** (safety check, via the uninstall registry).
3. Downloads the latest Windows EXE installer.
4. Installs **headless** (`service_secret=<file>`) — connectivity, no UI, no user needed.
5. Forces the service to **Automatic** and starts it (so it survives reboots).
6. **Stages `Promote-TwingateToUserMode.ps1`** into an admin-only directory (locked to
   SYSTEM + Administrators) and **registers the first-logon task** that runs it.
7. Deletes the temporary key file and installer.

Transcript: `C:\ProgramData\Twingate\headless-install.log`.

### Settings

Every setting can be **passed on the command line** *or* **baked into the "Editable
defaults" block** near the top of the script (handy for Autopilot, where CLI args are
awkward). A CLI value always overrides the baked-in default.

| Setting | Default | Purpose |
| --- | --- | --- |
| `-ServiceKey` / `$inlineServiceKey` | — | Service key JSON. Pass as a string, or paste into the inline block. **Required** (one or the other). |
| `-TwingateNetworkName` | derived from key | Network subdomain (`acme`). Auto-derived from the key's `network` field; override only if needed. |
| `-DeployDir` | `C:\ProgramData\TwingateDeploy` | Persistent admin-only dir the promote script is staged into and run from. |
| `-LoginTaskName` | `Twingate Promote To User Mode` | Name of the first-logon task. Must match the promote script's own default so it can self-remove. |
| `-PromoteDelayMinutes` | `10` | Minutes after logon before the promotion fires (lets the network/session settle). `0` = immediate. |
| `-RetryUntilOnline` | off | Repeat the first-logon task until the internet is reachable **and** promotion succeeds, then self-remove. See below. |
| `-RetryIntervalMinutes` | `5` | (with `-RetryUntilOnline`) Minutes between retries. |
| `-RetryDurationHours` | `24` | (with `-RetryUntilOnline`) Per-logon retry window before giving up until the next logon. |
| `-ConnectivityTestUrl` | MS NCSI endpoint | (with `-RetryUntilOnline`) URL probed for connectivity. Point at an internal-only URL to validate the Twingate tunnel specifically. |
| `-ConnectivityExpectedText` | `Microsoft Connect Test` | (with `-RetryUntilOnline`) Substring the probe body must contain (defeats captive portals). `''` = check HTTP 200 only. |

> **Both `.ps1` files must be in the same folder when you run the installer.** It copies
> the current `Promote-TwingateToUserMode.ps1` into the deploy dir every run (overwriting
> any older copy) so the staged script can't drift out of sync with the task. If the
> promote script isn't found alongside it, the installer stops with an error.
>
> **Security:** the service key is a secret. It's written to a restricted temp file and
> deleted afterward, and never written to the transcript. If you paste it into
> `$inlineServiceKey`, the **script file itself** holds the secret — keep it in an
> admin-only path and out of source control.

---

## `Promote-TwingateToUserMode.ps1`

You don't normally invoke this directly — the installer registers a SYSTEM task that runs
it on first logon. In order, it:

1. *(Optional, with `-WaitForConnectivity`)* probes the internet; if it's not reachable,
   exits without changes and **leaves the task** so it retries.
2. Downloads the latest Windows EXE.
3. Stops the headless service/process and **uninstalls the existing Twingate app**.
4. Reinstalls in **user mode** (`network=<network>.twingate.com`, no `service_secret`,
   with `auto_update=true no_optional_updates=true`).
5. Forces the service to **Automatic** and starts it — **this is the success signal**: if
   the reinstall failed the service won't start, the run is treated as failed, and the
   task is left in place to retry on the next logon.
6. Launches `Twingate.exe` in the interactive user's session (via a transient
   `BUILTIN\Users` task — an elevated/SYSTEM process can't reach the user session directly).
7. Promotes the tray notification icon.
8. **Removes its own login task** — so a successful promotion runs once and stops.

Transcript: `C:\ProgramData\Twingate\promote-to-user.log`.

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-TwingateNetworkName` | — (**required**) | Subdomain only (`acme`), not the FQDN. Pre-configures the reinstalled client. |
| `-LoginTaskName` | `Twingate Promote To User Mode` | Name of the task to self-remove. Must match what the installer registered. |
| `-SkipIfAlreadyUserMode` | off | Skip the reinstall if `Twingate.exe` is already present; still launches + cleans up. |
| `-WaitForConnectivity` | off | Probe the internet first and bail (without self-removing) if offline. Set by the installer's `-RetryUntilOnline`. |
| `-ConnectivityTestUrl` | MS NCSI endpoint | URL to probe when waiting for connectivity. |
| `-ConnectivityExpectedText` | `Microsoft Connect Test` | Substring the probe body must contain. `''` = HTTP 200 only. |

These also support the same "Editable defaults" block / CLI-override pattern.

---

## Testing & validation before fleet rollout

- **Stage both scripts in one folder and run the installer once on a test machine**, then
  read `headless-install.log` end-to-end. Confirm the service is **Running** and reaching
  internal resources.
- **Then log in as a separate standard test user** to fire the promotion. Watch
  `promote-to-user.log` and confirm the tray client appears.
- **Verify the registered task** looks right:

  ```powershell
  $t = Get-ScheduledTask 'Twingate Promote To User Mode'
  $t.Triggers[0].Delay          # PT10M
  $t.Triggers[0].Repetition     # PT5M / PT24H, only with -RetryUntilOnline
  $t.Actions[0].Arguments       # path + -TwingateNetworkName ... (+ connectivity args)
  ```

- **Confirm the staged promote script matches** what the task passes (re-staged every
  install run):

  ```powershell
  Select-String 'C:\ProgramData\TwingateDeploy\Promote-TwingateToUserMode.ps1' -Pattern 'WaitForConnectivity'
  ```

- **No `promote-to-user.log` after the task fires** = the promote script died before it
  could start its transcript (almost always a parameter-binding mismatch between the task
  and a stale staged script). Re-run the installer to re-stage, or run the task's exact
  command line by hand to see the swallowed error.
- **Confirm the login task self-removed** after a successful run.
- **Icon promotion timing:** the tray icon's registry key only exists after the app has
  run in-session. The script waits 10 s; increase it if the icon isn't reliably promoted.

---

## Requirements

- Windows 10 / 11, Windows PowerShell 5.1; run elevated (the installer is intended to run
  as SYSTEM during Autopilot, the promote task runs as SYSTEM at logon).
- A Twingate **Service Account + Service Key** for the headless install (Enterprise plan).
- Outbound HTTPS to `api.twingate.com`, `binaries.twingate.com`, and `www.twingate.com`
  (installer download + changelog fallback).
- Both scripts shipped together; the installer locks the deploy dir
  (`C:\ProgramData\TwingateDeploy\`) to SYSTEM + Administrators. The staged promote script
  holds **no secrets**.

### Things to know

- The device must ship with Twingate in **headless mode**; `Twingate.exe` (the UI) is
  absent until the promote script reinstalls — its presence is used as the "already user
  mode" signal.
- Assumes **one interactive user** per device (standard single-user model). The tray app
  launches into the active session via a `BUILTIN\Users` task.
- The login task runs **elevated** (SYSTEM / highest privileges) — required to
  uninstall/reinstall Twingate — and hands the in-session tray launch off to a transient
  user-context task.
- Both scripts force the service to **Automatic** so it always auto-starts.
