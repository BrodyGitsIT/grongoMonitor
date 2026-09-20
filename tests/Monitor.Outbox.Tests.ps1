#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams
}

AfterAll {
    Remove-TestRoot $script:Root
}

Describe 'New-OutboxFileName' {

    It 'is 19-digit ticks, an underscore, the EVENT_ID and .json' {
        $Id = [guid]::NewGuid().ToString()
        New-OutboxFileName -EventId $Id | Should -Match "^\d{19}_$Id\.json$"
    }

    It 'sorts lexicographically in creation order (what the forwarder relies on)' {
        $Names = 1..25 | ForEach-Object {
            Start-Sleep -Milliseconds 2
            New-OutboxFileName -EventId ([guid]::NewGuid().ToString())
        }

        @($Names | Sort-Object) | Should -Be @($Names)
    }

    It 'is independent of the local timezone / culture' {
        $Fi = $null
        if (Test-CultureAvailable 'ar-SA') {
            $Fi = Use-Culture 'ar-SA' { New-OutboxFileName -EventId 'x' }
            $Fi | Should -Match '^\d{19}_x\.json$'
        }
        else {
            Set-ItResult -Skipped -Because 'ar-SA culture is unavailable (invariant globalization)'
        }
    }

    It 'requires an EventId' {
        { New-OutboxFileName -EventId '' } | Should -Throw
    }
}

