#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$releaseDir = Join-Path $repoRoot 'artifacts\release'
$installScript = Join-Path $scriptRoot 'install.ps1'
$uninstallScript = Join-Path $scriptRoot 'uninstall.ps1'
$powershellPath = (@(Get-Command powershell.exe -CommandType Application)[0]).Source
$nodePath = (@(Get-Command node.exe -CommandType Application)[0]).Source
$npmPath = (@(Get-Command npm.cmd -CommandType Application)[0]).Source
$originalEnvironment = @{}
$environmentNames = @(
    'Path', 'npm_config_prefix', 'CODEX_HOME', 'LOCALAPPDATA',
    'FAKE_NPM_SCRIPT', 'FAKE_NPM_PREFIX', 'FAKE_NPM_MARKER', 'FAKE_NPM_MODE',
    'FAKE_CLI_MODE', 'FAKE_DEMO_MARKER', 'FAKE_CODEX_SCRIPT', 'FAKE_CODEX_STATE',
    'FAKE_CODEX_MODE', 'FAKE_CODEX_ADD_MARKER', 'STALE_MARKER'
)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IncidentDocket-release-acceptance-' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Set-EnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value) {
        Remove-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath ('Env:' + $Name) -Value $Value
    }
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [AllowNull()][string]$PathValue,
        [AllowNull()][string]$NpmPrefix,
        [AllowNull()][string]$CodexHome,
        [AllowNull()][string]$LocalAppData,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $stdoutPath = Join-Path $testRoot ($Label + '-' + [Guid]::NewGuid().ToString('N') + '.stdout')
    $stderrPath = Join-Path $testRoot ($Label + '-' + [Guid]::NewGuid().ToString('N') + '.stderr')
    $oldValues = @{}
    foreach ($name in @('Path', 'npm_config_prefix', 'CODEX_HOME', 'LOCALAPPDATA')) {
        $oldValues[$name] = if (Test-Path -LiteralPath ('Env:' + $name)) { [string](Get-Item -LiteralPath ('Env:' + $name)).Value } else { $null }
    }
    try {
        Set-EnvironmentValue -Name 'Path' -Value $PathValue
        Set-EnvironmentValue -Name 'npm_config_prefix' -Value $NpmPrefix
        Set-EnvironmentValue -Name 'CODEX_HOME' -Value $CodexHome
        Set-EnvironmentValue -Name 'LOCALAPPDATA' -Value $LocalAppData
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $FilePath @Arguments 1>$stdoutPath 2>$stderrPath
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $oldPreference
            }
        }
        finally {
            Pop-Location
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout = Read-Text -Path $stdoutPath
            Stderr = Read-Text -Path $stderrPath
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
        }
    }
    finally {
        foreach ($name in $oldValues.Keys) {
            Set-EnvironmentValue -Name $name -Value $oldValues[$name]
        }
    }
}

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return $Path
}

function Copy-Setup {
    param([Parameter(Mandatory = $true)][string]$Destination)
    New-Directory -Path $Destination | Out-Null
    Expand-Archive -LiteralPath (Join-Path $releaseDir 'incident-docket-windows-setup.zip') -DestinationPath $Destination -Force
    return $Destination
}

function Get-ChecksumEntry {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    $lines = @(Get-Content -LiteralPath $Path -Encoding ASCII)
    $matches = @($lines | Where-Object { ([string]$_) -cmatch ('^[0-9A-Fa-f]{64}\s+' + [regex]::Escape($Name) + '$') })
    Assert-True ($matches.Count -eq 1) ('Expected exactly one checksum entry for ' + $Name)
    return [regex]::Match([string]$matches[0], '^(?<hash>[0-9A-Fa-f]{64})').Groups['hash'].Value.ToUpperInvariant()
}

