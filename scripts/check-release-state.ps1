[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Tag
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Convert-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Context)
    try {
        $value = $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ($Context + ' returned malformed JSON; refusing to continue.')
    }
    if ($null -eq $value) { throw ($Context + ' returned empty JSON; refusing to continue.') }
    return (, $value)
}

function Invoke-GhApi {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $stdoutPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '-stdout.txt')
    $stderrPath = Join-Path $tempRoot ([Guid]::NewGuid().ToString('N') + '-stderr.txt')
    try {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $exitCode = 1
            & gh @Arguments 1>$stdoutPath 2>$stderrPath
            if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE }
        }
        finally { $ErrorActionPreference = $oldPreference }
        [pscustomobject]@{
            ExitCode = $exitCode
            Stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
            Stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RequiredStringProperty {
    param([Parameter(Mandatory = $true)][pscustomobject]$Object, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Context)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string]) {
        throw ($Context + ' is malformed; missing string property ' + $Name + '.')
    }
    return [string]$property.Value
}

function Get-ReleaseState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Release)
    $states = New-Object 'System.Collections.Generic.List[string]'
    $draft = $Release.PSObject.Properties['draft']
    $prerelease = $Release.PSObject.Properties['prerelease']
    $publishedAt = $Release.PSObject.Properties['published_at']
    $draftValue = $false
    $draftKnown = $false
    if ($null -ne $draft -and $draft.Value -is [bool]) {
        $draftKnown = $true
        $draftValue = [bool]$draft.Value
        if ($draftValue) { [void]$states.Add('draft') }
    }
    if ($null -ne $prerelease -and $prerelease.Value -is [bool] -and [bool]$prerelease.Value) {
        [void]$states.Add('prerelease')
    }
    if ($null -ne $publishedAt -and $publishedAt.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$publishedAt.Value) -and (-not $draftKnown -or -not $draftValue)) {
        [void]$states.Add('published')
    }
    if ($states.Count -eq 0) { return 'status unavailable' }
    return ($states -join ', ')
}

function Get-HttpResponseBody {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bodyMatch = [regex]::Match($Text, '(?s)\r?\n\r?\n(?<body>.*)\z')
    if (-not $bodyMatch.Success) { throw 'Published-by-tag response had no parseable HTTP body.' }
    return $bodyMatch.Groups['body'].Value.Trim()
}

function Get-HttpStatus {
    param([Parameter(Mandatory = $true)][string]$Text)
    $matches = @([regex]::Matches($Text, '(?mi)^HTTP/\d(?:\.\d)?\s+(?<status>\d{3})\b'))
    if ($matches.Count -ne 1) { throw 'Published-by-tag response had an unexpected HTTP status line.' }
    return [int]$matches[0].Groups['status'].Value
}

Assert-True (-not [string]::IsNullOrWhiteSpace($Repository) -and $Repository -cmatch '^[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?$') 'Repository must be an owner/name identity.'
Assert-True (-not [string]::IsNullOrWhiteSpace($Tag)) 'Tag must not be empty.'
Assert-True (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) 'GH_TOKEN is required for authenticated Release checks.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('IncidentDocket-release-state-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $apiHeader = 'X-GitHub-Api-Version: 2022-11-28'
    $listEndpoint = 'repos/' + $Repository + '/releases?per_page=100'
    $listResult = Invoke-GhApi -Arguments @('api', '--paginate', '--slurp', '--method', 'GET', '--header', $apiHeader, $listEndpoint)
    if ($listResult.ExitCode -ne 0) {
        throw 'Could not retrieve the complete Release list; refusing to treat the failure as absence.'
    }

    $listJson = Convert-StrictJson -Text $listResult.Stdout -Context 'Paginated Release list'
    $topLevel = @($listJson)
    if ($topLevel.Count -gt 0) {
        $arrayItems = @($topLevel | Where-Object { $_ -is [System.Array] }).Count
        $objectItems = @($topLevel | Where-Object { $_ -is [pscustomobject] }).Count
        if ($arrayItems -eq $topLevel.Count) {
            $pages = $topLevel
        }
        elseif ($objectItems -eq $topLevel.Count) {
            $pages = @(,$topLevel)
        }
        else {
            throw 'Paginated Release list JSON had an invalid page shape; refusing to continue.'
        }

        $matches = @()
        foreach ($page in $pages) {
            if ($page -isnot [System.Array]) { throw 'Paginated Release list contained a non-array page.' }
            foreach ($release in @($page)) {
                if ($release -isnot [pscustomobject]) { throw 'Paginated Release list contained a non-object Release.' }
                $releaseTag = Get-RequiredStringProperty -Object $release -Name 'tag_name' -Context 'Release list entry'
                if ([string]::Equals($releaseTag, $Tag, [StringComparison]::Ordinal)) { $matches += $release }
            }
        }
        if ($matches.Count -gt 0) {
            $state = Get-ReleaseState -Release $matches[0]
            throw ('Release ' + $Tag + ' already exists (' + $state + '); refusing to overwrite or continue.')
        }
    }

    $encodedTag = [Uri]::EscapeDataString($Tag)
    $tagEndpoint = 'repos/' + $Repository + '/releases/tags/' + $encodedTag
    $tagResult = Invoke-GhApi -Arguments @('api', '--include', '--method', 'GET', '--header', $apiHeader, $tagEndpoint)
    $status = Get-HttpStatus -Text $tagResult.Stdout
    $body = Get-HttpResponseBody -Text $tagResult.Stdout
    $bodyJson = Convert-StrictJson -Text $body -Context 'Published-by-tag response'
    if ($status -eq 404) {
        Assert-True ($tagResult.ExitCode -ne 0) 'Published-by-tag endpoint returned 404 with a successful exit code.'
        Assert-True ($bodyJson -is [pscustomobject]) 'Published-by-tag 404 response was not an object.'
        $message = Get-RequiredStringProperty -Object $bodyJson -Name 'message' -Context 'Published-by-tag 404 response'
        $statusProperty = $bodyJson.PSObject.Properties['status']
        Assert-True ([string]::Equals($message, 'Not Found', [StringComparison]::Ordinal)) 'Published-by-tag endpoint returned an unexpected 404 response.'
        $statusIsExact = $null -ne $statusProperty -and (($statusProperty.Value -is [int] -or $statusProperty.Value -is [long]) -and [int64]$statusProperty.Value -eq 404 -or ($statusProperty.Value -is [string] -and [string]::Equals([string]$statusProperty.Value, '404', [StringComparison]::Ordinal)))
        Assert-True $statusIsExact 'Published-by-tag endpoint returned an unexpected 404 response.'
        Write-Output ('No existing Release found for ' + $Tag + '.')
        exit 0
    }
    if ($status -eq 200) {
        Assert-True ($tagResult.ExitCode -eq 0) 'Published-by-tag endpoint returned HTTP 200 with a failed exit code.'
        Assert-True ($bodyJson -is [pscustomobject]) 'Published-by-tag success response was not an object.'
        $releaseTag = Get-RequiredStringProperty -Object $bodyJson -Name 'tag_name' -Context 'Published-by-tag response'
        if ([string]::Equals($releaseTag, $Tag, [StringComparison]::Ordinal)) {
            $state = Get-ReleaseState -Release $bodyJson
            throw ('Release ' + $Tag + ' already exists (' + $state + '); refusing to overwrite or continue.')
        }
        throw 'Published-by-tag endpoint returned a different tag; refusing to continue.'
    }
    throw ('Published-by-tag endpoint returned unexpected HTTP status ' + $status + '; refusing to continue.')
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
