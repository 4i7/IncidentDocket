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

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$packagePath = Join-Path $scriptRoot 'incident-docket.tgz'
$hashPath = Join-Path $scriptRoot 'PACKAGE_SHA256.txt'

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
    throw 'incident-docket.tgz was not found beside install.ps1.'
}
if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
    throw 'PACKAGE_SHA256.txt was not found beside install.ps1.'
}

$nodePath = Get-ApplicationPath @('node.exe', 'node')
if ($null -eq $nodePath) {
    throw 'Node.js 22 or later is required; node was not found.'
}
$nodeVersionText = (& $nodePath '--version' 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersionText -notmatch '^v(\d+)\.(\d+)\.(\d+)') {
    throw 'Unable to determine the Node.js version.'
}
if ([int]$Matches[1] -lt 22) {
    throw 'Node.js 22 or later is required.'
}

$npmPath = Get-ApplicationPath @('npm.cmd', 'npm')
if ($null -eq $npmPath) {
    throw 'npm was not found.'
}

$hashText = Get-Content -LiteralPath $hashPath -Raw -Encoding UTF8
$hashMatches = [regex]::Matches($hashText, '(?i)(?<![0-9a-f])([0-9a-f]{64})(?![0-9a-f])')
if ($hashMatches.Count -ne 1) {
    throw 'PACKAGE_SHA256.txt does not contain exactly one SHA-256 value.'
}
$expectedHash = $hashMatches[0].Groups[1].Value.ToUpperInvariant()
$actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualHash -ne $expectedHash) {
    throw 'Package hash mismatch; installation was not performed.'
}

& $npmPath @('install', '--global', $packagePath)
if ($LASTEXITCODE -ne 0) {
    throw 'npm global installation failed.'
}

$cliPath = Get-ApplicationPath @('incident-docket.cmd', 'incident-docket.exe', 'incident-docket')
if ($null -eq $cliPath) {
    $prefixText = (& $npmPath @('prefix', '--global') 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefixText)) {
        $candidate = Join-Path $prefixText 'incident-docket.cmd'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $cliPath = $candidate
        }
    }
}
if ($null -eq $cliPath) {
    throw 'The installed incident-docket command was not found.'
}

& $cliPath @('demo', '--fixture', 'gpu-driver-reset')
if ($LASTEXITCODE -ne 0) {
    throw 'Fixture demo failed; installation is not considered successful.'
}

if ($RegisterCodexMcp) {
    $codexPath = Get-ApplicationPath @('codex.cmd', 'codex.exe', 'codex')
    if ($null -eq $codexPath) {
        Write-Warning 'Codex CLI was not found. Package installation and fixture verification succeeded; MCP registration remains incomplete.'
    }
    else {
        $stateText = (& $codexPath @('mcp', 'get', 'incident_docket') 2>&1 | Out-String).Trim()
        $stateExitCode = $LASTEXITCODE
        if ($stateExitCode -eq 0) {
            Write-Output 'Codex MCP incident_docket is already registered; no duplicate was created.'
            if (-not [string]::IsNullOrWhiteSpace($stateText)) {
                Write-Output $stateText
            }
        }
        else {
            & $codexPath @('mcp', 'add', 'incident_docket', '--', 'incident-docket', 'mcp')
            if ($LASTEXITCODE -ne 0) {
                throw 'Codex MCP registration failed.'
            }
            Write-Output 'Codex MCP incident_docket registered.'
        }
    }
}

Write-Output 'IncidentDocket installation and fixture verification completed.'
