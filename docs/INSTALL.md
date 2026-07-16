# IncidentDocket installation

## Prerequisites

- Node.js 22 or later
- npm
- Codex CLI only when using the MCP workflow

Installing the package does not start live collection. Live collection is an explicit MCP operation and is supported only on Windows 11.

## Recommended Windows setup

1. Download `incident-docket-windows-setup.zip` from the latest Release.
2. Extract the ZIP to a directory you control.
3. In PowerShell, run:

```powershell
.\install.ps1 -RegisterCodexMcp
```

The installer validates `PACKAGE_SHA256.txt`, installs the bundled tarball globally, and runs the synthetic fixture demo. It does not request administrator elevation or collect live evidence.

If Codex CLI is not installed, package installation and fixture verification still complete; run the MCP registration command after installing Codex.

## Manual tarball install

Download `incident-docket.tgz` and verify its SHA-256 value against `SHA256SUMS.txt`, then run:

```powershell
npm install --global .\incident-docket.tgz
incident-docket demo --fixture gpu-driver-reset
```

## MCP registration

Codex is needed only for the MCP reasoning workflow:

```powershell
codex mcp add incident_docket -- incident-docket mcp
```

The server exposes `plan_collection`, `collect_incident_window`, `inspect_evidence`, and `export_support_report` over stdio.

## Fixture and live collection

The fixture demo works on Node.js 22 or later on Windows, macOS, and Linux. Live collection requires Windows 11 and Windows PowerShell 5.1. OS and display-driver snapshots describe collection-time context and do not prove incident-time causation.

## Updating

Download the new setup ZIP from the latest Release and run `install.ps1` again. The installer verifies the bundled package before replacing the global installation.

## Uninstalling

From an extracted setup ZIP, run:

```powershell
.\uninstall.ps1
```

To remove the IncidentDocket Codex MCP registration as well:

```powershell
.\uninstall.ps1 -RemoveCodexMcp
```

Both operations are safe to repeat when the package or MCP entry is absent.

## Hash verification

`SHA256SUMS.txt` covers the two Release assets. The setup ZIP also includes `PACKAGE_SHA256.txt`; `install.ps1` refuses to install when the bundled tarball hash does not match.

## Privacy boundary

IncidentDocket accepts only allowlisted fields, masks known sensitive identifiers, and never returns raw collector output. Masking is not complete anonymization. Review every timeline and report before sharing it, and never place real machine or user data in fixtures or commits.

## Troubleshooting

- If Node.js or npm is missing, install Node.js 22 or later and rerun the installer.
- If the package hash fails, download the complete setup ZIP again and compare it with `SHA256SUMS.txt`.
- If the fixture demo fails, fix the reported installation or PATH issue before using MCP.
- If Codex registration is incomplete, run the registration command manually after installing Codex CLI.
