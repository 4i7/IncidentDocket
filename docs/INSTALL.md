# IncidentDocket installation

## Prerequisites and network boundary

- Node.js 22 or later, including npm.
- Windows 11 is required for live collection; the fixture demo also works on macOS and Linux.
- Codex CLI is required only when registering the MCP server.
- Network access is needed to download the Release assets and may be needed by npm to resolve the package's production dependencies. The installer itself does not download scripts or run live collection.

## Recommended Windows setup

Download both `incident-docket-windows-setup.zip` and `SHA256SUMS.txt` from the same [latest Release](https://github.com/4i7/IncidentDocket/releases/latest) into a directory you control. Verify the ZIP before extracting or running anything from it:

```powershell
$matches = @(
  Get-Content .\SHA256SUMS.txt |
  Where-Object { $_ -match '^[0-9A-Fa-f]{64}\s+incident-docket-windows-setup\.zip$' }
)

if ($matches.Count -ne 1) {
  throw "Expected exactly one checksum entry for incident-docket-windows-setup.zip."
}

$expected = (($matches[0] -split '\s+')[0]).ToLowerInvariant()
$actual = (Get-FileHash .\incident-docket-windows-setup.zip -Algorithm SHA256).Hash.ToLowerInvariant()

if ($actual -ne $expected) {
  throw "Setup ZIP checksum mismatch. Do not extract or run it."
}

Expand-Archive .\incident-docket-windows-setup.zip .\incident-docket-setup -Force
Set-Location .\incident-docket-setup

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -RegisterCodexMcp
```

`ExecutionPolicy Bypass` applies only to this new PowerShell process. Do not use `Set-ExecutionPolicy`; `Unblock-File` is not required. This process-scoped command is intended for a checksum-verified ZIP when a Restricted policy or Mark-of-the-Web attachment would otherwise block the extracted script. Never pipe a downloaded script to `Invoke-Expression` or `iex`.

The installer verifies the bundled `incident-docket.tgz`, installs that exact local file globally, runs the synthetic fixture demo, and then handles MCP registration. It never starts live collection and does not request administrator elevation.

If `-RegisterCodexMcp` is supplied and Codex CLI is missing, the installer fails before npm starts. Install Codex CLI and rerun the command, or rerun without the flag for package-only installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

After a successful registration, restart Codex and manually confirm these four tools are available: `plan_collection`, `collect_incident_window`, `inspect_evidence`, and `export_support_report`.

## Manual tarball install

Download `incident-docket.tgz` and `SHA256SUMS.txt` from the same Release into one directory. Verify and install the same local file; do not replace it with a latest-download URL after verification:

```powershell
$matches = @(
  Get-Content .\SHA256SUMS.txt |
  Where-Object { $_ -match '^[0-9A-Fa-f]{64}\s+incident-docket\.tgz$' }
)

if ($matches.Count -ne 1) {
  throw "Expected exactly one checksum entry for incident-docket.tgz."
}

$expected = (($matches[0] -split '\s+')[0]).ToLowerInvariant()
$actual = (Get-FileHash .\incident-docket.tgz -Algorithm SHA256).Hash.ToLowerInvariant()

if ($actual -ne $expected) {
  throw "Package checksum mismatch."
}

npm install --global .\incident-docket.tgz
incident-docket demo --fixture gpu-driver-reset
```

## MCP registration and failure recovery

The installer uses the current Codex CLI JSON inspection command:

```powershell
codex mcp get incident_docket --json
```

An absent entry is added as `codex mcp add incident_docket -- incident-docket mcp` and then read back and checked. A correct existing entry is left unchanged. An existing entry with a different command or args is never removed or overwritten; inspect it, correct it manually, and rerun the installer. The expected entry is command `incident-docket`, args `['mcp']`, and enabled when Codex reports an enabled state.

If npm installation, fixture verification, MCP add, or post-add validation fails, the installer exits non-zero and names the failed stage. No automatic rollback is attempted. Review the global package before using the recovery command `npm uninstall --global incident-docket`; review an existing MCP entry before any manual `codex mcp remove`.

## Fixture and live collection

The fixture demo works on Node.js 22 or later on Windows, macOS, and Linux. Live collection requires Windows 11 and Windows PowerShell 5.1. OS and display-driver snapshots describe collection-time context and do not prove incident-time causation.

## Updating

Download and checksum-verify a new setup ZIP, extract it, and run `install.ps1` again. The installer verifies the bundled package before installing it.

## Uninstalling

From an extracted setup ZIP, remove the global package:

```powershell
.\uninstall.ps1
```

To also remove the IncidentDocket MCP registration:

```powershell
.\uninstall.ps1 -RemoveCodexMcp
```

Package removal and MCP removal are independent. The script removes an MCP entry only when its inspected command is exactly `incident-docket` with args `['mcp']`; an unrelated same-name entry is preserved and reported. Missing npm, package, Codex, or MCP entry is handled as an idempotent/partial result without automatic elevation.

Case and report data under the symbolic path `%LOCALAPPDATA%\IncidentDocket` are intentionally retained. Review the files for privacy, then remove them manually if desired; uninstall does not delete user evidence automatically.

## Hash verification and privacy

`SHA256SUMS.txt` covers `incident-docket.tgz` and `incident-docket-windows-setup.zip`. The setup ZIP includes `PACKAGE_SHA256.txt` for the exact bundled tarball. Masking is not complete anonymization: review every timeline and report before sharing, and do not publish real machine/user data or a Codex Session ID.
