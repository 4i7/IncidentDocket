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

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object[]]$Entries
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $fixedTime = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
    $stream = [IO.File]::Open(
        $DestinationPath,
        [IO.FileMode]::Create,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $archive = $null
    try {
        $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            [Text.Encoding]::UTF8
        )

        foreach ($entrySpec in $Entries) {
            $sourcePath = [IO.Path]::GetFullPath([string]$entrySpec.Source)
            $entryName = [string]$entrySpec.Name
            if ($entryName -notmatch '^[^/\\]+$' -or $entryName -in @('.', '..')) {
                throw ('Unsafe ZIP entry name: ' + $entryName)
            }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw ('ZIP source file was not found: ' + $entryName)
            }

            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTime
            $input = [IO.File]::OpenRead($sourcePath)
            $output = $null
            try {
                $output = $entry.Open()
                $input.CopyTo($output)
            }
            finally {
                if ($null -ne $output) { $output.Dispose() }
                $input.Dispose()
            }
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
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
    $licensePath = Join-Path $repoRoot 'LICENSE'
    if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
        throw 'LICENSE was not found.'
    }
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $stagingDir 'LICENSE')
    Copy-Item -LiteralPath $tgzPath -Destination (Join-Path $stagingDir 'incident-docket.tgz')
    $packageHashPath = Join-Path $stagingDir 'PACKAGE_SHA256.txt'
    [IO.File]::WriteAllText($packageHashPath, ($tgzHash + "  incident-docket.tgz`n"), [Text.Encoding]::ASCII)

    $zipPath = Join-Path $outputDir 'incident-docket-windows-setup.zip'
    $zipEntries = @(
        @{ Name = 'incident-docket.tgz'; Source = (Join-Path $stagingDir 'incident-docket.tgz') },
        @{ Name = 'install.ps1'; Source = (Join-Path $stagingDir 'install.ps1') },
        @{ Name = 'uninstall.ps1'; Source = (Join-Path $stagingDir 'uninstall.ps1') },
        @{ Name = 'INSTALL.md'; Source = (Join-Path $stagingDir 'INSTALL.md') },
        @{ Name = 'LICENSE'; Source = (Join-Path $stagingDir 'LICENSE') },
        @{ Name = 'PACKAGE_SHA256.txt'; Source = $packageHashPath }
    )
    New-DeterministicZip -DestinationPath $zipPath -Entries $zipEntries

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipStream = [IO.File]::OpenRead($zipPath)
    $zipArchive = $null
    try {
        $zipArchive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList @(
            $zipStream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false,
            [Text.Encoding]::UTF8
        )
        $actualZipEntries = @($zipArchive.Entries)
        if ($actualZipEntries.Count -ne $zipEntries.Count) {
            throw 'Deterministic ZIP entry count mismatch.'
        }
        for ($index = 0; $index -lt $zipEntries.Count; $index++) {
            if ($actualZipEntries[$index].FullName -cne [string]$zipEntries[$index].Name) {
                throw 'Deterministic ZIP entry order mismatch.'
            }
            if ($actualZipEntries[$index].FullName -match '(^|/|\\)\.\.?(?:/|\\|$)' -or $actualZipEntries[$index].FullName.EndsWith('/')) {
                throw 'Deterministic ZIP contains an unsafe or directory entry.'
            }
            if ($actualZipEntries[$index].LastWriteTime.DateTime -ne [DateTime]::Parse('2000-01-01T00:00:00')) {
                throw 'Deterministic ZIP entry timestamp mismatch.'
            }
        }

        $tgzEntry = $actualZipEntries | Where-Object { $_.FullName -ceq 'incident-docket.tgz' }
        $tgzEntryStream = $tgzEntry.Open()
        try {
            if ((Get-StreamSha256 -Stream $tgzEntryStream) -cne $tgzHash) {
                throw 'ZIP incident-docket.tgz hash does not match the release tarball.'
            }
        }
        finally {
            $tgzEntryStream.Dispose()
        }

        $packageHashEntry = $actualZipEntries | Where-Object { $_.FullName -ceq 'PACKAGE_SHA256.txt' }
        $packageHashStream = $packageHashEntry.Open()
        $packageHashText = $null
        try {
            $packageHashReader = New-Object System.IO.StreamReader($packageHashStream, [Text.Encoding]::ASCII, $false)
            try {
                $packageHashText = $packageHashReader.ReadToEnd()
            }
            finally {
                $packageHashReader.Dispose()
            }
        }
        finally {
            $packageHashStream.Dispose()
        }
        if ($packageHashText -cnotmatch ('^' + $tgzHash + "\s+incident-docket\.tgz`n$")) {
            throw 'PACKAGE_SHA256.txt does not match incident-docket.tgz.'
        }
    }
    finally {
        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
        $zipStream.Dispose()
    }
    $zipHash = Get-Sha256 $zipPath

    $sumLines = @(
        ($tgzHash + '  incident-docket.tgz'),
        ($zipHash + '  incident-docket-windows-setup.zip')
    )
    [IO.File]::WriteAllText(
        (Join-Path $outputDir 'SHA256SUMS.txt'),
        (($sumLines -join "`n") + "`n"),
        [Text.Encoding]::ASCII
    )

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
