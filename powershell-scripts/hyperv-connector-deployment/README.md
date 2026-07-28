# Twingate Connector — Hyper-V Deployment Scripts

Automate the deployment and lifecycle management of Twingate Connectors on Windows Server using Hyper-V. Two scripts are provided:

| Script | When to use |
|---|---|
| `Deploy-TwingateConnector.ps1` | **Recommended.** API-driven, fully automated. No manual token copy-paste. |
| `hyperv-prebuilt-image-connector-installer.ps1` | **Legacy.** Uses a pre-built disk image. Requires manual token entry. |

---

## Deploy-TwingateConnector.ps1 (Recommended)

### Overview

Creates Twingate Connectors end-to-end — Twingate API connector records, Ubuntu 24.04 Gen2 Hyper-V VMs, and cloud-init provisioning — with no manual steps beyond running the script. Supports six lifecycle actions: **Deploy**, **Remove**, **UpdateConnector**, **UpdateOS**, **List**, and **FixVM**.

### Prerequisites

- Windows Server 2022 or 2025
- Hyper-V role installed (script can install it and prompt for reboot)
- PowerShell 5.1+ running **as Administrator**
- Internet access (downloads Ubuntu cloud image and qemu-img.exe on first run)
- A Twingate API token with **Read, Write & Provision** scope
- A Remote Network already created in the Twingate Admin Console
- qemu-img.exe is resolved automatically from the latest fdcastel GitHub release (with a Cloudbase v2.3.0 fallback); no manual download needed.

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Action` | Yes | — | `Deploy`, `Remove`, `UpdateConnector`, `UpdateOS`, `List`, or `FixVM` |
| `-TwingateNetwork` | Most actions | prompted | Your Twingate network slug (e.g. `acme` for `acme.twingate.com`) |
| `-ApiToken` | Most actions | prompted | API token. Accepts plain string or SecureString. |
| `-RemoteNetwork` | Deploy, Remove | prompted | Remote Network display name from the Admin Console |
| `-ConnectorCount` | Deploy only | `2` | Number of connectors (and VMs) to create |
| `-VMPath` | No | `C:\TwingateConnectors` | Root directory for VM files, cached images, and tools |
| `-VMCpu` | Deploy only | `1` | vCPUs per VM |
| `-VMMemory` | Deploy only | `2147483648` (2 GB) | RAM per VM in bytes |
| `-VSwitch` | No | auto-detect | Hyper-V external vSwitch name |
| `-VMName` | FixVM (required); Remove (optional) | prompted for FixVM | Target a single VM by name, e.g. `TG-Connector-NY-1` |

`List` requires no API parameters. `UpdateConnector` and `UpdateOS` require `-TwingateNetwork` and `-ApiToken` but not `-RemoteNetwork` — they discover VMs by name pattern (`TG-Connector-*`).

### Actions

**Deploy** — Creates connectors via the Twingate API, provisions Ubuntu 24.04 Gen2 VMs using cloud-init, and waits for all connectors to report `ALIVE`. On first run, downloads the Ubuntu cloud image (~600 MB) and qemu-img.exe to `VMPath\images` and `VMPath\tools` respectively. These are cached and reused on subsequent runs.

**Remove** — Stops and deletes all VMs matching `TG-Connector-<RemoteNetwork>-*`, removes their disk files, and deletes the corresponding connector records from the Twingate API. Pass `-VMName <name>` to remove just one VM (its connector record and files); in that mode `-RemoteNetwork` is not required. Without `-VMName`, Remove targets all `TG-Connector-<RemoteNetwork>-*` VMs as before. Fail-safe: if the API delete fails, local VM cleanup still proceeds with a warning.

**UpdateConnector** — SSHs into each running VM sequentially and runs `apt-get install twingate-connector` to upgrade to the latest connector package. Verifies the connector reports `ALIVE` before moving to the next VM.

**UpdateOS** — SSHs into each running VM sequentially and runs `apt-get upgrade` to apply all OS updates. Verifies the connector reports `ALIVE` before moving to the next VM.

**List** — Displays all `TG-Connector-*` VMs with their Hyper-V state, IP address, uptime, and connector ID. No API call required.

**FixVM** — Repairs a single connector VM by name (`-VMName`). Checks whether the connector is already `ALIVE` (no-op), installed but stopped (starts it), or missing entirely (creates a **net-new** connector, runs the bootstrap over SSH, and repoints the VM). When it reprovisions, the VM's previous connector record is left in the Twingate Admin Console and flagged in an "ACTION REQUIRED" notice at the end of the run so you can review/remove it manually.

### Usage Examples

```powershell
# Deploy 2 connectors (default) into the "Office" Remote Network
.\Deploy-TwingateConnector.ps1 -Action Deploy -TwingateNetwork "acme" -RemoteNetwork "Office"

