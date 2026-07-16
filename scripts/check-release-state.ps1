[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag
)

$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('IncidentDocket-release-state-' + [Guid]::NewGuid().ToString('N'))
$stdoutPath = Join-Path $tempRoot 'stdout.txt'
$stderrPath = Join-Path $tempRoot 'stderr.txt'

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    & gh api --include --method GET ('repos/{0}/releases/tags/{1}' -f $Repository, $Tag) 1>$stdoutPath 2>$stderrPath
    $exitCode = $LASTEXITCODE
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
    if ($exitCode -eq 0) {
        throw ('Release ' + $Tag + ' already exists; refusing to overwrite or continue.')
    }
    if ($stdout -notmatch '(?mi)^HTTP/\d(?:\.\d)?\s+404\b') {
        $detail = (($stdout + "`n" + $stderr).Trim() -replace '\s+', ' ')
        throw ('Could not prove that Release ' + $Tag + ' is absent: ' + $detail)
    }
    Write-Output ('No existing Release found for ' + $Tag + '.')
    exit 0
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
