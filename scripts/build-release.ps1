#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-ApplicationPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $commands = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        throw ("Required command was not found: " + $Name)
    }
    $command = $commands[0]
    if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }
    return $command.Path
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$packageJsonPath = Join-Path $repoRoot 'package.json'
$outputDir = Join-Path $repoRoot 'artifacts\release'
$repoFullPath = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
$outputFullPath = [IO.Path]::GetFullPath($outputDir).TrimEnd('\')

if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
    throw 'package.json was not found.'
}
if ($outputFullPath -eq $repoFullPath -or -not $outputFullPath.StartsWith($repoFullPath + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($outputFullPath) -ne 'release') {
    throw 'Refusing to clean an unexpected output path.'
}

$package = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$package.name -ne 'incident-docket') {
    throw 'package.json name must be incident-docket.'
}
$version = [string]$package.version
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw 'package.json version is not a normalized semantic version.'
}

if (Test-Path -LiteralPath $outputDir) {
    Remove-Item -LiteralPath $outputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('incident-docket-release-' + [Guid]::NewGuid().ToString('N'))
$packDir = Join-Path $tempRoot 'pack'
$stagingDir = Join-Path $tempRoot 'setup'
New-Item -ItemType Directory -Path $packDir, $stagingDir -Force | Out-Null
$locationPushed = $false

try {
    Push-Location -LiteralPath $repoRoot
    $locationPushed = $true
    $npmPath = Get-ApplicationPath 'npm.cmd'
    $packArguments = @('pack', '--pack-destination', $packDir)
    & $npmPath @packArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'npm pack failed.'
    }

    $versionedName = $package.name + '-' + $version + '.tgz'
    $versionedPackages = @(Get-ChildItem -LiteralPath $packDir -Filter $versionedName -File)
    if ($versionedPackages.Count -ne 1) {
        throw ('Expected one npm pack output named ' + $versionedName + '.')
    }

    $tarPath = Get-ApplicationPath 'tar.exe'
    $tarEntries = @(& $tarPath @('-tzf', $versionedPackages[0].FullName))
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the npm tarball.'
    }
    $actualEntries = @($tarEntries | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $expectedEntries = @(
        'package/LICENSE',
        'package/README.md',
        'package/collectors/windows.ps1',
        'package/dist/core.js',
        'package/dist/index.js',
        'package/package.json',
        'package/samples/gpu-driver-reset.json'
    )
    $entryDiff = Compare-Object -ReferenceObject ($expectedEntries | Sort-Object) -DifferenceObject ($actualEntries | Sort-Object)
    if ($null -ne $entryDiff) {
        throw ('npm tarball allowlist mismatch: ' + (($actualEntries | Sort-Object) -join ', '))
    }

    $tgzPath = Join-Path $outputDir 'incident-docket.tgz'
    Copy-Item -LiteralPath $versionedPackages[0].FullName -Destination $tgzPath
    $tgzHash = Get-Sha256 $tgzPath

    foreach ($fileName in @('install.ps1', 'uninstall.ps1')) {
        $sourcePath = Join-Path $scriptRoot $fileName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw ('Missing setup file: ' + $fileName)
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $stagingDir $fileName)
    }

    $installDocPath = Join-Path $repoRoot 'docs\INSTALL.md'
    if (-not (Test-Path -LiteralPath $installDocPath -PathType Leaf)) {
        throw 'docs/INSTALL.md was not found.'
    }
    Copy-Item -LiteralPath $installDocPath -Destination (Join-Path $stagingDir 'INSTALL.md')
    Copy-Item -LiteralPath $tgzPath -Destination (Join-Path $stagingDir 'incident-docket.tgz')
    Set-Content -LiteralPath (Join-Path $stagingDir 'PACKAGE_SHA256.txt') -Value ($tgzHash + '  incident-docket.tgz') -Encoding ASCII

    $fixedZipTime = [datetime]::Parse('2000-01-01T00:00:00Z').ToUniversalTime()
    Get-ChildItem -LiteralPath $stagingDir -File | ForEach-Object {
        $_.LastWriteTimeUtc = $fixedZipTime
        $_.CreationTimeUtc = $fixedZipTime
        $_.LastAccessTimeUtc = $fixedZipTime
    }
    $zipPath = Join-Path $outputDir 'incident-docket-windows-setup.zip'
    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $zipHash = Get-Sha256 $zipPath

    $sumLines = @(
        ($tgzHash + '  incident-docket.tgz'),
        ($zipHash + '  incident-docket-windows-setup.zip')
    )
    Set-Content -LiteralPath (Join-Path $outputDir 'SHA256SUMS.txt') -Value $sumLines -Encoding ASCII

    Write-Output 'Release assets generated:'
    Write-Output ('incident-docket.tgz ' + $tgzHash)
    Write-Output ('incident-docket-windows-setup.zip ' + $zipHash)
    Write-Output 'SHA256SUMS.txt'
}
finally {
    if ($locationPushed) {
        Pop-Location
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
