#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    $script:Srv = Start-StubEventServer

    function Invoke-TestCycle {
        param(
            [string]$Url = $script:Srv.Url,
            [string]$Token = 'tok',
            [int]$Batch = 50,
            [int]$Timeout = 5,
            [string]$HostName = 'test-host'
        )

        Invoke-ForwarderCycle `
            -OutboxPath $OutboxPath `
            -EndpointUri "$Url/api/v1/events/batch" `
            -Token $Token `
            -BatchSize $Batch `
            -Hostname $HostName `
            -DiagLogPath $ForwarderLogPath `
            -TimeoutSec $Timeout
    }

    function Add-TestOutbox {
        param([int]$Count = 3, [string]$Prefix = 'ev')

        $Base = [DateTimeOffset]::UtcNow.Ticks
        1..$Count | ForEach-Object {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId ("{0}-{1:D3}" -f $Prefix, $_) -Ticks ($Base + $_))
        }
    }

    function Get-Diag {
        if (Test-Path -LiteralPath $ForwarderLogPath) { return (Get-Content -LiteralPath $ForwarderLogPath -Raw) }
        return ''
    }
}

AfterAll {
    Stop-StubEventServer $script:Srv
    Remove-TestRoot $script:Root
}

Describe 'Get-NextForwarderInterval' {

    It '<Outcome> from <Current>s (base <Base>, max <Max>) gives <Expected>s' -TestCases @(
        @{ Outcome = 'Failed';    Current = 30;  Base = 30; Max = 900; Expected = 60 }
        @{ Outcome = 'Failed';    Current = 60;  Base = 30; Max = 900; Expected = 120 }
        @{ Outcome = 'Failed';    Current = 600; Base = 30; Max = 900; Expected = 900 }
        @{ Outcome = 'Failed';    Current = 900; Base = 30; Max = 900; Expected = 900 }
        @{ Outcome = 'Error';     Current = 30;  Base = 30; Max = 900; Expected = 60 }
        @{ Outcome = 'Delivered'; Current = 900; Base = 30; Max = 900; Expected = 30 }
        @{ Outcome = 'NoAck';     Current = 240; Base = 30; Max = 900; Expected = 30 }
        @{ Outcome = 'Idle';      Current = 240; Base = 30; Max = 900; Expected = 240 }
        @{ Outcome = 'Idle';      Current = 30;  Base = 30; Max = 900; Expected = 30 }
    ) {
        Get-NextForwarderInterval -Current $Current -Base $Base -Max $Max -Outcome $Outcome | Should -Be $Expected
    }

    It 'never backs off to less than the base interval when Max < Base (misconfiguration)' {
        Get-NextForwarderInterval -Current 30 -Base 30 -Max 10 -Outcome 'Failed' | Should -Be 30
    }

    It 'does not overflow on absurd values' {
        { Get-NextForwarderInterval -Current 2000000000 -Base 30 -Max 2100000000 -Outcome 'Failed' } | Should -Not -Throw
        Get-NextForwarderInterval -Current 2000000000 -Base 30 -Max 2100000000 -Outcome 'Failed' | Should -Be 2100000000
    }

    It 'reaches the cap after repeated failures, then stays there' {
        $Interval = 30
        1..12 | ForEach-Object { $Interval = Get-NextForwarderInterval -Current $Interval -Base 30 -Max 900 -Outcome 'Failed' }
        $Interval | Should -Be 900
    }
}

Describe 'Write-ForwarderDiag' {

    BeforeEach { Reset-TestRoot $script:Root }

    It 'appends "timestamp | message" lines' {
        Write-ForwarderDiag -Path $ForwarderLogPath -Message 'hello'
        Write-ForwarderDiag -Path $ForwarderLogPath -Message 'world'

        $Lines = @(Get-Content -LiteralPath $ForwarderLogPath)
        $Lines.Count | Should -Be 2
        $Lines[0] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d) \| hello$'
    }

    It 'rolls the file over to .old once it exceeds the size limit' {
        1..30 | ForEach-Object { Write-ForwarderDiag -Path $ForwarderLogPath -Message ('x' * 100) -MaxBytes 1000 }

        Test-Path -LiteralPath "$ForwarderLogPath.old" | Should -BeTrue
        (Get-Item -LiteralPath $ForwarderLogPath -ErrorAction SilentlyContinue).Length | Should -BeLessThan 1500
    }

    It 'is best-effort: an unwritable path never throws' {
        { Write-ForwarderDiag -Path (Join-Path $script:Root 'no/such/dir/x.log') -Message 'x' } | Should -Not -Throw
    }
}

Describe 'Invoke-ForwarderCycle' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $script:Srv.State.Mode = 'Accept'
        $script:Srv.State.StatusCode = 500
        $script:Srv.State.Requests.Clear()
    }

    Context 'nothing to do' {

        It 'is Idle and sends no request for an empty outbox' {
            $Result = Invoke-TestCycle

            $Result.Outcome | Should -Be 'Idle'
            $script:Srv.State.Requests.Count | Should -Be 0
        }

        It 'ignores files that are not *.json' {
            Set-Content -LiteralPath (Join-Path $OutboxPath 'notes.txt') -Value 'x'
            Set-Content -LiteralPath (Join-Path $OutboxPath 'old.json.corrupt') -Value '{}'

            (Invoke-TestCycle).Outcome | Should -Be 'Idle'
            $script:Srv.State.Requests.Count | Should -Be 0
        }

        It 'is Idle when the outbox directory does not exist' {
            Remove-Item -LiteralPath $OutboxPath -Recurse -Force

            (Invoke-TestCycle).Outcome | Should -Be 'Idle'
        }
    }

    Context 'successful delivery' {

        It 'delivers, deletes acknowledged files, and reports counts' {
            Add-TestOutbox -Count 4

            $Result = Invoke-TestCycle

            $Result.Outcome  | Should -Be 'Delivered'
            $Result.Sent     | Should -Be 4
            $Result.Accepted | Should -Be 4
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
        }

        It 'POSTs JSON to /api/v1/events/batch with a bearer token' {
            Add-TestOutbox -Count 1

            [void](Invoke-TestCycle -Token 'sekrit')

            $Request = $script:Srv.State.Requests[0]
            $Request.Method | Should -Be 'POST'
            $Request.Path   | Should -Be '/api/v1/events/batch'
            $Request.ContentType | Should -Match '^application/json'
            $Request.Authorization | Should -Be 'Bearer sekrit'
        }

        It 'sends {"host": ..., "events": [...]} matching the documented contract' {
            Add-TestOutbox -Count 3

            [void](Invoke-TestCycle -HostName 'pop-os')

            $Body = $script:Srv.State.Requests[0].Body | ConvertFrom-Json
            $Body.host | Should -Be 'pop-os'
            @($Body.events).Count | Should -Be 3
            $Body.events[0].EVENT_ID | Should -Be 'ev-001'
            $Body.events[0].EVENT    | Should -Be 'HEARTBEAT'
        }

        It 'sends a one-element events array as an array, not an object' {
            Add-TestOutbox -Count 1

            [void](Invoke-TestCycle)

            $script:Srv.State.Requests[0].Body | Should -Match '"events":\[\{'
        }

        It 'sends the oldest events first and honours the batch size' {
            Add-TestOutbox -Count 7

            $Result = Invoke-TestCycle -Batch 3

            $Result.Sent | Should -Be 3
            $Sent = @(($script:Srv.State.Requests[0].Body | ConvertFrom-Json).events | ForEach-Object EVENT_ID)
            $Sent | Should -Be @('ev-001', 'ev-002', 'ev-003')

            $Remaining = @(Get-OutboxFiles $OutboxPath | ForEach-Object { ($_.Name -replace '^\d+_', '') -replace '\.json$', '' })
            $Remaining | Should -Be @('ev-004', 'ev-005', 'ev-006', 'ev-007')
        }

        It 'drains a backlog in order across successive cycles' {
            Add-TestOutbox -Count 7

            1..3 | ForEach-Object { [void](Invoke-TestCycle -Batch 3) }

            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
            $script:Srv.State.Requests.Count | Should -Be 3
            $All = @($script:Srv.State.Requests | ForEach-Object { ($_.Body | ConvertFrom-Json).events } | ForEach-Object EVENT_ID)
            $All | Should -Be @(1..7 | ForEach-Object { "ev-{0:D3}" -f $_ })
        }

        It 'handles a large batch (500 events)' {
            Add-TestOutbox -Count 500

            $Result = Invoke-TestCycle -Batch 500

            $Result.Accepted | Should -Be 500
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
        }

        It 'writes a "Batch delivered" diagnostic to grongoMonitor.log' {
            Add-TestOutbox -Count 2
            [void](Invoke-TestCycle)

            Get-Diag | Should -Match 'Batch delivered\. Sent=2 Accepted=2'
        }
    }

    Context 'wire fidelity' {

        It 'sends TIMESTAMP and DATA timestamps byte-for-byte (originating offset preserved)' {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'ts-1' -Timestamp '2026-09-13T21:25:23-05:00' `
                -EventType 'BOOT' -Data @{ BOOT_TIME = '2026-09-13T08:10:15.5000000-05:00' })

            [void](Invoke-TestCycle)

            $Body = $script:Srv.State.Requests[0].Body
            $Body | Should -Match ([regex]::Escape('"TIMESTAMP":"2026-09-13T21:25:23-05:00"'))
            $Body | Should -Match ([regex]::Escape('"BOOT_TIME":"2026-09-13T08:10:15.5000000-05:00"'))
        }

        It 'does not convert timestamps to the machine timezone (regression: DateTime round-trip)' {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'ts-2' -Timestamp '2026-01-01T00:30:00+09:00')

            [void](Invoke-TestCycle)

            $script:Srv.State.Requests[0].Body | Should -Match ([regex]::Escape('2026-01-01T00:30:00+09:00'))
            $script:Srv.State.Requests[0].Body | Should -Not -Match '2025-12-31'
        }

        It 'keeps string values that merely look like numbers or dates as strings' {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'ts-3' -Data @{ CODE = '007'; ID = '1e3' })

            [void](Invoke-TestCycle)

            $Body = $script:Srv.State.Requests[0].Body
            $Body | Should -Match '"CODE":"007"'
            $Body | Should -Match '"ID":"1e3"'
        }

        It 'delivers unicode intact' {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'u-1' -Data @{ CONTAINER = 'café-日本-🐳' })

            [void](Invoke-TestCycle)

            (($script:Srv.State.Requests[0].Body | ConvertFrom-Json).events[0].DATA.CONTAINER) | Should -Be 'café-日本-🐳'
        }

        It 'JSON-escapes an awkward hostname so the body stays valid' {
            Add-TestOutbox -Count 1

            [void](Invoke-TestCycle -HostName 'we"ird\host')

            (($script:Srv.State.Requests[0].Body | ConvertFrom-Json).host) | Should -Be 'we"ird\host'
        }
    }

    Context 'authentication header' {

        It 'omits the Authorization header entirely when there is no token' {
            Add-TestOutbox -Count 1

            [void](Invoke-TestCycle -Token '')

            $script:Srv.State.Requests[0].Authorization | Should -BeNullOrEmpty
        }

        It 'never writes the token into grongoMonitor.log, on success or failure' {
            Add-TestOutbox -Count 1
            [void](Invoke-TestCycle -Token 'SUPERSECRETTOKEN')

            $script:Srv.State.Mode = 'Status'
            Add-TestOutbox -Count 1 -Prefix 'again'
            [void](Invoke-TestCycle -Token 'SUPERSECRETTOKEN')

            Get-Diag | Should -Not -Match 'SUPERSECRETTOKEN'
        }
    }

    Context 'acknowledgement handling (at-least-once delivery)' {

        It 'deletes only the events the server acknowledged (partial ack)' {
            Add-TestOutbox -Count 4
            $script:Srv.State.Mode = 'AcceptSome'
            $script:Srv.State.AcceptCount = 2

            $Result = Invoke-TestCycle

            $Result.Outcome  | Should -Be 'Delivered'
            $Result.Accepted | Should -Be 2
            $Left = @(Get-OutboxFiles $OutboxPath | ForEach-Object { ($_.Name -replace '^\d+_', '') -replace '\.json$', '' })
            $Left | Should -Be @('ev-003', 'ev-004')
        }

        It 'retries unacknowledged events on the next cycle' {
            Add-TestOutbox -Count 3
            $script:Srv.State.Mode = 'AcceptSome'
            $script:Srv.State.AcceptCount = 1
            [void](Invoke-TestCycle)

            $script:Srv.State.Mode = 'Accept'
            [void](Invoke-TestCycle)

            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
            $Resent = @(($script:Srv.State.Requests[1].Body | ConvertFrom-Json).events | ForEach-Object EVENT_ID)
            $Resent | Should -Be @('ev-002', 'ev-003')
        }

        It 'deletes nothing for a 2xx with no accepted list: <Mode>' -TestCases @(
            @{ Mode = 'NoAck' }
            @{ Mode = 'NullAck' }
            @{ Mode = 'Text' }
        ) {
            Add-TestOutbox -Count 3
            $script:Srv.State.Mode = $Mode

            $Result = Invoke-TestCycle

            $Result.Outcome | Should -Be 'NoAck'
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 3
            Get-Diag | Should -Match "no 'accepted' list"
        }

        It 'treats an empty accepted list as delivered-but-nothing-ingested (keeps everything queued)' {
            Add-TestOutbox -Count 2
            $script:Srv.State.Mode = 'EmptyAck'

            $Result = Invoke-TestCycle

            $Result.Outcome  | Should -Be 'Delivered'
            $Result.Accepted | Should -Be 0
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 2
        }

        It 'ignores acknowledged IDs it never sent' {
            Add-TestOutbox -Count 2
            $script:Srv.State.Mode = 'Accept'

            { Invoke-TestCycle } | Should -Not -Throw
        }

        It 'deletes every file that shares a duplicated EVENT_ID once it is acknowledged' {
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'dup' -Ticks 1000)
            [void](Write-OutboxEventFile -Path $OutboxPath -EventId 'dup' -Ticks 2000)

            $Result = Invoke-TestCycle

            $Result.Sent | Should -Be 2
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
        }
    }

    Context 'failures keep everything queued' {

        It 'HTTP <Code> -> Failed, status captured, nothing deleted' -TestCases @(
            @{ Code = 401 }
            @{ Code = 403 }
            @{ Code = 408 }
            @{ Code = 429 }
            @{ Code = 500 }
            @{ Code = 502 }
            @{ Code = 503 }
        ) {
            Add-TestOutbox -Count 3
            $script:Srv.State.Mode = 'Status'
            $script:Srv.State.StatusCode = $Code

            $Result = Invoke-TestCycle

            $Result.Outcome    | Should -Be 'Failed'
            $Result.StatusCode | Should -Be $Code
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 3
            Get-Diag | Should -Match "HTTP $Code"
        }

        It 'connection refused -> Failed with no status code' {
            Add-TestOutbox -Count 2
            $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $Probe.Start(); $Port = $Probe.LocalEndpoint.Port; $Probe.Stop()

            $Result = Invoke-TestCycle -Url "http://127.0.0.1:$Port"

            $Result.Outcome | Should -Be 'Failed'
            $Result.StatusCode | Should -BeNullOrEmpty
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 2
        }

        It 'unresolvable host -> Failed' {
            Add-TestOutbox -Count 1

            (Invoke-TestCycle -Url 'http://no-such-host.invalid' -Timeout 5).Outcome | Should -Be 'Failed'
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 1
        }

        It 'a hung server times out -> Failed' {
            Add-TestOutbox -Count 1
            $script:Srv.State.Mode = 'Hang'

            $Watch = [Diagnostics.Stopwatch]::StartNew()
            $Result = Invoke-TestCycle -Timeout 1
            $Watch.Stop()

            $Result.Outcome | Should -Be 'Failed'
            $Watch.Elapsed.TotalSeconds | Should -BeLessThan 8
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 1
            $script:Srv.State.Mode = 'Accept'
        }

        It 'a malformed endpoint URI -> Failed (not an unhandled exception)' {
            Add-TestOutbox -Count 1

            $Result = $null
            { $Result = Invoke-ForwarderCycle -OutboxPath $OutboxPath -EndpointUri 'not a uri' -Token 't' -BatchSize 5 -Hostname 'h' -DiagLogPath $ForwarderLogPath } | Should -Not -Throw
            (Invoke-ForwarderCycle -OutboxPath $OutboxPath -EndpointUri 'not a uri' -Token 't' -BatchSize 5 -Hostname 'h' -DiagLogPath $ForwarderLogPath).Outcome | Should -Be 'Failed'
        }

        It 'recovers on the very next cycle once the server is healthy again' {
            Add-TestOutbox -Count 3
            $script:Srv.State.Mode = 'Status'
            [void](Invoke-TestCycle)
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 3

            $script:Srv.State.Mode = 'Accept'
            (Invoke-TestCycle).Outcome | Should -Be 'Delivered'
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
        }
    }

    Context 'corrupt and stale files' {

        It 'quarantines <Case> as .corrupt, still delivers the good files' -TestCases @(
            @{ Case = 'invalid JSON';           Content = '{ not json' }
            @{ Case = 'a file with no EVENT_ID'; Content = '{"EVENT":"X"}' }
            @{ Case = 'a blank EVENT_ID';       Content = '{"EVENT_ID":"  ","EVENT":"X"}' }
            @{ Case = 'a null EVENT_ID';        Content = '{"EVENT_ID":null}' }
            @{ Case = 'an empty file';          Content = '' }
            @{ Case = 'a JSON array';           Content = '[{"EVENT_ID":"a"}]' }
            @{ Case = 'a bare JSON number';     Content = '42' }
            @{ Case = 'a truncated write';      Content = '{"EVENT_ID":"a","EVENT":"HEART' }
            @{ Case = 'trailing garbage';       Content = '{"EVENT_ID":"a"} garbage' }
        ) {
            $Bad = Join-Path $OutboxPath '0000000000000000001_bad.json'
            Set-Content -LiteralPath $Bad -Value $Content -NoNewline
            Add-TestOutbox -Count 2

            $Result = Invoke-TestCycle

            $Result.Quarantined | Should -Be 1
            $Result.Sent        | Should -Be 2
            Test-Path -LiteralPath "$Bad.corrupt" | Should -BeTrue
            Test-Path -LiteralPath $Bad | Should -BeFalse
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
            Get-Diag | Should -Match 'Quarantining unreadable outbox file'
        }

        It 'does not loop on a corrupt file: once quarantined it is never picked up again' {
            Set-Content -LiteralPath (Join-Path $OutboxPath '1_bad.json') -Value 'nope'

            (Invoke-TestCycle).Outcome | Should -Be 'Idle'
            (Invoke-TestCycle).Outcome | Should -Be 'Idle'
            $script:Srv.State.Requests.Count | Should -Be 0
        }

        It 'sends no request when every file is corrupt' {
            1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $OutboxPath "$_-bad.json") -Value 'x' }

            $Result = Invoke-TestCycle

            $Result.Outcome | Should -Be 'Idle'
            $Result.Quarantined | Should -Be 3
            $script:Srv.State.Requests.Count | Should -Be 0
        }

        It 'accepts a file with a UTF-8 BOM (hand-edited on Windows)' {
            $Path = Join-Path $OutboxPath '0000000000000000001_bom.json'
            [System.IO.File]::WriteAllText($Path, '{"EVENT_ID":"bom-1","TIMESTAMP":"t","HOST":"h","EVENT":"X","DATA":{}}', [System.Text.UTF8Encoding]::new($true))

            (Invoke-TestCycle).Outcome | Should -Be 'Delivered'
            @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
        }

        It 'sweeps .tmp-* files older than 5 minutes but leaves fresh ones' {
            $Old   = Join-Path $OutboxPath '.tmp-old'
            $Fresh = Join-Path $OutboxPath '.tmp-fresh'
            Set-Content -LiteralPath $Old   -Value 'x'
            Set-Content -LiteralPath $Fresh -Value 'x'
            (Get-Item -LiteralPath $Old -Force).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)

            [void](Invoke-TestCycle)

            Test-Path -LiteralPath $Old   | Should -BeFalse
            Test-Path -LiteralPath $Fresh | Should -BeTrue
        }

        It 'never sends a .tmp-* file' {
            Set-Content -LiteralPath (Join-Path $OutboxPath '.tmp-abc') -Value '{"EVENT_ID":"tmp"}'

            (Invoke-TestCycle).Outcome | Should -Be 'Idle'
        }
    }
}