function Get-AssetHashes {
    $result = [ordered]@{}
    foreach ($name in @('incident-docket.tgz', 'incident-docket-windows-setup.zip', 'SHA256SUMS.txt')) {
        $path = Join-Path $releaseDir $name
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) ('Missing release asset: ' + $name)
        $result[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    return $result
}

function Get-EntryHash {
    param([Parameter(Mandatory = $true)][System.IO.Compression.ZipArchiveEntry]$Entry)
    $stream = $Entry.Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Write-FakeCommandWrappers {
    param([Parameter(Mandatory = $true)][string]$Directory)
    New-Directory -Path $Directory | Out-Null
    $npmScript = Join-Path $Directory 'fake-npm.ps1'
    $npmWrapper = Join-Path $Directory 'npm.cmd'
    $codexScript = Join-Path $Directory 'fake-codex.ps1'
    $codexWrapper = Join-Path $Directory 'codex.cmd'

    $npmScriptText = @'
param([string[]]$CommandLine)
$command = if ($CommandLine.Count -gt 0) { [string]$CommandLine[0] } else { '' }
if ($command -ieq 'install') {
    if ($env:FAKE_NPM_MODE -ieq 'fail') { exit 7 }
    New-Item -ItemType Directory -Path $env:FAKE_NPM_PREFIX -Force | Out-Null
    if ($env:FAKE_NPM_MARKER) { [IO.File]::WriteAllText($env:FAKE_NPM_MARKER, 'install') }
    $cli = Join-Path $env:FAKE_NPM_PREFIX 'incident-docket.cmd'
    $cliText = @(
        '@echo off',
        'if /I "%1"=="demo" (',
        '  if /I "%FAKE_CLI_MODE%"=="fail" exit /b 9',
        '  if not "%FAKE_DEMO_MARKER%"=="" echo demo>"%FAKE_DEMO_MARKER%"',
        ')',
        'exit /b 0',
        ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($cli, $cliText, [Text.Encoding]::ASCII)
    exit 0
}
if ($command -ieq 'prefix') { Write-Output $env:FAKE_NPM_PREFIX; exit 0 }
if ($command -ieq 'uninstall') { exit 0 }
exit 0
'@
    [IO.File]::WriteAllText($npmScript, $npmScriptText, [Text.Encoding]::UTF8)
    $npmWrapperText = '@echo off' + "`r`n" + '"' + $powershellPath + '" -NoProfile -ExecutionPolicy Bypass -File "%FAKE_NPM_SCRIPT%" %*' + "`r`n" + 'exit /b %ERRORLEVEL%' + "`r`n"
    [IO.File]::WriteAllText($npmWrapper, $npmWrapperText, [Text.Encoding]::ASCII)

    $codexScriptText = @'
param([string[]]$CommandLine)
$state = $env:FAKE_CODEX_STATE
if ($env:FAKE_CODEX_OPERATION -ieq 'get') {
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) {
        [Console]::Error.WriteLine("Error: No MCP server named 'incident_docket' found.")
        exit 1
    }
    Get-Content -LiteralPath $state -Raw -Encoding UTF8
    exit 0
}
if ($env:FAKE_CODEX_OPERATION -ieq 'add') {
    if ($env:FAKE_CODEX_ADD_MARKER) { [IO.File]::WriteAllText($env:FAKE_CODEX_ADD_MARKER, 'add') }
    if ($env:FAKE_CODEX_MODE -ieq 'bad-add') {
        [IO.File]::WriteAllText($state, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"wrong","args":["bad"]}}')
    }
    else {
        [IO.File]::WriteAllText($state, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"incident-docket","args":["mcp"]}}')
    }
    exit 0
}
if ($env:FAKE_CODEX_OPERATION -ieq 'remove') {
    if (Test-Path -LiteralPath $state -PathType Leaf) { Remove-Item -LiteralPath $state -Force }
    exit 0
}
[Console]::Error.WriteLine('Unsupported fake Codex command.')
exit 2
'@
    [IO.File]::WriteAllText($codexScript, $codexScriptText, [Text.Encoding]::UTF8)
    $codexWrapperText = @(
        '@echo off',
        'set "FAKE_CODEX_OPERATION="',
        'if /I "%1"=="mcp" if /I "%2"=="get" set "FAKE_CODEX_OPERATION=get"',
        'if /I "%1"=="mcp" if /I "%2"=="add" set "FAKE_CODEX_OPERATION=add"',
        'if /I "%1"=="mcp" if /I "%2"=="remove" set "FAKE_CODEX_OPERATION=remove"',
        ('"' + $powershellPath + '" -NoProfile -ExecutionPolicy Bypass -File "%FAKE_CODEX_SCRIPT%"'),
        'exit /b %ERRORLEVEL%',
        ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($codexWrapper, $codexWrapperText, [Text.Encoding]::ASCII)
    return [pscustomobject]@{ Directory = $Directory; NpmScript = $npmScript; CodexScript = $codexScript }
}

function Set-FakeEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$FakeRoot,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$LocalAppData,
        [Parameter(Mandatory = $true)][string]$PathValue,
        [AllowNull()][string]$StatePath,
        [AllowNull()][string]$NpmMode,
        [AllowNull()][string]$CliMode,
        [AllowNull()][string]$CodexMode,
        [AllowNull()][string]$NpmMarker,
        [AllowNull()][string]$DemoMarker,
        [AllowNull()][string]$AddMarker,
        [AllowNull()][string]$StaleMarker
    )
    Set-EnvironmentValue -Name 'Path' -Value $PathValue
    Set-EnvironmentValue -Name 'FAKE_NPM_SCRIPT' -Value (Join-Path $FakeRoot 'fake-npm.ps1')
    Set-EnvironmentValue -Name 'FAKE_NPM_PREFIX' -Value $Prefix
    Set-EnvironmentValue -Name 'FAKE_NPM_MARKER' -Value $NpmMarker
    Set-EnvironmentValue -Name 'FAKE_NPM_MODE' -Value $NpmMode
    Set-EnvironmentValue -Name 'FAKE_CLI_MODE' -Value $CliMode
    Set-EnvironmentValue -Name 'FAKE_DEMO_MARKER' -Value $DemoMarker
    Set-EnvironmentValue -Name 'FAKE_CODEX_SCRIPT' -Value (Join-Path $FakeRoot 'fake-codex.ps1')
    Set-EnvironmentValue -Name 'FAKE_CODEX_STATE' -Value $StatePath
    Set-EnvironmentValue -Name 'FAKE_CODEX_MODE' -Value $CodexMode
    Set-EnvironmentValue -Name 'FAKE_CODEX_ADD_MARKER' -Value $AddMarker
    Set-EnvironmentValue -Name 'STALE_MARKER' -Value $StaleMarker
    Set-EnvironmentValue -Name 'LOCALAPPDATA' -Value $LocalAppData
}

