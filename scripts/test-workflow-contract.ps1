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
$releaseState = Get-Content -LiteralPath $releaseStatePath -Raw -Encoding UTF8
$workflowText = ((Get-ChildItem -LiteralPath (Join-Path $repoRoot '.github/workflows') -File | Where-Object { $_.Extension -in @('.yml', '.yaml') } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n")

Assert-True ($ci -match '(?ms)^permissions:\s*\r?\n\s+contents:\s+read\s*$') 'CI must have read-only contents permission.'
Assert-True ($ci -notmatch '(?i)contents:\s+write') 'CI must not request contents write permission.'
Assert-True ($ci -match '(?m)^\s*runs-on:\s+windows-latest\s*$') 'CI must use a Windows runner.'
Assert-True ($ci -match '(?m)^\s*node-version:\s*\[22,\s*24\]\s*$') 'CI must test Node.js 22 and 24.'
Assert-True ($ci -match '(?m)^\s*node-version:\s*\$\{\{\s*matrix\.node-version\s*\}\}\s*$') 'CI setup-node must use the matrix version.'
$posixFixtureMatch = [regex]::Match($ci, '(?ms)^  posix-fixture:\s*\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\z)')
Assert-True $posixFixtureMatch.Success 'CI must define the posix-fixture job.'
$posixFixture = $posixFixtureMatch.Groups['body'].Value
Assert-True ($posixFixture -match '(?m)^\s*runs-on:\s+ubuntu-latest\s*$') 'POSIX fixture CI must use Ubuntu.'
Assert-True ($posixFixture -match '(?m)^\s*node-version:\s+22\s*$') 'POSIX fixture CI must use Node.js 22.'
foreach ($command in @('npm ci', 'npm test', 'npm run build', 'npm pack --dry-run', 'npm audit --omit=dev')) {
    Assert-True ($posixFixture -match [regex]::Escape($command)) ('POSIX fixture CI command is missing: ' + $command)
}
Assert-True ($posixFixture -match '\$RUNNER_TEMP') 'POSIX fixture CI must use a temporary install prefix.'
Assert-True ($posixFixture -match 'npm install --prefix') 'POSIX fixture CI must install the packed package.'
Assert-True ($posixFixture -match 'demo --fixture gpu-driver-reset') 'POSIX fixture CI must run the synthetic fixture CLI.'
Assert-True ($posixFixture -notmatch '(?i)\blive\b') 'POSIX fixture CI must remain synthetic-only.'
Assert-True ($posixFixture -match 'find "\$work"') 'POSIX fixture CI must verify CWD isolation.'
Assert-True ($posixFixture -match 'grep -Fqi') 'POSIX fixture CI must scan fixture output for secrets.'
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
Assert-True ($releaseState -match "'--paginate'") 'Release state must use a paginated Release list.'
Assert-True ($releaseState -match "'--slurp'") 'Release state must parse the complete paginated response.'
Assert-True ($releaseState -match '\$env:GH_TOKEN') 'Release state must require authenticated API access.'
Assert-True ($releaseState -notmatch '(?i)Invoke-Expression') 'Release state must not execute parsed shell text.'
Assert-True ($release -match 'gh release create') 'Release creation command is missing.'
Assert-True ($release -notmatch '(?i)npm\s+publish|git\s+push|git\s+tag') 'Workflow contains a forbidden mutation.'
Assert-True ($ci -match 'scripts[\\/]test-packed-mcp\.mjs') 'CI must run packed MCP smoke.'
Assert-True ($release -match 'scripts[\\/]test-packed-mcp\.mjs') 'Release build must run packed MCP smoke.'

$uses = @([regex]::Matches($workflowText, '(?m)^\s*(?:-\s+)?uses:\s+(?<ref>[^\s#]+)(?:\s+#\s*(?<comment>.*))?\s*$'))
Assert-True ($uses.Count -gt 0) 'No GitHub Actions were found.'
foreach ($match in $uses) {
    $ref = $match.Groups['ref'].Value
    $comment = $match.Groups['comment'].Value
    Assert-True ($ref -match '^actions/(checkout|setup-node|upload-artifact|download-artifact)@[0-9a-fA-F]{40}$') ('Action is not an official immutable pin: ' + $ref)
    Assert-True ($comment -match '(?i)\bv[0-9]+(?:\.[0-9]+){0,2}\b') ('Action pin is missing a readable version comment: ' + $ref)
}
$uploadArtifactSha = 'b7c566a772e6b6bfb58ed0dc250532a479d7789f'
$downloadArtifactSha = '37930b1c2abaa49bbe596cd826c3c89aef350131'
$uploadPins = @([regex]::Matches($workflowText, '(?m)^\s*(?:-\s+)?uses:\s+actions/upload-artifact@(?<ref>[^\s#]+)(?:\s+#\s*(?<comment>.*))?\s*$'))
$downloadPins = @([regex]::Matches($workflowText, '(?m)^\s*(?:-\s+)?uses:\s+actions/download-artifact@(?<ref>[^\s#]+)(?:\s+#\s*(?<comment>.*))?\s*$'))
Assert-True ($uploadPins.Count -gt 0) 'upload-artifact is missing.'
Assert-True ($downloadPins.Count -gt 0) 'download-artifact is missing.'
foreach ($pin in $uploadPins) {
    Assert-True ($pin.Groups['ref'].Value -ceq $uploadArtifactSha) 'upload-artifact is not pinned to the approved v6 SHA.'
    Assert-True ($pin.Groups['comment'].Value -match '(?i)\bv6\.0\.0\b') 'upload-artifact pin is missing the v6.0.0 comment.'
}
foreach ($pin in $downloadPins) {
    Assert-True ($pin.Groups['ref'].Value -ceq $downloadArtifactSha) 'download-artifact is not pinned to the approved v7 SHA.'
    Assert-True ($pin.Groups['comment'].Value -match '(?i)\bv7\.0\.0\b') 'download-artifact pin is missing the v7.0.0 comment.'
}
Assert-True ((Count-Matches $workflowText '@(?:v[0-9]+|main|master|HEAD)(?:\s|$)') -eq 0) 'A mutable Action ref remains.'
Assert-True ((Count-Matches $workflowText 'persist-credentials:\s*false') -eq (Count-Matches $workflowText 'uses:\s+actions/checkout@')) 'Every checkout must disable persisted credentials.'

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
$oldGhToken = $env:GH_TOKEN
$oldFakeScenario = $env:FAKE_GH_SCENARIO
try {
    New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
    $fakeGh = Join-Path $fakeRoot 'gh.cmd'
    $fakeGhText = @'
@echo off
if /I "%~2"=="--paginate" goto list
goto tag

:list
if /I "%FAKE_GH_SCENARIO%"=="api-failure" (
  echo list api failure 1>&2
  exit /b 1
)
if /I "%FAKE_GH_SCENARIO%"=="pagination-failure" (
  echo [[{"tag_name":"page-1"}]]
  echo pagination failure 1>&2
  exit /b 1
)
if /I "%FAKE_GH_SCENARIO%"=="malformed-json" (
  echo not-json
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="published-match" (
  echo [[{"tag_name":"v0.1.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="draft-match" (
  echo [[{"tag_name":"v0.1.0","draft":true,"prerelease":false,"published_at":null}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="prerelease-match" (
  echo [[{"tag_name":"v0.1.0","draft":false,"prerelease":true,"published_at":"2026-01-01T00:00:00Z"}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="page2-match" (
  echo [[{"tag_name":"unrelated"}],[{"tag_name":"v0.1.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="duplicate-match" (
  echo [[{"tag_name":"v0.1.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"},{"tag_name":"v0.1.0","draft":true,"prerelease":false,"published_at":null}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="unrelated-draft" (
  echo [[{"tag_name":"other","draft":true,"prerelease":false,"published_at":null}]]
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="unrelated-published" (
  echo [[{"tag_name":"other","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}]]
  exit /b 0
)
echo [[]]
exit /b 0

:tag
if /I "%FAKE_GH_SCENARIO%"=="endpoint-match" (
  echo HTTP/2.0 200 OK
  echo Content-Type: application/json
  echo(
  echo {"tag_name":"v0.1.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}
  exit /b 0
)
if /I "%FAKE_GH_SCENARIO%"=="unexpected-tag-status" (
  echo HTTP/2.0 500 Internal Server Error
  echo Content-Type: application/json
  echo(
  echo {"message":"Server error","status":500}
  exit /b 1
)
if /I "%FAKE_GH_SCENARIO%"=="malformed-tag-response" (
  echo HTTP/2.0 404 Not Found
  echo Content-Type: application/json
  echo(
  echo not-json
  exit /b 1
)
echo HTTP/2.0 404 Not Found
echo Content-Type: application/json
echo(
echo {"message":"Not Found","status":404}
exit /b 1
'@
    [IO.File]::WriteAllText($fakeGh, $fakeGhText, [Text.Encoding]::ASCII)
    $env:Path = $fakeRoot + ';' + $oldPath
    $env:GH_TOKEN = 'fake-token'
    $releaseStateCases = @(
        @{ Name = 'no-releases'; Expected = 0 },
        @{ Name = 'published-match'; Expected = 1; Needle = 'published' },
        @{ Name = 'draft-match'; Expected = 1; Needle = 'draft' },
        @{ Name = 'prerelease-match'; Expected = 1; Needle = 'prerelease' },
        @{ Name = 'unrelated-draft'; Expected = 0 },
        @{ Name = 'unrelated-published'; Expected = 0 },
        @{ Name = 'page2-match'; Expected = 1 },
        @{ Name = 'duplicate-match'; Expected = 1 },
        @{ Name = 'malformed-json'; Expected = 1 },
        @{ Name = 'api-failure'; Expected = 1 },
        @{ Name = 'pagination-failure'; Expected = 1 },
        @{ Name = 'endpoint-match'; Expected = 1 },
        @{ Name = 'unexpected-tag-status'; Expected = 1 },
        @{ Name = 'malformed-tag-response'; Expected = 1 }
    )
    foreach ($testCase in $releaseStateCases) {
        $env:FAKE_GH_SCENARIO = $testCase.Name
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $captured = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseStatePath -Repository 'example/repo' -Tag 'v0.1.0' 2>&1 | Out-String)
        }
        finally { $ErrorActionPreference = $oldPreference }
        $exitCode = $LASTEXITCODE
        Assert-True ($exitCode -eq $testCase.Expected) ('Release state case had unexpected exit code: ' + $testCase.Name)
        if ($testCase.ContainsKey('Needle')) { Assert-True ($captured -match $testCase.Needle) ('Release state case did not report its safe status: ' + $testCase.Name) }
    }
}
finally {
    $env:Path = $oldPath
    $env:GH_TOKEN = $oldGhToken
    $env:FAKE_GH_SCENARIO = $oldFakeScenario
    Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Workflow contract passed.'
