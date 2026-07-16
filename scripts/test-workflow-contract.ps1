[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) '..'))

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Count-Matches {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Pattern)
    return @([regex]::Matches($Text, $Pattern)).Count
}

$ciPath = Join-Path $repoRoot '.github/workflows/ci.yml'
$releasePath = Join-Path $repoRoot '.github/workflows/release.yml'
$verifyPath = Join-Path $repoRoot 'scripts/verify-release-assets.ps1'
$releaseStatePath = Join-Path $repoRoot 'scripts/check-release-state.ps1'
$ci = Get-Content -LiteralPath $ciPath -Raw -Encoding UTF8
$release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8
$verify = Get-Content -LiteralPath $verifyPath -Raw -Encoding UTF8

Assert-True ($ci -match '(?ms)^permissions:\s*\r?\n\s+contents:\s+read\s*$') 'CI must have read-only contents permission.'
Assert-True ($ci -notmatch '(?i)contents:\s+write') 'CI must not request contents write permission.'
Assert-True ($ci -match '(?m)^\s*runs-on:\s+windows-latest\s*$') 'CI must use a Windows runner.'
Assert-True ($ci -match '(?m)^\s*node-version:\s+24\s*$') 'CI must use Node.js 24.'
Assert-True ($release -match '(?m)^\s*node-version:\s+24\s*$') 'Release build must use Node.js 24.'
Assert-True ($release -match '(?m)^\s*cancel-in-progress:\s+false\s*$') 'Release concurrency must not cancel an in-flight publish.'
Assert-True ($release -match "(?m)^\s*if:\s*github\.event_name == 'push' && startsWith\(github\.ref, 'refs/tags/v'\)\s*$") 'Publish job event boundary is not fail-closed.'
Assert-True ($release -match '(?ms)publish:\s*\r?\n\s+if:') 'Publish job must have an explicit condition.'
Assert-True ($release -match '(?ms)publish:.*?permissions:\s*\r?\n\s+contents:\s+write') 'Only the publish job may request contents write permission.'
Assert-True ($release -match '(?m)^\s*workflow_dispatch:\s*$') 'Release workflow must retain manual validation trigger.'
Assert-True ($release -match '(?m)^\s*push:\s*$') 'Release workflow must retain push trigger.'
$publishCondition = { param([string]$Event, [string]$Ref) $Event -ceq 'push' -and $Ref.StartsWith('refs/tags/v', [StringComparison]::Ordinal) }
Assert-True (-not (& $publishCondition 'workflow_dispatch' 'refs/tags/v0.1.0')) 'Manual tag-ref dispatch would publish.'
Assert-True (& $publishCondition 'push' 'refs/tags/v0.1.0') 'A tag push would not publish.'
Assert-True (-not (& $publishCondition 'push' 'refs/heads/main')) 'A branch push would publish.'
Assert-True ($release -match 'scripts[\\/]verify-release-assets\.ps1') 'Release workflow must call independent asset verification.'
Assert-True ($release -match 'ExpectedTgzSha256') 'Publish must compare the tgz build output hash.'
Assert-True ($release -match 'ExpectedSetupZipSha256') 'Publish must compare the ZIP build output hash.'
Assert-True ($release -match 'ExpectedChecksumsSha256') 'Publish must compare the checksum-file build output hash.'
Assert-True ($release -match 'scripts[\\/]check-release-state\.ps1') 'Publish must fail closed for an existing Release.'
Assert-True ($release -match 'gh release create') 'Release creation command is missing.'
Assert-True ($release -notmatch '(?i)npm\s+publish|git\s+push|git\s+tag') 'Workflow contains a forbidden mutation.'
Assert-True ($ci -match 'scripts[\\/]test-packed-mcp\.mjs') 'CI must run packed MCP smoke.'
Assert-True ($release -match 'scripts[\\/]test-packed-mcp\.mjs') 'Release build must run packed MCP smoke.'

$uses = @([regex]::Matches($ci + "`n" + $release, '(?m)^\s*-\s+uses:\s+(?<ref>[^\s#]+)(?:\s+#\s*(?<comment>.*))?\s*$'))
Assert-True ($uses.Count -gt 0) 'No GitHub Actions were found.'
foreach ($match in $uses) {
    $ref = $match.Groups['ref'].Value
    $comment = $match.Groups['comment'].Value
    Assert-True ($ref -match '^actions/(checkout|setup-node|upload-artifact|download-artifact)@[0-9a-fA-F]{40}$') ('Action is not an official immutable pin: ' + $ref)
    Assert-True ($comment -match '(?i)\bv[0-9]+(?:\.[0-9]+){0,2}\b') ('Action pin is missing a readable version comment: ' + $ref)
}
Assert-True ((Count-Matches ($ci + "`n" + $release) '@(?:v[0-9]+|main|master|HEAD)(?:\s|$)') -eq 0) 'A mutable Action ref remains.'
Assert-True ((Count-Matches ($ci + "`n" + $release) 'persist-credentials:\s*false') -eq (Count-Matches ($ci + "`n" + $release) 'uses:\s+actions/checkout@')) 'Every checkout must disable persisted credentials.'

Assert-True ($verify -match "'incident-docket\.tgz', 'incident-docket-windows-setup\.zip', 'SHA256SUMS\.txt'") 'Exact three release assets are not enforced.'
Assert-True ($verify -match "'incident-docket\.tgz', 'install\.ps1', 'uninstall\.ps1', 'INSTALL\.md', 'LICENSE', 'PACKAGE_SHA256\.txt'") 'Exact six setup ZIP entries are not enforced.'
Assert-True ($verify -match 'PACKAGE_SHA256\.txt must contain exactly one') 'Inner checksum validation is missing.'

$assetTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('IncidentDocket-asset-contract-' + [Guid]::NewGuid().ToString('N'))
try {
    $assetCopy = Join-Path $assetTestRoot 'release'
    New-Item -ItemType Directory -Path $assetCopy -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot 'artifacts/release/*') -Destination $assetCopy -Force
    [IO.File]::AppendAllText((Join-Path $assetCopy 'incident-docket.tgz'), 'mutated')
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyPath -ReleaseDirectory $assetCopy 2>$null
        $mutatedExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($mutatedExit -ne 0) 'Mutated downloaded asset passed publish-side verification.'
}
finally {
    Remove-Item -LiteralPath $assetTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$fakeRoot = Join-Path ([IO.Path]::GetTempPath()) ('IncidentDocket-workflow-contract-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:Path
try {
    New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
    $fakeGh = Join-Path $fakeRoot 'gh.cmd'
    $fakeGhText = @'
@echo off
if /I "%FAKE_GH_STATUS%"=="200" (
  echo HTTP/2 200 OK
  echo {"tag_name":"v0.1.0"}
  exit /b 0
)
echo HTTP/2 404 Not Found
exit /b 1
'@
    [IO.File]::WriteAllText($fakeGh, $fakeGhText, [Text.Encoding]::ASCII)
    $env:Path = $fakeRoot + ';' + $oldPath
    $env:FAKE_GH_STATUS = '200'
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $existingResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseStatePath -Repository 'example/repo' -Tag 'v0.1.0' 2>$null
        $existingExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($existingExit -ne 0) 'Existing Release contract case unexpectedly succeeded.'
    $env:FAKE_GH_STATUS = '404'
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $missingResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseStatePath -Repository 'example/repo' -Tag 'v0.1.0'
        $missingExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($missingExit -eq 0) 'Missing Release contract case did not succeed.'
}
finally {
    $env:Path = $oldPath
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Workflow contract passed.'