Describe 'Invoke-ForwarderLoop and the background runspace' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $script:Srv.State.Mode = 'Accept'
        $script:Srv.State.Requests.Clear()

        $Script:ForwarderControl    = [hashtable]::Synchronized(@{ Stop = $false })
        $Script:ForwarderWakeSignal = [System.Threading.AutoResetEvent]::new($false)
        $Script:ForwarderPowerShell = $null
        $Script:ForwarderRunspace   = $null
        $Script:ForwarderHandle     = $null
        $Script:ForwardingEnabled     = $true
        $Script:SuppressOutboxOnError = $false
        $Script:ForwarderPendingCount = 0

        $Script:ForwarderConfig = [ordered]@{
            ServerUrl         = $script:Srv.Url
            Token             = 'tok'
            BatchSize         = 50
            IntervalSeconds   = 1
            MaxBackoffSeconds = 2
        }
    }

    AfterEach {
        Stop-EventForwarder
    }

    It 'Get-ForwarderRunspaceScript defines every function the loop needs' {
        $Text = Get-ForwarderRunspaceScript

        foreach ($Name in 'Get-JsonPropertyOrNull', 'Write-ForwarderDiag', 'Get-NextForwarderInterval', 'Invoke-ForwarderCycle', 'Invoke-ForwarderLoop') {
            $Text | Should -Match "function $Name \{"
        }
    }

    It 'the injected script is self-contained: it runs in a fresh runspace and resolves every command' {
        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.Open()
        try {
            $PS = [powershell]::Create()
            $PS.Runspace = $Runspace
            [void]$PS.AddScript((Get-ForwarderRunspaceScript))
            [void]$PS.AddStatement().AddScript('(Get-Command Invoke-ForwarderLoop, Invoke-ForwarderCycle, Write-ForwarderDiag, Get-NextForwarderInterval, Get-JsonPropertyOrNull -ErrorAction Stop).Count')
            @($PS.Invoke())[-1] | Should -Be 5
            $PS.HadErrors | Should -BeFalse
        }
        finally { $Runspace.Dispose() }
    }

    It 'exits immediately and says why when no server is configured' {
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-ForwarderLoop -OutboxPath $OutboxPath -DiagLogPath $ForwarderLogPath -ServerUrl '' -Token 't' -BatchSize 5 `
            -IntervalSeconds 1 -MaxBackoffSeconds 2 -Hostname 'h' -WakeSignal $Script:ForwarderWakeSignal -Control $Script:ForwarderControl
        $Watch.Stop()

        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 2
        Get-Diag | Should -Match 'no server configured'
    }

    It 'does nothing (and logs start/stop) when Stop is already set' {
        $Script:ForwarderControl.Stop = $true
        Add-TestOutbox -Count 2

        Invoke-ForwarderLoop -OutboxPath $OutboxPath -DiagLogPath $ForwarderLogPath -ServerUrl $script:Srv.Url -Token 't' -BatchSize 5 `
            -IntervalSeconds 1 -MaxBackoffSeconds 2 -Hostname 'h' -WakeSignal $Script:ForwarderWakeSignal -Control $Script:ForwarderControl

        $script:Srv.State.Requests.Count | Should -Be 0
        Get-Diag | Should -Match 'Forwarder started'
        Get-Diag | Should -Match 'Forwarder stopped'
    }

    It 'delivers queued events from the real background runspace and empties the outbox' {
        Add-TestOutbox -Count 5

        Start-EventForwarder

        (Wait-Until { @(Get-OutboxFiles $OutboxPath).Count -eq 0 } -TimeoutSeconds 15) | Should -BeTrue
        $script:Srv.State.Requests.Count | Should -BeGreaterThan 0
        $script:Srv.State.Requests[0].Authorization | Should -Be 'Bearer tok'
    }

    It 'trims a trailing slash from the server URL' {
        $Script:ForwarderConfig.ServerUrl = "$($script:Srv.Url)/"
        Add-TestOutbox -Count 1

        Start-EventForwarder

        (Wait-Until { $script:Srv.State.Requests.Count -gt 0 } -TimeoutSeconds 15) | Should -BeTrue
        $script:Srv.State.Requests[0].Path | Should -Be '/api/v1/events/batch'
    }

    It 'wakes early when Add-OutboxEvent fills a batch (no waiting for the interval)' {
        $Script:ForwarderConfig.IntervalSeconds = 30
        $Script:ForwarderConfig.BatchSize       = 3

        Start-EventForwarder
        Start-Sleep -Seconds 2   # first (idle) cycle done; forwarder is now sleeping ~30 s

        1..3 | ForEach-Object { Add-OutboxEvent -EventId "w$_" -Timestamp 't' -EventType 'X' }

        (Wait-Until { @(Get-OutboxFiles $OutboxPath).Count -eq 0 } -TimeoutSeconds 8) | Should -BeTrue
    }

    It 'keeps events queued while the server is down, then delivers them after recovery' {
        $script:Srv.State.Mode = 'Status'
        Add-TestOutbox -Count 3

        Start-EventForwarder

        (Wait-Until { $script:Srv.State.Requests.Count -ge 1 } -TimeoutSeconds 10) | Should -BeTrue
        @(Get-OutboxFiles $OutboxPath).Count | Should -Be 3

        $script:Srv.State.Mode = 'Accept'

        (Wait-Until { @(Get-OutboxFiles $OutboxPath).Count -eq 0 } -TimeoutSeconds 20) | Should -BeTrue
    }

    It 'stops promptly on Stop-EventForwarder even while sleeping out a long interval' {
        $Script:ForwarderConfig.IntervalSeconds = 300

        Start-EventForwarder
        Start-Sleep -Milliseconds 800

        $Watch = [Diagnostics.Stopwatch]::StartNew()
        Stop-EventForwarder
        $Watch.Stop()

        $Watch.Elapsed.TotalSeconds | Should -BeLessThan 6
        Get-Diag | Should -Match 'Forwarder stopped'
    }

    It 'Stop-EventForwarder is a no-op when the forwarder was never started' {
        { Stop-EventForwarder } | Should -Not -Throw
    }

    It 'Stop-EventForwarder can be called twice' {
        Start-EventForwarder
        Stop-EventForwarder
        { Stop-EventForwarder } | Should -Not -Throw
    }
}
