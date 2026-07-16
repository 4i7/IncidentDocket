#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$RemoveCodexMcp
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

$npmPath = Get-ApplicationPath @('npm.cmd', 'npm')
if ($null -eq $npmPath) {
    throw 'npm was not found; the global package was not changed.'
}

& $npmPath @('uninstall', '--global', 'incident-docket')
if ($LASTEXITCODE -ne 0) {
    throw 'npm global uninstall failed.'
}
Write-Output 'IncidentDocket global package removed if it was installed.'

if ($RemoveCodexMcp) {
    $codexPath = Get-ApplicationPath @('codex.cmd', 'codex.exe', 'codex')
    if ($null -eq $codexPath) {
        Write-Warning 'Codex CLI was not found; no MCP registration was changed.'
    }
    else {
        $stateText = (& $codexPath @('mcp', 'get', 'incident_docket') 2>&1 | Out-String).Trim()
        $stateExitCode = $LASTEXITCODE
        if ($stateExitCode -ne 0) {
            Write-Output 'Codex MCP incident_docket was not registered.'
        }
        else {
            & $codexPath @('mcp', 'remove', 'incident_docket')
            if ($LASTEXITCODE -ne 0) {
                throw 'Codex MCP removal failed.'
            }
            Write-Output 'Codex MCP incident_docket removed.'
        }
    }
}
