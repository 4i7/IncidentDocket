[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
    [string]$ExpectedTgzSha256,
    [string]$ExpectedSetupZipSha256,
    [string]$ExpectedChecksumsSha256
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
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

function Get-StrictChecksumMap {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -Encoding ASCII | Where-Object { ([string]$_).Trim().Length -gt 0 })
    Assert-True ($lines.Count -eq 2) 'SHA256SUMS.txt must contain exactly two non-empty entries.'
    $map = @{}
    foreach ($line in $lines) {
        $match = [regex]::Match([string]$line, '^(?<hash>[0-9A-Fa-f]{64})[ \t]+(?<name>[^\s]+)$')
        Assert-True $match.Success 'SHA256SUMS.txt contains an invalid entry.'
        $name = $match.Groups['name'].Value
        Assert-True ($name -in @('incident-docket.tgz', 'incident-docket-windows-setup.zip')) ('Unexpected checksum filename: ' + $name)
        Assert-True ($name -notmatch '(^|[\\/])\.\.?([\\/]|$)' -and $name -notmatch '^[A-Za-z]:') ('Unsafe checksum filename: ' + $name)
        Assert-True (-not $map.ContainsKey($name)) ('Duplicate checksum filename: ' + $name)
        $map[$name] = $match.Groups['hash'].Value.ToUpperInvariant()
    }
    Assert-True ($map.ContainsKey('incident-docket.tgz') -and $map.ContainsKey('incident-docket-windows-setup.zip')) 'SHA256SUMS.txt is incomplete.'
    return $map
}

function Get-ZipEntryText {
    param([Parameter(Mandatory = $true)][System.IO.Compression.ZipArchiveEntry]$Entry)
    $stream = $Entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII, $false)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

$root = [IO.Path]::GetFullPath($ReleaseDirectory)
Assert-True (Test-Path -LiteralPath $root -PathType Container) ('Release directory was not found: ' + $root)
$expectedFiles = @('incident-docket.tgz', 'incident-docket-windows-setup.zip', 'SHA256SUMS.txt')
$children = @(Get-ChildItem -LiteralPath $root -Force)
Assert-True (-not @($children | Where-Object { $_.PSIsContainer }).Count) 'Release directory must not contain subdirectories.'
$actualNames = @($children | Select-Object -ExpandProperty Name)
Assert-True ($actualNames.Count -eq $expectedFiles.Count) ('Release asset set mismatch: ' + ($actualNames -join ', '))
foreach ($name in $actualNames) {
    Assert-True ($name -cin $expectedFiles) ('Unexpected release asset: ' + $name)
}
foreach ($name in $expectedFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf) ('Missing release asset: ' + $name)
}

$tgzPath = Join-Path $root 'incident-docket.tgz'
$zipPath = Join-Path $root 'incident-docket-windows-setup.zip'
$checksumsPath = Join-Path $root 'SHA256SUMS.txt'
$hashes = [ordered]@{
    tgz_sha256 = Get-Sha256 -Path $tgzPath
    setup_zip_sha256 = Get-Sha256 -Path $zipPath
    checksums_sha256 = Get-Sha256 -Path $checksumsPath
}
foreach ($pair in @(
        @{ Name = 'tgz_sha256'; Expected = $ExpectedTgzSha256 },
        @{ Name = 'setup_zip_sha256'; Expected = $ExpectedSetupZipSha256 },
        @{ Name = 'checksums_sha256'; Expected = $ExpectedChecksumsSha256 }
    )) {
    if ($null -ne $pair.Expected -and $pair.Expected -ne '') {
        Assert-True ($pair.Expected -cmatch '^[0-9A-Fa-f]{64}$') ('Expected hash is invalid: ' + $pair.Name)
        Assert-True ($hashes[$pair.Name] -ceq $pair.Expected.ToUpperInvariant()) ('Build hash mismatch: ' + $pair.Name)
    }
}

$checksumMap = Get-StrictChecksumMap -Path $checksumsPath
Assert-True ($checksumMap['incident-docket.tgz'] -ceq $hashes.tgz_sha256) 'SHA256SUMS.txt tgz hash does not match bytes.'
Assert-True ($checksumMap['incident-docket-windows-setup.zip'] -ceq $hashes.setup_zip_sha256) 'SHA256SUMS.txt ZIP hash does not match bytes.'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipStream = [IO.File]::OpenRead($zipPath)
$archive = $null
try {
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Read, $false, [Text.Encoding]::UTF8)
    $expectedEntries = @('incident-docket.tgz', 'install.ps1', 'uninstall.ps1', 'INSTALL.md', 'LICENSE', 'PACKAGE_SHA256.txt')
    Assert-True ($archive.Entries.Count -eq $expectedEntries.Count) 'Setup ZIP must contain exactly six entries.'
    for ($index = 0; $index -lt $expectedEntries.Count; $index++) {
        $entry = $archive.Entries[$index]
        Assert-True ($entry.FullName -ceq $expectedEntries[$index]) ('Setup ZIP entry mismatch at index ' + $index)
        Assert-True (-not $entry.FullName.EndsWith('/')) 'Setup ZIP contains a directory entry.'
        Assert-True ($entry.FullName -notmatch '(^|[\\/])\.\.?([\\/]|$)') 'Setup ZIP contains a traversal entry.'
    }
    $tgzEntry = $archive.Entries | Where-Object { $_.FullName -ceq 'incident-docket.tgz' }
    $tgzEntryStream = $tgzEntry.Open()
    try { Assert-True ((Get-StreamSha256 -Stream $tgzEntryStream) -ceq $hashes.tgz_sha256) 'Setup ZIP tgz bytes do not match the outer tgz.' }
    finally { $tgzEntryStream.Dispose() }

    $packageHashEntry = $archive.Entries | Where-Object { $_.FullName -ceq 'PACKAGE_SHA256.txt' }
    $packageHashLines = @(Get-ZipEntryText -Entry $packageHashEntry | Select-String -Pattern '\S' | ForEach-Object { $_.Line })
    Assert-True ($packageHashLines.Count -eq 1) 'PACKAGE_SHA256.txt must contain exactly one non-empty entry.'
    $packageMatch = [regex]::Match([string]$packageHashLines[0], '^(?<hash>[0-9A-Fa-f]{64})[ \t]+(?<name>[^\s]+)$')
    Assert-True ($packageMatch.Success -and $packageMatch.Groups['name'].Value -ceq 'incident-docket.tgz') 'PACKAGE_SHA256.txt contains an invalid entry.'
    Assert-True ($packageMatch.Groups['hash'].Value.ToUpperInvariant() -ceq $hashes.tgz_sha256) 'PACKAGE_SHA256.txt hash does not match the tgz.'
}
finally {
    if ($null -ne $archive) { $archive.Dispose() }
    $zipStream.Dispose()
}

[ordered]@{
    tgz_sha256 = $hashes.tgz_sha256
    setup_zip_sha256 = $hashes.setup_zip_sha256
    checksums_sha256 = $hashes.checksums_sha256
} | ConvertTo-Json -Compress
