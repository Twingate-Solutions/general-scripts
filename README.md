# General Scripts

Twingate Solutions Engineering's collection of small, self-contained operational
scripts — client deployment, log/report parsing, gateway setup, and diagnostics.

Each folder is its own mini-project with its own README explaining its purpose and
usage. Start there; this page is just the index.

> ⚠️ **Reference scripts — provided as-is, with no support or warranty.** These scripts are published as reference examples to build from, not a supported product. Nothing here is guaranteed and no support is attached to it. They were developed with help from an LLM-based coding assistant. Review the code and test it yourself before using it in any critical or production environment. Your use is governed by the Apache License 2.0, including its "AS IS", no-warranty (Section 7), and limitation-of-liability (Section 8) terms.

## Folder Index

| Folder | Purpose | Platform | Language |
| --- | --- | --- | --- |
| [`bash-scripts/`](bash-scripts/) | macOS/Linux Twingate client diagnostics & admin helpers | macOS/Linux | Bash |
| [`powershell-scripts/`](powershell-scripts/) | Windows Twingate client deployment & lifecycle scripts (Intune/MDM) | Windows | PowerShell |
| [`powershell-scripts/autopilot-scripting/`](powershell-scripts/autopilot-scripting/) | Ship headless Windows machines that self-promote to the user-mode client on first logon | Windows | PowerShell |
| [`powershell-scripts/hyperv-connector-deployment/`](powershell-scripts/hyperv-connector-deployment/) | **Moved** — now [Twingate-Solutions/twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv) | Windows | PowerShell |
| [`twingate-headless-client-gateway/`](twingate-headless-client-gateway/) | Configure a Linux box as a whole-network Twingate gateway + DNS for IoT/unmanaged devices | Linux | Bash |
| [`filter-network-events-report/`](filter-network-events-report/) | Filter a Network Events report CSV down to a single user's events | Cross-platform | Python |
| [`unique_ports/`](unique_ports/) | Extract unique host:port combinations actually accessed, from a Network Events report | Cross-platform | Python |
| [`remove-users/`](remove-users/) | Bulk-remove all users from a Twingate group via the Twingate CLI | Linux/macOS | Bash |
| [`internet-security-include-only-group/`](internet-security-include-only-group/) | Populate an exclude group from an include group for an Internet Security rollout, via the Twingate CLI | Linux/macOS | Bash |

## Conventions

- **Templates, not turnkey products.** Most scripts here are starting points for
  admins to read, test on throwaway systems, and adapt to their own environment —
  not fully supported, drop-in tools. Treat each one as a basis to build from.
- **Secrets never get committed.** Twingate API tokens and service keys are
  secrets. Pass them at runtime (arguments, environment variables, or a local file
  excluded from git) — never hardcode them into a script or commit them to this
  repo.
- **One folder, one README.** New scripts should follow the same pattern —
  see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

Apache 2.0 — see [`LICENSE`](LICENSE).
