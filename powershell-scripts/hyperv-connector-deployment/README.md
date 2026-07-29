# Moved — Twingate Connector Hyper-V Deployment Scripts

> **These scripts now live in their own repository:**
>
> 👉 **[Twingate-Solutions/twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv)**

This folder is retained only so that existing links and bookmarks land somewhere useful. There is no code here anymore.

## What moved

| File | New location |
|---|---|
| `Deploy-TwingateConnector.ps1` | [twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv) (repo root) |
| `Reset-TwingateConnectorEnvironment.ps1` | [twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv) (repo root) |
| `hyperv-prebuilt-image-connector-installer.ps1` | [twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv) (repo root) |
| `tests/` | [twingate-connector-hyperv](https://github.com/Twingate-Solutions/twingate-connector-hyperv) `tests/` |

A duplicate copy of `hyperv-prebuilt-image-connector-installer.ps1` also previously existed at `powershell-scripts/hyperv-prebuilt-image-connector-installer.ps1`. It has been removed as well.

## Why

The Hyper-V connector deployment tooling grew into a standalone project with its own documentation, Pester test suite, and release cadence. It no longer fits the "small, self-contained script" model that the rest of this repository follows.

## Notes for existing users

- **Full documentation** — parameters, all six lifecycle actions (Deploy, Remove, UpdateConnector, UpdateOS, List, FixVM), and usage examples — is in the README of the new repository.
- **Git history** for these files remains available in this repository. Browse it at
  `https://github.com/Twingate-Solutions/general-scripts/commits/main/powershell-scripts/hyperv-connector-deployment`
- **The legacy pre-built VM image** is still published as a release asset on *this* repository
  (`releases/download/hyperv-image/Ubuntu_Twingate_Connector-22_04.zip`). That release is
  intentionally being kept in place so copies of the legacy script already deployed in the field
  continue to work. Do not delete it.
