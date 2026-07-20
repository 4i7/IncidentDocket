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
    if (($result.Stderr + "`n" + $result.Stdout) -match '(?i)(no MCP server named|not found|does not exist)') {
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
    $argumentValues = @($transport.args | ForEach-Object { [string]$_ })
    if ($null -ne $transport.PSObject.Properties['type'] -and [string]$transport.type -cne 'stdio') {
        return $false
    }
    if ([string]$transport.command -cne 'incident-docket' -or $argumentValues.Count -ne 1 -or $argumentValues[0] -cne 'mcp') {
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
    $argumentValues = @($transport.args | ForEach-Object { Get-SafeMcpValue $_ })
    $argsText = if ($argumentValues.Count -eq 0) { '[]' } else { '[' + ($argumentValues -join ', ') + ']' }
    Write-Warning ('Current MCP entry was not removed: command=' + (Get-SafeMcpValue $transport.command) + '; args=' + $argsText)
    Write-Warning 'Expected managed entry: command=incident-docket; args=[mcp]; enabled=true when reported.'
}

$failures = New-Object System.Collections.Generic.List[string]

$npmPath = Get-ApplicationPath @('npm.cmd', 'npm')
if ($null -eq $npmPath) {
    Write-Warning 'npm was not found; the global package was not changed.'
    $failures.Add('npm package removal could not run')
}
else {
    try {
        & $npmPath @('uninstall', '--global', 'incident-docket')
        if ($LASTEXITCODE -ne 0) {
            throw 'npm global uninstall failed.'
        }
        Write-Output 'IncidentDocket global package removed if it was installed.'
    }
    catch {
        $failures.Add([string]$_.Exception.Message)
        [Console]::Error.WriteLine(('Package removal failed: ' + [string]$_.Exception.Message))
    }
}

if ($RemoveCodexMcp) {
    $codexPath = Get-ApplicationPath @('codex.cmd', 'codex.exe', 'codex')
    if ($null -eq $codexPath) {
        Write-Warning 'Codex CLI was not found; no MCP registration was changed.'
        $failures.Add('Codex MCP removal could not run')
    }
    else {
        try {
            $state = Get-CodexMcpState -CodexPath $codexPath
            if (-not $state.Exists) {
                Write-Output 'Codex MCP incident_docket was not registered.'
            }
            elseif (-not (Test-ManagedMcpState -State $state)) {
                Write-McpMismatch -State $state
                $failures.Add('The existing incident_docket MCP entry is not owned by this installer and was not removed')
            }
            else {
                $removeResult = Invoke-Codex -CodexPath $codexPath -Arguments @('mcp', 'remove', 'incident_docket')
                if ($removeResult.ExitCode -ne 0) {
                    throw 'Codex MCP removal failed.'
                }
                $after = Get-CodexMcpState -CodexPath $codexPath
                if ($after.Exists) {
                    throw 'Codex MCP removal was not confirmed.'
                }
                Write-Output 'Managed Codex MCP incident_docket entry removed.'
            }
        }
        catch {
            $failures.Add([string]$_.Exception.Message)
            [Console]::Error.WriteLine(('MCP removal failed: ' + [string]$_.Exception.Message))
        }
    }
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine(('IncidentDocket uninstall completed with failures: ' + ($failures -join '; ')))
    exit 1
}

Write-Output 'IncidentDocket uninstall completed. %LOCALAPPDATA%\IncidentDocket case and report files were not removed.'