function Invoke-ReleaseBuild {
    $outPath = Join-Path $testRoot ('build-' + [Guid]::NewGuid().ToString('N') + '.out')
    $errPath = Join-Path $testRoot ('build-' + [Guid]::NewGuid().ToString('N') + '.err')
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $powershellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptRoot 'build-release.ps1') 1>$outPath 2>$errPath
        $buildExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    Assert-True ($buildExitCode -eq 0) ('build-release.ps1 failed: ' + (Read-Text $errPath))
}

function Invoke-McpSmoke {
    param([Parameter(Mandatory = $true)][string]$EntryPath, [Parameter(Mandatory = $true)][string]$StorageRoot)
    $outPath = Join-Path $testRoot 'packed-mcp-smoke.out'
    $errPath = Join-Path $testRoot 'packed-mcp-smoke.err'
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $nodePath (Join-Path $repoRoot 'scripts/test-packed-mcp.mjs') $EntryPath $StorageRoot 1>$outPath 2>$errPath
        $smokeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    Assert-True ($smokeExitCode -eq 0) ('Packed MCP smoke failed: ' + (Read-Text $errPath))
    return Read-Text $outPath
}

try {
    New-Directory -Path $testRoot | Out-Null
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = if (Test-Path -LiteralPath ('Env:' + $name)) { [string](Get-Item -LiteralPath ('Env:' + $name)).Value } else { $null }
    }

    Write-Output '1. Reproducible release build and ZIP validation'
    Invoke-ReleaseBuild
    $hashFirst = Get-AssetHashes
    Invoke-ReleaseBuild
    $hashSecond = Get-AssetHashes
    foreach ($name in $hashFirst.Keys) {
        Assert-True ($hashFirst[$name] -ceq $hashSecond[$name]) ('Consecutive build hash mismatch: ' + $name)
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $releaseDir 'incident-docket-windows-setup.zip'
    $zipStream = [IO.File]::OpenRead($zipPath)
    $zipArchive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read, $false, [Text.Encoding]::UTF8)
    try {
        $expectedNames = @('incident-docket.tgz', 'install.ps1', 'uninstall.ps1', 'INSTALL.md', 'LICENSE', 'PACKAGE_SHA256.txt')
        Assert-True ($zipArchive.Entries.Count -eq $expectedNames.Count) 'ZIP entry count mismatch.'
        for ($index = 0; $index -lt $expectedNames.Count; $index++) {
            $entry = $zipArchive.Entries[$index]
            Assert-True ($entry.FullName -ceq $expectedNames[$index]) ('ZIP entry order mismatch at index ' + $index)
            Assert-True ($entry.FullName -notmatch '(^|/|\\)\.\.?(/|\\|$)') 'ZIP traversal entry found.'
            Assert-True (-not $entry.FullName.EndsWith('/')) 'ZIP directory entry found.'
            Assert-True ($entry.LastWriteTime.DateTime -eq [DateTime]::Parse('2000-01-01T00:00:00')) 'ZIP timestamp is not fixed.'
        }
        $tgzHash = (Get-FileHash -LiteralPath (Join-Path $releaseDir 'incident-docket.tgz') -Algorithm SHA256).Hash.ToUpperInvariant()
        $tgzEntry = $zipArchive.Entries | Where-Object { $_.FullName -ceq 'incident-docket.tgz' }
        Assert-True ((Get-EntryHash -Entry $tgzEntry) -ceq $tgzHash) 'ZIP tarball hash mismatch.'
        $packageHashEntry = $zipArchive.Entries | Where-Object { $_.FullName -ceq 'PACKAGE_SHA256.txt' }
        $packageHashStream = $packageHashEntry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($packageHashStream, [Text.Encoding]::ASCII, $false)
            try { $packageHashText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $packageHashStream.Dispose() }
        Assert-True ($packageHashText -cmatch ('^' + $tgzHash + "\s+incident-docket\.tgz\r?\n$")) 'PACKAGE_SHA256.txt mismatch.'
    }
    finally {
        $zipArchive.Dispose()
        $zipStream.Dispose()
    }
    $outerTgzExpected = Get-ChecksumEntry -Path (Join-Path $releaseDir 'SHA256SUMS.txt') -Name 'incident-docket.tgz'
    $outerZipExpected = Get-ChecksumEntry -Path (Join-Path $releaseDir 'SHA256SUMS.txt') -Name 'incident-docket-windows-setup.zip'
    Assert-True ($outerTgzExpected -ceq $hashFirst['incident-docket.tgz']) 'SHA256SUMS tgz entry mismatch.'
    Assert-True ($outerZipExpected -ceq $hashFirst['incident-docket-windows-setup.zip']) 'SHA256SUMS ZIP entry mismatch.'

    $tamperedZip = Join-Path $testRoot 'tampered.zip'
    Copy-Item -LiteralPath $zipPath -Destination $tamperedZip
    [IO.File]::AppendAllText($tamperedZip, 'tampered')
    Assert-True ((Get-FileHash -LiteralPath $tamperedZip -Algorithm SHA256).Hash.ToUpperInvariant() -cne $outerZipExpected) 'Tampered ZIP was accepted.'
    $tamperedTgz = Join-Path $testRoot 'tampered.tgz'
    Copy-Item -LiteralPath (Join-Path $releaseDir 'incident-docket.tgz') -Destination $tamperedTgz
    [IO.File]::AppendAllText($tamperedTgz, 'tampered')
    Assert-True ((Get-FileHash -LiteralPath $tamperedTgz -Algorithm SHA256).Hash.ToUpperInvariant() -cne $outerTgzExpected) 'Tampered tgz was accepted.'

    Write-Output '2. Isolated installer and MCP state matrix'
    $fakeRoot = New-Directory -Path (Join-Path $testRoot 'fake-tools')
    $fake = Write-FakeCommandWrappers -Directory $fakeRoot
    $fakeNpmOnlyRoot = New-Directory -Path (Join-Path $testRoot 'fake-npm-only')
    Copy-Item -LiteralPath (Join-Path $fakeRoot 'npm.cmd') -Destination (Join-Path $fakeNpmOnlyRoot 'npm.cmd') -Force
    $fakeCodexOnlyRoot = New-Directory -Path (Join-Path $testRoot 'fake-codex-only')
    Copy-Item -LiteralPath (Join-Path $fakeRoot 'codex.cmd') -Destination (Join-Path $fakeCodexOnlyRoot 'codex.cmd') -Force
    $nodeDir = Split-Path -Parent $nodePath
    $npmDir = Split-Path -Parent $npmPath
    $systemPath = @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32')) -join ';'
    $fakeBasePath = $fakeRoot + ';' + $nodeDir + ';' + $npmDir + ';' + $systemPath

    $missingChecksumCases = @('missing', 'duplicate', 'tampered')
    foreach ($caseName in $missingChecksumCases) {
        $caseRoot = New-Directory -Path (Join-Path $testRoot ('checksum-' + $caseName))
        $setup = Copy-Setup -Destination (Join-Path $caseRoot 'setup')
        $prefix = Join-Path $caseRoot 'prefix'
        $local = Join-Path $caseRoot 'local'
        $marker = Join-Path $caseRoot 'npm-called'
        if ($caseName -eq 'missing') {
            [IO.File]::WriteAllText((Join-Path $setup 'PACKAGE_SHA256.txt'), "`n", [Text.Encoding]::ASCII)
        }
        elseif ($caseName -eq 'duplicate') {
            $line = Read-Text (Join-Path $setup 'PACKAGE_SHA256.txt')
            [IO.File]::WriteAllText((Join-Path $setup 'PACKAGE_SHA256.txt'), ($line + $line), [Text.Encoding]::ASCII)
        }
        else {
            [IO.File]::AppendAllText((Join-Path $setup 'incident-docket.tgz'), 'tampered')
        }
        Set-FakeEnvironment -FakeRoot $fakeRoot -Prefix $prefix -LocalAppData $local -PathValue $fakeBasePath -StatePath (Join-Path $caseRoot 'state.json') -NpmMode $null -CliMode $null -CodexMode $null -NpmMarker $marker -DemoMarker $null -AddMarker $null -StaleMarker $null
        $result = Invoke-Captured -FilePath $powershellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $setup 'install.ps1')) -WorkingDirectory $caseRoot -PathValue $fakeBasePath -NpmPrefix $null -CodexHome $null -LocalAppData $local -Label ('installer-' + $caseName)
        Assert-True ($result.ExitCode -ne 0) ('Invalid checksum case succeeded: ' + $caseName)
        Assert-True (-not (Test-Path -LiteralPath $marker -PathType Leaf)) ('npm started for invalid checksum case: ' + $caseName)
    }

    $codexMissingRoot = New-Directory -Path (Join-Path $testRoot 'codex-missing')
    $codexMissingSetup = Copy-Setup -Destination (Join-Path $codexMissingRoot 'setup')
    $codexMissingMarker = Join-Path $codexMissingRoot 'npm-called'
    $fakeNpmOnlyPath = $fakeNpmOnlyRoot + ';' + $nodeDir + ';' + $npmDir + ';' + $systemPath
    Set-FakeEnvironment -FakeRoot $fakeRoot -Prefix (Join-Path $codexMissingRoot 'prefix') -LocalAppData (Join-Path $codexMissingRoot 'local') -PathValue $fakeNpmOnlyPath -StatePath (Join-Path $codexMissingRoot 'state.json') -NpmMode $null -CliMode $null -CodexMode $null -NpmMarker $codexMissingMarker -DemoMarker $null -AddMarker $null -StaleMarker $null
    $result = Invoke-Captured -FilePath $powershellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $codexMissingSetup 'install.ps1'), '-RegisterCodexMcp') -WorkingDirectory $codexMissingRoot -PathValue $fakeNpmOnlyPath -NpmPrefix $null -CodexHome $null -LocalAppData (Join-Path $codexMissingRoot 'local') -Label 'installer-codex-missing'
    Assert-True ($result.ExitCode -ne 0) 'Codex-missing registration unexpectedly succeeded.'
    Assert-True (-not (Test-Path -LiteralPath $codexMissingMarker -PathType Leaf)) 'npm started before Codex preflight failure.'

    $fakeCases = @(
        @{ Name = 'package-only'; State = 'none'; CodexMode = $null; CliMode = $null; NpmMode = $null; Register = $false; Expected = 0 },
        @{ Name = 'correct-existing'; State = 'correct'; CodexMode = $null; CliMode = $null; NpmMode = $null; Register = $true; Expected = 0 },
        @{ Name = 'entry-absent'; State = 'none'; CodexMode = $null; CliMode = $null; NpmMode = $null; Register = $true; Expected = 0 },
        @{ Name = 'wrong-existing'; State = 'wrong'; CodexMode = $null; CliMode = $null; NpmMode = $null; Register = $true; Expected = 1 },
        @{ Name = 'add-validation-mismatch'; State = 'none'; CodexMode = 'bad-add'; CliMode = $null; NpmMode = $null; Register = $true; Expected = 1 },
        @{ Name = 'stale-path'; State = 'none'; CodexMode = $null; CliMode = $null; NpmMode = $null; Register = $false; Expected = 0 },
        @{ Name = 'demo-failure'; State = 'none'; CodexMode = $null; CliMode = 'fail'; NpmMode = $null; Register = $false; Expected = 1 },
        @{ Name = 'npm-failure'; State = 'none'; CodexMode = $null; CliMode = $null; NpmMode = 'fail'; Register = $false; Expected = 1 }
    )
    foreach ($testCase in $fakeCases) {
        $caseRoot = New-Directory -Path (Join-Path $testRoot ('installer-' + $testCase.Name))
        $setup = Copy-Setup -Destination (Join-Path $caseRoot 'setup')
        $prefix = Join-Path $caseRoot 'prefix'
        $local = Join-Path $caseRoot 'local'
        $statePath = Join-Path $caseRoot 'state.json'
        $npmMarker = Join-Path $caseRoot 'npm-called'
        $addMarker = Join-Path $caseRoot 'mcp-add-called'
        $demoMarker = Join-Path $caseRoot 'demo-called'
        if ($testCase.State -eq 'correct') {
            [IO.File]::WriteAllText($statePath, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"incident-docket","args":["mcp"]}}')
        }
        elseif ($testCase.State -eq 'wrong') {
            [IO.File]::WriteAllText($statePath, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"other","args":["wrong"]}}')
        }
        $pathValue = $fakeBasePath
        if ($testCase.Name -eq 'stale-path') {
            $staleDir = New-Directory -Path (Join-Path $caseRoot 'stale')
            $staleCli = Join-Path $staleDir 'incident-docket.cmd'
            [IO.File]::WriteAllText($staleCli, '@echo off' + "`r`n" + 'echo stale>"%STALE_MARKER%"' + "`r`n" + 'exit /b 9' + "`r`n", [Text.Encoding]::ASCII)
            $pathValue = $staleDir + ';' + $fakeBasePath
        }
        Set-FakeEnvironment -FakeRoot $fakeRoot -Prefix $prefix -LocalAppData $local -PathValue $pathValue -StatePath $statePath -NpmMode $testCase.NpmMode -CliMode $testCase.CliMode -CodexMode $testCase.CodexMode -NpmMarker $npmMarker -DemoMarker $demoMarker -AddMarker $addMarker -StaleMarker (Join-Path $caseRoot 'stale-called')
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $setup 'install.ps1'))
        if ($testCase.Register) { $args += '-RegisterCodexMcp' }
        $result = Invoke-Captured -FilePath $powershellPath -Arguments $args -WorkingDirectory $caseRoot -PathValue $pathValue -NpmPrefix $null -CodexHome $null -LocalAppData $local -Label ('installer-' + $testCase.Name)
        Assert-True ($result.ExitCode -eq $testCase.Expected) ('Unexpected installer exit for ' + $testCase.Name + ': ' + $result.ExitCode + ' stdout=' + $result.Stdout + ' stderr=' + $result.Stderr)
        if ($testCase.Name -eq 'correct-existing') { Assert-True (-not (Test-Path -LiteralPath $addMarker -PathType Leaf)) 'Correct existing MCP entry was duplicated.' }
        if ($testCase.Name -eq 'entry-absent') { Assert-True (Test-Path -LiteralPath $addMarker -PathType Leaf) 'Missing MCP entry was not added.' }
        if ($testCase.Name -eq 'wrong-existing') { Assert-True ((Read-Text $statePath) -match '"other"') 'Wrong MCP entry was changed.' }
        if ($testCase.Name -eq 'stale-path') { Assert-True (-not (Test-Path -LiteralPath (Join-Path $caseRoot 'stale-called') -PathType Leaf)) 'Stale PATH binary was used.' }
        if ($testCase.Name -eq 'demo-failure') { Assert-True (($result.Stderr + $result.Stdout) -match '(?i)fixture demo') 'Demo failure stage was not reported.' }
        if ($testCase.Name -eq 'npm-failure') { Assert-True (($result.Stderr + $result.Stdout) -match '(?i)npm global installation failed') 'npm failure was not reported.' }
    }

    Write-Output '3. Isolated uninstaller ownership and partial behavior'
    $uninstallCases = @(
        @{ Name = 'package-absent'; State = 'none'; IncludeNpm = $true; Expected = 0 },
        @{ Name = 'managed-mcp'; State = 'correct'; IncludeNpm = $true; Expected = 0 },
        @{ Name = 'wrong-mcp'; State = 'wrong'; IncludeNpm = $true; Expected = 1 },
        @{ Name = 'npm-missing-mcp-continues'; State = 'correct'; IncludeNpm = $false; Expected = 1 }
    )
    foreach ($testCase in $uninstallCases) {
        $caseRoot = New-Directory -Path (Join-Path $testRoot ('uninstaller-' + $testCase.Name))
        $statePath = Join-Path $caseRoot 'state.json'
        if ($testCase.State -eq 'correct') {
            [IO.File]::WriteAllText($statePath, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"incident-docket","args":["mcp"]}}')
        }
        elseif ($testCase.State -eq 'wrong') {
            [IO.File]::WriteAllText($statePath, '{"name":"incident_docket","enabled":true,"transport":{"type":"stdio","command":"other","args":["wrong"]}}')
        }
        $local = Join-Path $caseRoot 'local'
        $pathValue = if ($testCase.IncludeNpm) { $fakeBasePath } else { $fakeCodexOnlyRoot + ';' + $systemPath }
        Set-FakeEnvironment -FakeRoot $fakeRoot -Prefix (Join-Path $caseRoot 'prefix') -LocalAppData $local -PathValue $pathValue -StatePath $statePath -NpmMode $null -CliMode $null -CodexMode $null -NpmMarker $null -DemoMarker $null -AddMarker $null -StaleMarker $null
        $result = Invoke-Captured -FilePath $powershellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstallScript, '-RemoveCodexMcp') -WorkingDirectory $caseRoot -PathValue $pathValue -NpmPrefix $null -CodexHome $null -LocalAppData $local -Label ('uninstaller-' + $testCase.Name)
        Assert-True ($result.ExitCode -eq $testCase.Expected) ('Unexpected uninstaller exit for ' + $testCase.Name)
        if ($testCase.Name -eq 'wrong-mcp') { Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) 'Uninstaller removed a wrong MCP entry.' }
        if ($testCase.Name -eq 'npm-missing-mcp-continues') { Assert-True (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) 'MCP removal did not continue when npm was missing.' }
    }
    $retentionRoot = New-Directory -Path (Join-Path $testRoot 'uninstaller-retention')
    $retained = New-Directory -Path (Join-Path $retentionRoot 'local\IncidentDocket')
    $retainedFile = Join-Path $retained 'case.md'
    [IO.File]::WriteAllText($retainedFile, 'retained')
    Set-FakeEnvironment -FakeRoot $fakeRoot -Prefix (Join-Path $retentionRoot 'prefix') -LocalAppData (Join-Path $retentionRoot 'local') -PathValue $fakeBasePath -StatePath (Join-Path $retentionRoot 'state.json') -NpmMode $null -CliMode $null -CodexMode $null -NpmMarker $null -DemoMarker $null -AddMarker $null -StaleMarker $null
    $result = Invoke-Captured -FilePath $powershellPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uninstallScript) -WorkingDirectory $retentionRoot -PathValue $fakeBasePath -NpmPrefix $null -CodexHome $null -LocalAppData (Join-Path $retentionRoot 'local') -Label 'uninstaller-retention'
    Assert-True ($result.ExitCode -eq 0) 'Basic uninstall failed during retention test.'
    Assert-True (Test-Path -LiteralPath $retainedFile -PathType Leaf) 'Uninstaller removed LocalAppData evidence.'

    Write-Output '4. Clean Unicode/space setup, packed CLI, and packed MCP'
    foreach ($name in $environmentNames) {
        Set-EnvironmentValue -Name $name -Value $originalEnvironment[$name]
    }
    $unicodeMarker = [string][char]0x00FC
    $cleanRoot = New-Directory -Path (Join-Path $testRoot ('clean ' + $unicodeMarker + ' setup space'))
    $downloadRoot = New-Directory -Path (Join-Path $cleanRoot 'download')
    Copy-Item -LiteralPath (Join-Path $releaseDir 'incident-docket-windows-setup.zip') -Destination (Join-Path $downloadRoot 'incident-docket-windows-setup.zip')
    Copy-Item -LiteralPath (Join-Path $releaseDir 'SHA256SUMS.txt') -Destination (Join-Path $downloadRoot 'SHA256SUMS.txt')
    $verifiedExpected = Get-ChecksumEntry -Path (Join-Path $downloadRoot 'SHA256SUMS.txt') -Name 'incident-docket-windows-setup.zip'
    $verifiedActual = (Get-FileHash -LiteralPath (Join-Path $downloadRoot 'incident-docket-windows-setup.zip') -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-True ($verifiedActual -ceq $verifiedExpected) 'Clean setup ZIP preverification failed.'
    $cleanSetup = Join-Path $cleanRoot 'extracted setup'
    Expand-Archive -LiteralPath (Join-Path $downloadRoot 'incident-docket-windows-setup.zip') -DestinationPath $cleanSetup -Force
    $cleanPrefix = Join-Path $cleanRoot ('prefix ' + $unicodeMarker + ' space')
    $cleanCwd = Join-Path $cleanRoot ('cwd ' + $unicodeMarker + ' space')
    $cleanLocal = Join-Path $cleanRoot ('local ' + $unicodeMarker + ' space')
    $cleanCodexHome = Join-Path $cleanRoot 'codex profile'
    New-Directory -Path $cleanPrefix | Out-Null
    New-Directory -Path $cleanCwd | Out-Null
    New-Directory -Path $cleanLocal | Out-Null
    New-Directory -Path $cleanCodexHome | Out-Null
    $cleanPath = $cleanPrefix + ';' + $env:Path
    $beforeCwd = @(Get-ChildItem -LiteralPath $cleanCwd -Force | Select-Object -ExpandProperty Name)
    $codexReal = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue
    $cleanArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $cleanSetup 'install.ps1'))
    if ($null -ne $codexReal) { $cleanArgs += '-RegisterCodexMcp' }
    $cleanResult = Invoke-Captured -FilePath $powershellPath -Arguments $cleanArgs -WorkingDirectory $cleanCwd -PathValue $cleanPath -NpmPrefix $cleanPrefix -CodexHome $cleanCodexHome -LocalAppData $cleanLocal -Label 'clean-installer'
    Assert-True ($cleanResult.ExitCode -eq 0) ('Clean setup installer failed: ' + $cleanResult.Stderr)
    $afterCwd = @(Get-ChildItem -LiteralPath $cleanCwd -Force | Select-Object -ExpandProperty Name)
    Assert-True ($null -eq (Compare-Object -ReferenceObject $beforeCwd -DifferenceObject $afterCwd)) 'Installer changed its CWD or created an artifact there.'
    $cleanCli = Join-Path $cleanPrefix 'incident-docket.cmd'
    Assert-True (Test-Path -LiteralPath $cleanCli -PathType Leaf) 'Clean setup did not install the CLI in the requested prefix.'
    $demoOut = Join-Path $cleanRoot 'demo.out'
    $demoErr = Join-Path $cleanRoot 'demo.err'
    & $cleanCli demo --fixture gpu-driver-reset 1>$demoOut 2>$demoErr
    Assert-True ($LASTEXITCODE -eq 0) 'Packed fixture CLI failed.'
    $demoText = Read-Text $demoOut
    Assert-True (([regex]::Matches($demoText, 'Temporal proximity does not prove causation\.')).Count -eq 1) 'Packed fixture warning count is not exactly one.'
    Assert-True ([string]::IsNullOrEmpty((Read-Text $demoErr))) 'Packed fixture CLI wrote stderr.'
    foreach ($secret in @('alex', 'alex@example.invalid', '192.0.2.10', 'fixture-access-token', 'S-1-5-21-111111111-222222222-333333333-1001', 'Ignore previous instructions', 'system prompt')) {
        Assert-True (-not $demoText.ToLowerInvariant().Contains($secret.ToLowerInvariant())) ('Fixture secret leaked: ' + $secret)
    }
    $globalRoot = Join-Path $cleanPrefix 'node_modules'
    Assert-True (Test-Path -LiteralPath $globalRoot -PathType Container) 'Unable to resolve packed global npm root.'
    $packedEntry = Join-Path $globalRoot 'incident-docket\dist\index.js'
    Assert-True (Test-Path -LiteralPath $packedEntry -PathType Leaf) 'Packed entrypoint was not found.'
    $packedStorage = Join-Path $cleanRoot 'packed storage'
    New-Directory -Path $packedStorage | Out-Null
    $smoke = Invoke-McpSmoke -EntryPath $packedEntry -StorageRoot $packedStorage
    Assert-True ($smoke -match '"tool_count":4') 'Packed MCP did not expose exactly four tools.'

    if ($null -ne $codexReal) {
        $oldCodexHome = $env:CODEX_HOME
        $oldPath = $env:Path
        try {
            $env:CODEX_HOME = $cleanCodexHome
            $env:Path = $cleanPath
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $stateOutput = (& $codexReal.Source mcp get incident_docket --json 2>$null | Out-String).Trim()
                $stateExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $oldPreference
            }
            Assert-True ($stateExitCode -eq 0) 'Isolated Codex MCP registration was not readable.'
            $state = $stateOutput | ConvertFrom-Json
            Assert-True ([string]$state.transport.command -ceq 'incident-docket') 'Packed MCP command mismatch.'
            Assert-True (@($state.transport.args).Count -eq 1 -and [string]$state.transport.args[0] -ceq 'mcp') 'Packed MCP args mismatch.'
        }
        finally {
            $env:CODEX_HOME = $oldCodexHome
            $env:Path = $oldPath
        }
    }

    Write-Output 'Release acceptance passed.'
}
catch {
    [Console]::Error.WriteLine(('Release acceptance failed: ' + [string]$_.Exception.Message))
    exit 1
}
finally {
    foreach ($name in $originalEnvironment.Keys) {
        Set-EnvironmentValue -Name $name -Value $originalEnvironment[$name]
    }
    if (Test-Path -LiteralPath $testRoot) {
        $fullTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $fullRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
        if ($fullRoot.StartsWith($fullTemp + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullRoot) -like 'IncidentDocket-release-acceptance-*') {
            Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
