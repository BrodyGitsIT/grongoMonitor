#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $Script:HasFi = Test-CultureAvailable 'fi-FI'
    $Script:HasTh = Test-CultureAvailable 'th-TH'
    $Script:HasAr = Test-CultureAvailable 'ar-SA'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    $script:Log = $MonitorParams.LogPath
}

AfterAll {
    Remove-TestRoot $script:Root
}

Describe 'Write-EventLog' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled     = $false
        $Script:SuppressOutboxOnError = $false
    }

    Context 'line format' {

        It 'writes "TIMESTAMP | HOST=name | EVENT=type" for an event with no data' {
            Write-EventLog -Event 'HEARTBEAT'

            $Lines = @(Get-Content -LiteralPath $script:Log)
            $Lines.Count | Should -Be 1
            $Lines[0] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d) \| HOST=\S+ \| EVENT=HEARTBEAT$'
        }

        It 'uses the detected hostname' {
            Write-EventLog -Event 'X'
            (Read-EventLogRecords $script:Log)[0].Host | Should -Be $Hostname
        }

        It 'appends key=value fields for each data entry' {
            Write-EventLog -Event 'DOCKER_CRASHED' -Data @{ CONTAINER = 'web'; EXIT_CODE = '137' }

            $Record = (Read-EventLogRecords $script:Log)[0]
            $Record.Data['CONTAINER'] | Should -Be 'web'
            $Record.Data['EXIT_CODE'] | Should -Be '137'
        }

        It 'appends (never overwrites) across calls, one line per event' {
            1..5 | ForEach-Object { Write-EventLog -Event "E$_" }

            @(Get-EventNames $script:Log) | Should -Be @('E1', 'E2', 'E3', 'E4', 'E5')
        }

        It 'never writes the internal EVENT_ID into events.log' {
            Write-EventLog -Event 'X' -Data @{ A = 'b' }
            (Get-Content -LiteralPath $script:Log -Raw) | Should -Not -Match 'EVENT_ID'
        }

        It 'accepts an empty Data hashtable' {
            { Write-EventLog -Event 'X' -Data @{} } | Should -Not -Throw
            (Read-EventLogRecords $script:Log)[0].Data.Count | Should -Be 0
        }
    }

    Context 'value sanitising (each event must stay on exactly one line)' {

        It 'replaces "|" in values with "/" so the field separator is unambiguous' {
            Write-EventLog -Event 'X' -Data @{ MESSAGE = 'a|b||c' }

            @(Get-Content -LiteralPath $script:Log).Count | Should -Be 1
            (Read-EventLogRecords $script:Log)[0].Data['MESSAGE'] | Should -Be 'a/b//c'
        }

        It 'flattens LF, CR and CRLF in values to spaces' -TestCases @(
            @{ Name = 'LF';   Value = "line1`nline2" }
            @{ Name = 'CR';   Value = "line1`rline2" }
            @{ Name = 'CRLF'; Value = "line1`r`nline2" }
        ) {
            Write-EventLog -Event 'X' -Data @{ MESSAGE = $Value }

            @(Get-Content -LiteralPath $script:Log).Count | Should -Be 1
            (Read-EventLogRecords $script:Log)[0].Data['MESSAGE'] | Should -Match '^line1\s+line2$'
        }

        It 'keeps a multi-line stderr blob on one line' {
            $Blob = "Cannot connect to the Docker daemon`nIs the docker daemon running?`n"
            Write-EventLog -Event 'DOCKER_MONITOR_FAILED' -Data @{ MESSAGE = $Blob }

            @(Get-Content -LiteralPath $script:Log).Count | Should -Be 1
        }

        It 'writes a null value as an empty string' {
            Write-EventLog -Event 'X' -Data @{ A = $null }
            (Get-Content -LiteralPath $script:Log) | Should -Match '\| A=$'
        }

        It 'writes an empty-string value as KEY=' {
            Write-EventLog -Event 'X' -Data @{ A = '' }
            (Get-Content -LiteralPath $script:Log) | Should -Match '\| A=$'
        }

        It 'preserves "=" inside a value' {
            Write-EventLog -Event 'X' -Data @{ CMD = 'a=b=c' }
            (Read-EventLogRecords $script:Log)[0].Data['CMD'] | Should -Be 'a=b=c'
        }

        It 'stringifies non-string values (int, double, bool)' {
            Write-EventLog -Event 'X' -Data @{ I = 42; D = 1.5; B = $true }

            $Data = (Read-EventLogRecords $script:Log)[0].Data
            $Data['I'] | Should -Be '42'
            $Data['D'] | Should -Be '1.5'
            $Data['B'] | Should -Be 'True'
        }

        It 'round-trips unicode (accents, CJK, emoji) as UTF-8' {
            $Value = 'café 日本語 🐳'
            Write-EventLog -Event 'X' -Data @{ CONTAINER = $Value }

            $Text = [System.IO.File]::ReadAllText($script:Log, [System.Text.Encoding]::UTF8)
            $Text | Should -Match ([regex]::Escape($Value))
        }

        It 'does not write a UTF-8 BOM' {
            Write-EventLog -Event 'X'

            $Bytes = [System.IO.File]::ReadAllBytes($script:Log)
            ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
        }

        It 'handles a very large value (256 KiB) on a single line' {
            $Big = 'x' * 262144
            Write-EventLog -Event 'X' -Data @{ MESSAGE = $Big }

            @(Get-Content -LiteralPath $script:Log).Count | Should -Be 1
            (Get-Item -LiteralPath $script:Log).Length | Should -BeGreaterThan 262144
        }
    }

    Context 'parameter validation and failure' {

        It 'requires a non-empty -Event' {
            { Write-EventLog -Event '' } | Should -Throw
        }

        It 'throws (does not swallow) when the log cannot be written' {
            $LogPath = Join-Path $script:Root 'no-such-dir/events.log'
            { Write-EventLog -Event 'X' } | Should -Throw
        }
    }

    Context 'timestamps' {

        It 'Get-EventTimestamp is second-precision ISO-8601 with the local UTC offset' {
            Get-EventTimestamp | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$'
        }

        It 'is within a couple of seconds of now' {
            $Parsed = [DateTimeOffset]::Parse((Get-EventTimestamp), [System.Globalization.CultureInfo]::InvariantCulture)
            ([DateTimeOffset]::Now - $Parsed).TotalSeconds | Should -BeLessThan 3
        }

        It 'is not affected by a fi-FI culture (would otherwise use "." as time separator)' -Skip:(-not $Script:HasFi) {
            $Stamp = Use-Culture 'fi-FI' { Get-EventTimestamp }
            $Stamp | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d'
        }

        It 'is not affected by a th-TH culture (Buddhist-era year)' -Skip:(-not $Script:HasTh) {
            $Stamp = Use-Culture 'th-TH' { Get-EventTimestamp }
            $Stamp | Should -Match '^20\d\d-'
        }

        It 'is not affected by an ar-SA culture (Hijri calendar)' -Skip:(-not $Script:HasAr) {
            $Stamp = Use-Culture 'ar-SA' { Get-EventTimestamp }
            $Stamp | Should -Match '^20\d\d-'
        }
    }

    Context 'outbox hand-off' {

        BeforeEach {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 1000 }
        }

        It 'does not enqueue when forwarding is disabled' {
            $Script:ForwardingEnabled = $false
            Write-EventLog -Event 'X'

            @(Get-OutboxFiles (Join-Path $script:Root 'outbox')).Count | Should -Be 0
        }

        It 'enqueues exactly one outbox file per event when forwarding is enabled' {
            $Script:ForwardingEnabled = $true
            Write-EventLog -Event 'A'
            Write-EventLog -Event 'B'

            @(Get-OutboxFiles (Join-Path $script:Root 'outbox')).Count | Should -Be 2
        }

        It 'queues the same timestamp, event name and data that the log line has' {
            $Script:ForwardingEnabled = $true
            Write-EventLog -Event 'DOCKER_CRASHED' -Data @{ CONTAINER = 'web'; EXIT_CODE = '1' }

            $Log    = (Read-EventLogRecords $script:Log)[0]
            $Queued = Get-Content -LiteralPath (Get-OutboxFiles (Join-Path $script:Root 'outbox'))[0].FullName -Raw | ConvertFrom-Json

            $Queued.EVENT | Should -Be $Log.Event
            $Queued.HOST  | Should -Be $Log.Host
            $Queued.DATA.CONTAINER | Should -Be 'web'
            ($Queued.TIMESTAMP -is [string] -or $Queued.TIMESTAMP -is [datetime]) | Should -BeTrue
        }

        It 'does not enqueue while SuppressOutboxOnError is set (recursion guard)' {
            $Script:ForwardingEnabled     = $true
            $Script:SuppressOutboxOnError = $true
            Write-EventLog -Event 'X'

            @(Get-OutboxFiles (Join-Path $script:Root 'outbox')).Count | Should -Be 0
        }

        It 'still writes the local log line when the outbox is broken' {
            $Script:ForwardingEnabled = $true
            $OutboxPath = Join-Path $script:Root 'gone'

            { Write-EventLog -Event 'X' } | Should -Not -Throw

            @(Get-EventNames $script:Log) | Should -Contain 'X'
        }
    }
}