Describe 'Add-OutboxEvent' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled     = $true
        $Script:SuppressOutboxOnError = $false
        $Script:ForwarderPendingCount = 0
        $Script:ForwarderConfig       = [ordered]@{ BatchSize = 1000 }
        [void]$Script:ForwarderWakeSignal.Reset()
    }

    Context 'file contents and layout' {

        It 'writes one .json file whose content is the event record' {
            $Id = [guid]::NewGuid().ToString()
            Add-OutboxEvent -EventId $Id -Timestamp '2026-09-13T21:25:23-05:00' -EventType 'DOCKER_CRASHED' -Data @{ CONTAINER = 'nginx-proxy'; EXIT_CODE = '1' }

            $Files = @(Get-OutboxFiles $OutboxPath)
            $Files.Count | Should -Be 1
            $Files[0].Name | Should -Match "_$Id\.json$"

            $Raw = Get-Content -LiteralPath $Files[0].FullName -Raw
            $Raw | Should -Match '"EVENT_ID":"' 
            $Record = $Raw | ConvertFrom-Json
            $Record.EVENT_ID | Should -Be $Id
            $Record.EVENT    | Should -Be 'DOCKER_CRASHED'
            $Record.HOST     | Should -Be $Hostname
            $Record.DATA.CONTAINER | Should -Be 'nginx-proxy'
            $Record.DATA.EXIT_CODE | Should -Be '1'
        }

        It 'stores the timestamp string exactly as given (offset intact)' {
            Add-OutboxEvent -EventId 'e1' -Timestamp '2026-09-13T21:25:23-05:00' -EventType 'X'

            $Raw = Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw
            $Raw | Should -Match '"TIMESTAMP":"2026-09-13T21:25:23-05:00"'
        }

        It 'writes compact single-line JSON with no trailing newline' {
            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' -Data @{ A = 'b' }

            $Raw = [System.IO.File]::ReadAllText((Get-OutboxFiles $OutboxPath)[0].FullName)
            $Raw | Should -Not -Match "[\r\n]"
        }

        It 'writes an empty DATA object for events with no data' {
            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'HEARTBEAT'

            (Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw) | Should -Match '"DATA":\{\}'
        }

        It 'leaves no .tmp-* file behind after a successful write' {
            1..10 | ForEach-Object { Add-OutboxEvent -EventId "e$_" -Timestamp 't' -EventType 'X' }

            @(Get-ChildItem -LiteralPath $OutboxPath -Filter '.tmp-*' -Force).Count | Should -Be 0
            (Get-OutboxFiles $OutboxPath).Count | Should -Be 10
        }

        It 'preserves original value types (ints stay ints)' {
            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' -Data @{ EXIT_CODE = 137 }

            (Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw) | Should -Match '"EXIT_CODE":137'
        }

        It 'round-trips unicode, quotes, backslashes and newlines in data (JSON-escaped)' {
            $Message = "café `"quoted`" back\slash`nnewline 日本 🐳"
            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' -Data @{ MESSAGE = $Message }

            $Record = Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw | ConvertFrom-Json
            $Record.DATA.MESSAGE | Should -Be $Message
        }

        It 'keeps the raw (unsanitised) value: "|" is only rewritten in events.log, not in the outbox' {
            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' -Data @{ MESSAGE = 'a|b' }

            (Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw | ConvertFrom-Json).DATA.MESSAGE | Should -Be 'a|b'
        }

        It 'orders files by creation (oldest first by name)' {
            1..8 | ForEach-Object {
                Add-OutboxEvent -EventId ("e{0:D2}" -f $_) -Timestamp 't' -EventType 'X'
                Start-Sleep -Milliseconds 3
            }

            $Ids = @(Get-OutboxFiles $OutboxPath | ForEach-Object { ($_.Name -replace '^\d+_', '') -replace '\.json$', '' })
            $Ids | Should -Be @(1..8 | ForEach-Object { "e{0:D2}" -f $_ })
        }

        It 'produces a file the forwarder accepts (EVENT_ID present and parseable)' {
            Add-OutboxEvent -EventId 'abc' -Timestamp 't' -EventType 'X'

            $Parsed = Get-Content -LiteralPath (Get-OutboxFiles $OutboxPath)[0].FullName -Raw | ConvertFrom-Json
            Get-JsonPropertyOrNull $Parsed 'EVENT_ID' | Should -Be 'abc'
        }
    }

    Context 'batch wake signal' {

        It 'does not signal the forwarder before a full batch has queued' {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 3 }

            1..2 | ForEach-Object { Add-OutboxEvent -EventId "e$_" -Timestamp 't' -EventType 'X' }

            $Script:ForwarderWakeSignal.WaitOne(0) | Should -BeFalse
        }

        It 'signals as soon as the batch fills, and resets the counter' {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 3 }

            1..3 | ForEach-Object { Add-OutboxEvent -EventId "e$_" -Timestamp 't' -EventType 'X' }

            $Script:ForwarderPendingCount | Should -Be 0
            $Script:ForwarderWakeSignal.WaitOne(0) | Should -BeTrue
        }

        It 'signals again for each subsequent full batch' {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 2 }

            1..2 | ForEach-Object { Add-OutboxEvent -EventId "a$_" -Timestamp 't' -EventType 'X' }
            [void]$Script:ForwarderWakeSignal.WaitOne(0)
            1..2 | ForEach-Object { Add-OutboxEvent -EventId "b$_" -Timestamp 't' -EventType 'X' }

            $Script:ForwarderWakeSignal.WaitOne(0) | Should -BeTrue
        }

        It 'signals on every event when the batch size is 1' {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 1 }

            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X'

            $Script:ForwarderWakeSignal.WaitOne(0) | Should -BeTrue
        }

        It 'survives a $null wake signal' {
            $Script:ForwarderConfig = [ordered]@{ BatchSize = 1 }
            $Saved = $Script:ForwarderWakeSignal
            try {
                $Script:ForwarderWakeSignal = $null
                { Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' } | Should -Not -Throw
            }
            finally { $Script:ForwarderWakeSignal = $Saved }
        }
    }

    Context 'failure handling' {

        It 'never throws to the caller when the outbox directory is missing' {
            $OutboxPath = Join-Path $script:Root 'does-not-exist'

            { Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' } | Should -Not -Throw
        }

        It 'logs a single SERVICE_ERROR for the failed enqueue, without recursing' {
            $OutboxPath = Join-Path $script:Root 'does-not-exist'

            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X'

            $Errors = @(Read-EventLogRecords $LogPath | Where-Object Event -eq 'SERVICE_ERROR')
            $Errors.Count | Should -Be 1
            $Errors[0].Data['COMPONENT'] | Should -Be 'EventForwarder'
            $Errors[0].Data['MESSAGE']   | Should -Match 'Failed to enqueue event'
        }

        It 'resets the recursion guard afterwards so later failures are still reported' {
            $OutboxPath = Join-Path $script:Root 'does-not-exist'

            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X'
            Add-OutboxEvent -EventId 'e2' -Timestamp 't' -EventType 'X'

            $Script:SuppressOutboxOnError | Should -BeFalse
            @(Read-EventLogRecords $LogPath | Where-Object Event -eq 'SERVICE_ERROR').Count | Should -Be 2
        }

        It 'does not report a second error while a report is already in flight' {
            $OutboxPath = Join-Path $script:Root 'does-not-exist'
            $Script:SuppressOutboxOnError = $true

            Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X'

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'swallows a failure of the error report itself (log unwritable too)' {
            $OutboxPath = Join-Path $script:Root 'does-not-exist'
            $LogPath    = Join-Path $script:Root 'also/does-not-exist/events.log'

            { Add-OutboxEvent -EventId 'e1' -Timestamp 't' -EventType 'X' } | Should -Not -Throw
            $Script:SuppressOutboxOnError | Should -BeFalse
        }
    }
}