# Deploy 4 connectors with more RAM, storing files on D:\
.\Deploy-TwingateConnector.ps1 -Action Deploy -TwingateNetwork "acme" -RemoteNetwork "Office" `
    -ConnectorCount 4 -VMPath D:\VMs -VMMemory 4GB

# List all connector VMs
.\Deploy-TwingateConnector.ps1 -Action List

# Remove all connectors in a Remote Network
.\Deploy-TwingateConnector.ps1 -Action Remove -TwingateNetwork "acme" -RemoteNetwork "Office"

# Update the twingate-connector package on all VMs
.\Deploy-TwingateConnector.ps1 -Action UpdateConnector -TwingateNetwork "acme"

# Update the OS on all VMs
.\Deploy-TwingateConnector.ps1 -Action UpdateOS -TwingateNetwork "acme"

# Pass the API token as a SecureString (avoids plain text in shell history)
.\Deploy-TwingateConnector.ps1 -Action Deploy -TwingateNetwork "acme" -RemoteNetwork "Office" `
    -ApiToken (ConvertTo-SecureString 'your-token' -AsPlainText -Force)

# Repair a single connector VM
.\Deploy-TwingateConnector.ps1 -Action FixVM -TwingateNetwork "acme" -VMName "TG-Connector-NY-1"

# Remove just one VM (RemoteNetwork not required)
.\Deploy-TwingateConnector.ps1 -Action Remove -TwingateNetwork "acme" -VMName "TG-Connector-NY-1"
```

### What the script creates

For each connector, the following is created under `VMPath\TG-Connector-<RemoteNetwork>-<N>\`:

| File | Description |
|---|---|
| `disk.vhdx` | VM OS disk (copy of Ubuntu base image, expanded to 20 GB) |
| `cloud-init.iso` | NoCloud datasource ISO with cloud-init configuration |
| `ssh_key` / `ssh_key.pub` | Per-VM ED25519 SSH keypair |
| `ssh_user.txt` | VM admin username (used by Update actions) |

The Ubuntu `ubuntu` default user is disabled. A randomly generated admin user (`tgadm` + 4 random characters) is created with a 24-character random password. The script prints the credentials to the console at deploy time — save them if you need console/emergency access.

### VM naming convention

VMs are named `TG-Connector-<RemoteNetwork>-<N>`, e.g.:
- `TG-Connector-Office-1`
- `TG-Connector-Office-2`

Discovery in Remove and Update actions uses the `TG-Connector-*` name pattern. Connector IDs are stored in the VM's Notes field.

### Cleanup / reset

Use `Reset-TwingateConnectorEnvironment.ps1` to remove all `TG-Connector-*` VMs, their files, and the `TwingateExternalSwitch` vSwitch in one shot — useful after a failed or interrupted deployment. Cached downloads (`images\` and `tools\`) are intentionally left intact.

```powershell
# Preview what will be removed
.\Reset-TwingateConnectorEnvironment.ps1

# Remove everything without prompting
.\Reset-TwingateConnectorEnvironment.ps1 -Force
```

---

## hyperv-prebuilt-image-connector-installer.ps1 (Legacy)

### Overview

The original script. Downloads a pre-built Ubuntu 22.04 VM archive from GitHub Releases, extracts it, and imports it as a Hyper-V VM. Connector tokens must be generated manually in the Twingate Admin Console and pasted into the script before running.

### When to use

Use this script if:
- You are on a system where the new script's automatic image conversion doesn't work
- You need Ubuntu 22.04 specifically

For all other cases, use `Deploy-TwingateConnector.ps1`.

### Setup

1. In the Twingate Admin Console, create a Connector and copy the **Access Token** and **Refresh Token**.
2. Open `hyperv-prebuilt-image-connector-installer.ps1` and set the three variables at the top:
   ```powershell
   $networkName    = "companyname"   # your Twingate network slug
   $accessToken    = "eyJhbG..."     # access token from the Admin Console
   $refreshToken   = "80zwhs..."     # refresh token from the Admin Console
   ```
3. Run the script as Administrator.

The script downloads the VM archive (~1 GB), extracts it to `C:\twingate-connector-hyperv`, installs Hyper-V if needed, and imports the VM. The VM is named `Ubuntu_Twingate_Connector-22_04`.

### Limitations

- Tokens are hardcoded in the script — rotate them if the script is shared or stored in source control.
- Single connector only — run the script multiple times with different tokens for multiple connectors.
- No lifecycle management (no Remove, Update, or List actions).
- Uses Ubuntu 22.04 LTS (versus 24.04 in the new script).

---

## License

Apache 2.0 — see [LICENSE](../../LICENSE).
