param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("system_events", "application_events", "os", "display_drivers")]
    [string]$Action,
    [string]$WindowStartUtc,
    [string]$IncidentTimeUtc,
    [string]$WindowEndUtc
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"
$VerbosePreference = "SilentlyContinue"
$DebugPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Write-Payload {
    param(
        [string]$Status,
        [object[]]$Items
    )

    $payload = [PSCustomObject][ordered]@{
        status = $Status
        items = $Items
    }
    $json = ConvertTo-Json -InputObject $payload -Compress -Depth 4
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::Out.WriteLine([Convert]::ToBase64String($utf8.GetBytes($json)))
}

function Write-EventPayload {
    param(
        [string]$Status,
        [object[]]$Items,
        [bool]$TruncatedBefore,
        [bool]$TruncatedAfter
    )

    $payload = [PSCustomObject][ordered]@{
        status = $Status
        items = $Items
        truncated_before = $TruncatedBefore
        truncated_after = $TruncatedAfter
    }
    $json = ConvertTo-Json -InputObject $payload -Compress -Depth 4
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::Out.WriteLine([Convert]::ToBase64String($utf8.GetBytes($json)))
}

function Get-EventBatch {
    param(
        [hashtable]$Filter,
        [bool]$Oldest
    )

    try {
        if ($Oldest) {
            return @(Get-WinEvent -FilterHashtable $Filter -Oldest -MaxEvents 26 -ErrorAction Stop)
        }
        return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 26 -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -match "^NoMatchingEventsFound") {
            return @()
        }
        throw
    }
}

function Convert-EventRecord {
    param([object]$Record)

    $message = if ($null -eq $Record.Message) { "" } else { [string]$Record.Message }
    if ($message.Length -gt 10000) {
        $message = $message.Substring(0, 10000)
    }
    return [PSCustomObject][ordered]@{
        TimeCreated = $Record.TimeCreated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [Globalization.CultureInfo]::InvariantCulture)
        LogName = [string]$Record.LogName
        ProviderName = [string]$Record.ProviderName
        Id = [int]$Record.Id
        Level = [int]$Record.Level
        RecordId = [string]$Record.RecordId
        Message = $message
    }
}

try {
    if ($Action -eq "system_events" -or $Action -eq "application_events") {
        $format = "yyyy-MM-ddTHH:mm:ss.fff'Z'"
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $style = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $windowStart = [DateTime]::ParseExact($WindowStartUtc, $format, $culture, $style).ToLocalTime()
        $incidentTime = [DateTime]::ParseExact($IncidentTimeUtc, $format, $culture, $style).ToLocalTime()
        $windowEnd = [DateTime]::ParseExact($WindowEndUtc, $format, $culture, $style).ToLocalTime()
        $logName = if ($Action -eq "system_events") { "System" } else { "Application" }

        $before = @()
        $beforeEnd = if ($incidentTime -lt $windowEnd) { $incidentTime } else { $windowEnd }
        if ($windowStart -le $beforeEnd) {
            $before = @(Get-EventBatch -Filter @{
                LogName = $logName
                Level = @(1, 2, 3)
                StartTime = $windowStart
                EndTime = $beforeEnd
            } -Oldest $false)
        }
        $after = @()
        $afterStart = if ($incidentTime -gt $windowStart) { $incidentTime } else { $windowStart }
        if ($afterStart -le $windowEnd) {
            $after = @(Get-EventBatch -Filter @{
                LogName = $logName
                Level = @(1, 2, 3)
                StartTime = $afterStart
                EndTime = $windowEnd
            } -Oldest $true)
        }

        $truncatedBefore = $before.Count -gt 25
        $truncatedAfter = $after.Count -gt 25
        $selected = @($before | Select-Object -First 25) + @($after | Select-Object -First 25)
        $seen = @{}
        $items = @($selected | ForEach-Object {
            $key = "{0}|{1}|{2}" -f $_.LogName, $_.RecordId, $_.TimeCreated.ToUniversalTime().Ticks
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                Convert-EventRecord -Record $_
            }
        })
        $status = if ($items.Count -eq 0) { "no_data" } else { "ok" }
        Write-EventPayload -Status $status -Items $items -TruncatedBefore $truncatedBefore -TruncatedAfter $truncatedAfter
        exit 0
    }

    if ($Action -eq "os") {
        $record = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $record) {
            Write-Payload -Status "no_data" -Items @()
            exit 0
        }

        $lastBoot = if ($record.LastBootUpTime -is [DateTime]) {
            $record.LastBootUpTime.ToUniversalTime().ToString("o")
        } else {
            [string]$record.LastBootUpTime
        }
        $item = [PSCustomObject][ordered]@{
            Caption = [string]$record.Caption
            Version = [string]$record.Version
            BuildNumber = [string]$record.BuildNumber
            OSArchitecture = [string]$record.OSArchitecture
            LastBootUpTime = $lastBoot
        }
        Write-Payload -Status "ok" -Items @($item)
        exit 0
    }

    $records = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass = 'DISPLAY'" -ErrorAction Stop |
        Sort-Object DeviceName, DriverVersion, DriverDate, Manufacturer, DriverProviderName, Status, IsSigned |
        Select-Object -First 20)
    if ($records.Count -eq 0) {
        Write-Payload -Status "no_data" -Items @()
        exit 0
    }

    $items = @($records | ForEach-Object {
        $driverDate = if ($_.DriverDate -is [DateTime]) {
            $_.DriverDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ", [Globalization.CultureInfo]::InvariantCulture)
        } elseif ($null -eq $_.DriverDate) {
            ""
        } else {
            [string]$_.DriverDate
        }
        [PSCustomObject][ordered]@{
            DeviceName = [string]$_.DeviceName
            Manufacturer = [string]$_.Manufacturer
            DriverProviderName = [string]$_.DriverProviderName
            DriverVersion = [string]$_.DriverVersion
            DriverDate = $driverDate
            IsSigned = [bool]$_.IsSigned
            Status = [string]$_.Status
        }
    })
    Write-Payload -Status "ok" -Items $items
} catch {
    $denied = $_.Exception -is [UnauthorizedAccessException] -or $_.Exception.Message -match "Access.*denied|0x80041003"
    $status = if ($denied) { "denied" } else { "failed" }
    [Console]::Error.WriteLine("incident-docket collector $status")
    if ($Action -eq "system_events" -or $Action -eq "application_events") {
        Write-EventPayload -Status $status -Items @() -TruncatedBefore $false -TruncatedAfter $false
    } else {
        Write-Payload -Status $status -Items @()
    }
}
