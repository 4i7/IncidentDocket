#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$RegisterCodexMcp
)

$ErrorActionPreference = 'Stop'

function Get-ApplicationPath {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $commands = @(Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            $command = $commands[0]
            if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                return $command.Source
            }
            return $command.Path
        }
    }
    return $null
}

function Get-PackageHash {
    param([Parameter(Mandatory = $true)][string]$HashPath)

    $lines = @(Get-Content -LiteralPath $HashPath -Encoding ASCII)
    $matches = @($lines | Where-Object {
            ([string]$_) -cmatch '^(?<hash>[0-9A-Fa-f]{64})\s+incident-docket\.tgz$'
        })
    if ($lines.Count -ne 1 -or $matches.Count -ne 1) {
        throw 'PACKAGE_SHA256.txt must contain exactly one incident-docket.tgz checksum entry.'
    }
    return [regex]::Match(
        [string]$matches[0],
        '^(?<hash>[0-9A-Fa-f]{64})\s+incident-docket\.tgz$'
    ).Groups['hash'].Value.ToUpperInvariant()
}

function Get-InstalledCliPath {
    param([Parameter(Mandatory = $true)][string]$NpmPath)

    $prefixLines = @(& $NpmPath @('prefix', '--global') 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $prefixExitCode = $LASTEXITCODE
    if ($prefixExitCode -ne 0 -or $prefixLines.Count -eq 0) {
        throw 'Unable to resolve the global npm prefix after installation.'
    }
    $prefix = [IO.Path]::GetFullPath($prefixLines[$prefixLines.Count - 1])
    $candidates = @(
        (Join-Path $prefix 'incident-docket.cmd'),
        (Join-Path $prefix 'incident-docket.exe'),
        (Join-Path $prefix 'incident-docket'),
        (Join-Path $prefix 'bin\incident-docket.cmd'),
        (Join-Path $prefix 'bin\incident-docket.exe'),
        (Join-Path $prefix 'bin\incident-docket')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The installed incident-docket command was not found under the global npm prefix.'
}

function Invoke-InstalledCli {
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ([IO.Path]::GetExtension($CliPath) -ieq '.cmd') {
            $quotedPath = '"' + ($CliPath -replace '%', '%%') + '"'
            & $env:ComSpec @('/d', '/s', '/c', 'call', $quotedPath) @Arguments
        }
        else {
            & $CliPath @Arguments
        }
        $script:InstalledCliExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Invoke-Codex {
    param(
        [Parameter(Mandatory = $true)][string]$CodexPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('incident-docket-codex-' + [Guid]::NewGuid().ToString('N') + '.err')
    try {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $stdoutLines = @(& $CodexPath @Arguments 2>$stderrPath | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }
        $stderr = ''
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderrValue = Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
            if ($null -ne $stderrValue) { $stderr = ([string]$stderrValue).Trim() }
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout = ($stdoutLines -join "`n").Trim()
            Stderr = $stderr
        }
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CodexMcpState {
    param([Parameter(Mandatory = $true)][string]$CodexPath)

    $result = Invoke-Codex -CodexPath $CodexPath -Arguments @('mcp', 'get', 'incident_docket', '--json')
    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($result.Stdout)) {
            throw 'Codex returned an empty MCP state.'
        }
        try {
            $config = $result.Stdout | ConvertFrom-Json
        }
        catch {
            throw 'Codex returned invalid MCP JSON.'
        }
        return [pscustomobject]@{ Exists = $true; Config = $config }
    }

    if ($result.Stderr -match '(?i)(no MCP server named|not found|does not exist)') {
        return [pscustomobject]@{ Exists = $false; Config = $null }
    }
    throw 'Codex MCP state inspection failed.'
}

function Test-ManagedMcpState {
    param([Parameter(Mandatory = $true)]$State)

    if (-not $State.Exists -or $null -eq $State.Config.transport) {
        return $false
    }
    $transport = $State.Config.transport
    $command = [string]$transport.command
    $args = @($transport.args | ForEach-Object { [string]$_ })
    if ($null -ne $transport.PSObject.Properties['type'] -and [string]$transport.type -cne 'stdio') {
        return $false
    }
    if ($command -cne 'incident-docket' -or $args.Count -ne 1 -or $args[0] -cne 'mcp') {
        return $false
    }
    $enabledProperty = $State.Config.PSObject.Properties['enabled']
    if ($null -ne $enabledProperty -and $State.Config.enabled -ne $true) {
        return $false
    }
    return $true
}

function Get-SafeMcpValue {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return '<empty>' }
    if ($text -match '^[A-Za-z0-9._-]{1,64}$') { return $text }
    return '<redacted>'
}

function Write-McpMismatch {
    param([Parameter(Mandatory = $true)]$State)

    $transport = $State.Config.transport
    $args = @($transport.args | ForEach-Object { Get-SafeMcpValue $_ })
    $argsText = if ($args.Count -eq 0) { '[]' } else { '[' + ($args -join ', ') + ']' }
    Write-Output ('Current MCP entry: command=' + (Get-SafeMcpValue $transport.command) + '; args=' + $argsText)
    Write-Output 'Expected MCP entry: command=incident-docket; args=[mcp]; enabled=true when reported.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packagePath = Join-Path $scriptRoot 'incident-docket.tgz'
$hashPath = Join-Path $scriptRoot 'PACKAGE_SHA256.txt'
$stage = 'preflight'
$packageInstallStarted = $false
$packageInstalled = $false

try {
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw 'incident-docket.tgz was not found beside install.ps1.'
    }
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        throw 'PACKAGE_SHA256.txt was not found beside install.ps1.'
    }

    $stage = 'Node.js preflight'
    $nodePath = Get-ApplicationPath @('node.exe', 'node')
    if ($null -eq $nodePath) {
        throw 'Node.js 22 or later is required; install Node.js and rerun the installer.'
    }
    $nodeVersionText = (& $nodePath '--version' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersionText -notmatch '^v(\d+)\.(\d+)\.(\d+)') {
        throw 'Unable to determine the Node.js version.'
    }
    if ([int]$Matches[1] -lt 22) {
        throw 'Node.js 22 or later is required.'
    }

    $stage = 'npm preflight'
    $npmPath = Get-ApplicationPath @('npm.cmd', 'npm')
    if ($null -eq $npmPath) {
        throw 'npm was not found; install Node.js with npm and rerun the installer.'
    }

    $codexPath = $null
    if ($RegisterCodexMcp) {
        $stage = 'Codex CLI preflight'
        $codexPath = Get-ApplicationPath @('codex.cmd', 'codex.exe', 'codex')
        if ($null -eq $codexPath) {
            throw 'Codex CLI is required with -RegisterCodexMcp. Install Codex CLI, open a new PowerShell, then rerun this installer (or rerun without the flag for package-only installation).'
        }
    }

    $stage = 'package checksum verification'
    $expectedHash = Get-PackageHash -HashPath $hashPath
    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -cne $expectedHash) {
        throw 'Package hash mismatch; npm was not started.'
    }

    $stage = 'npm install'
    $packageInstallStarted = $true
    & $npmPath @('install', '--global', $packagePath)
    if ($LASTEXITCODE -ne 0) {
        throw 'npm global installation failed.'
    }
    $packageInstalled = $true

    $stage = 'fixture demo'
    $cliPath = Get-InstalledCliPath -NpmPath $npmPath
    Invoke-InstalledCli -CliPath $cliPath -Arguments @('demo', '--fixture', 'gpu-driver-reset')
    if ($script:InstalledCliExitCode -ne 0) {
        throw 'Fixture demo failed; the package may be installed but is not verified.'
    }

    if ($RegisterCodexMcp) {
        $stage = 'Codex MCP inspection'
        $state = Get-CodexMcpState -CodexPath $codexPath
        if ($state.Exists) {
            if (-not (Test-ManagedMcpState -State $state)) {
                Write-McpMismatch -State $state
                throw 'The existing incident_docket MCP entry is different and was not changed. Review it, then rerun the installer.'
            }
            Write-Output 'Codex MCP incident_docket is already registered correctly; no duplicate was created.'
        }
        else {
            $stage = 'Codex MCP add'
            $addResult = Invoke-Codex -CodexPath $codexPath -Arguments @('mcp', 'add', 'incident_docket', '--', 'incident-docket', 'mcp')
            if ($addResult.ExitCode -ne 0) {
                throw 'Codex MCP registration failed; the package remains installed and the MCP entry was not confirmed.'
            }
            $stage = 'Codex MCP post-add validation'
            $state = Get-CodexMcpState -CodexPath $codexPath
            if (-not (Test-ManagedMcpState -State $state)) {
                if ($state.Exists) { Write-McpMismatch -State $state }
                throw 'Codex MCP registration did not produce the expected command and args; the package remains installed.'
            }
            Write-Output 'Codex MCP incident_docket registered and verified.'
        }
        Write-Output 'Restart Codex, then confirm the four IncidentDocket tools are available: plan_collection, collect_incident_window, inspect_evidence, export_support_report.'
    }

    Write-Output 'IncidentDocket installation and fixture verification completed.'
}
catch {
    $message = [string]$_.Exception.Message
    [Console]::Error.WriteLine(('IncidentDocket installation failed during ' + $stage + ': ' + $message))
    if ($packageInstallStarted) {
        [Console]::Error.WriteLine('No automatic rollback was attempted. If this run should be removed, review the global package and run: npm uninstall --global incident-docket')
    }
    if ($RegisterCodexMcp -and $stage -like 'Codex MCP*') {
        [Console]::Error.WriteLine('Review the existing MCP entry with: codex mcp get incident_docket --json')
        [Console]::Error.WriteLine('Only after reviewing it, correct it manually with: codex mcp remove incident_docket; codex mcp add incident_docket -- incident-docket mcp')
    }
    exit 1
}
