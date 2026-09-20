#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

# End-to-end tests: the real script runs as a real child process, against a
# fake `docker` executable and (for forwarding) the real stub HTTP server.
# POSIX only - the fake docker is a shell script and signals are POSIX signals.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    $Script:SkipIntegration = $isWindows
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:PwshPath = (Get-Process -Id $PID).Path

    function New-IntegrationSandbox {
        $Root = New-TestRoot
        $Bin  = Join-Path $Root 'bin'
        New-Item -ItemType Directory -Path $Bin | Out-Null

        $Docker = @'
#!/bin/sh
if [ "$1" = "version" ]; then echo "27.0.0"; exit 0; fi
if [ "$1" = "events" ]; then
  echo "$*" >> "$FAKE_DOCKER_ARGS_LOG"
  [ -n "$FAKE_DOCKER_EVENTS" ] && [ -f "$FAKE_DOCKER_EVENTS" ] && cat "$FAKE_DOCKER_EVENTS"
  if [ -n "$FAKE_DOCKER_EVENTS_EXIT" ]; then echo "fake daemon error" >&2; exit "$FAKE_DOCKER_EVENTS_EXIT"; fi
  exec sleep "${FAKE_DOCKER_SLEEP:-120}"
fi
exit 0
'@
        $DockerPath = Join-Path $Bin 'docker'
        Set-Content -LiteralPath $DockerPath -Value $Docker -NoNewline
        & chmod +x $DockerPath

        return [pscustomobject]@{
            Root   = $Root
            Bin    = $Bin
            Params = (Get-MonitorParameters -Root $Root)
        }
    }

    function Start-MonitorProcess {
        param(
            [Parameter(Mandatory)]$Sandbox,
            [string[]]$ExtraArgs = @(),
            [hashtable]$Environment = @{}
        )

        $Info = [System.Diagnostics.ProcessStartInfo]::new()
        $Info.FileName = $script:PwshPath
        foreach ($A in '-NoProfile', '-NonInteractive', '-File', $Script:MonitorScript) { [void]$Info.ArgumentList.Add($A) }
        foreach ($Key in $Sandbox.Params.Keys) {
            [void]$Info.ArgumentList.Add("-$Key")
            [void]$Info.ArgumentList.Add([string]$Sandbox.Params[$Key])
        }
        foreach ($A in $ExtraArgs) { [void]$Info.ArgumentList.Add($A) }

        $Info.UseShellExecute = $false
        $Info.RedirectStandardOutput = $true
        $Info.RedirectStandardError  = $true
        $Info.Environment['HOME'] = $Sandbox.Root
        $Info.Environment['PATH'] = "$($Sandbox.Bin)$([System.IO.Path]::PathSeparator)$($env:PATH)"
        $Info.Environment['FAKE_DOCKER_ARGS_LOG'] = Join-Path $Sandbox.Root 'docker-args.log'
        foreach ($Name in 'GRONGO_EVENT_SERVER', 'GRONGO_EVENT_TOKEN', 'GRONGO_EVENT_BATCH_SIZE', 'GRONGO_EVENT_INTERVAL') {
            [void]$Info.Environment.Remove($Name)
        }
        foreach ($Key in $Environment.Keys) { $Info.Environment[$Key] = [string]$Environment[$Key] }

        $Process = [System.Diagnostics.Process]::Start($Info)

        return [pscustomobject]@{
            Process = $Process
            Out     = $Process.StandardOutput.ReadToEndAsync()
            Err     = $Process.StandardError.ReadToEndAsync()
            Log     = $Sandbox.Params.LogPath
        }
    }

    function Stop-MonitorProcess {
        # SIGTERM is what `systemctl stop` sends.
        param($Handle, [int]$TimeoutSeconds = 20)

        if ($null -eq $Handle -or $Handle.Process.HasExited) { return $Handle.Process.ExitCode }

        & kill -TERM $Handle.Process.Id

        if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
            $Handle.Process.Kill($true)
            return $null
        }

        return $Handle.Process.ExitCode
    }

    function Wait-ForEvent {
        param($Handle, [string]$Name, [int]$Count = 1, [int]$TimeoutSeconds = 30)

        Wait-Until { @(Get-EventNames $Handle.Log | Where-Object { $_ -eq $Name }).Count -ge $Count } -TimeoutSeconds $TimeoutSeconds
    }
}

Describe 'grongoMonitor.ps1 as a real process' -Skip:$Script:SkipIntegration {

    Context 'dot-sourcing is side-effect free' {

        It 'loads the functions without starting the loop or touching the filesystem' {
            $Root = New-TestRoot
            try {
                $Params = Get-MonitorParameters -Root (Join-Path $Root 'never-created')
                $Command = ". '$($Script:MonitorScript)' -LogPath '$($Params.LogPath)' -StatePath '$($Params.StatePath)' -OutboxPath '$($Params.OutboxPath)'; (Get-Command Write-EventLog, Invoke-GrongoMonitor).Count"

                $Watch = [Diagnostics.Stopwatch]::StartNew()
                $Output = & $script:PwshPath -NoProfile -NonInteractive -Command $Command
                $Watch.Stop()

                $Output | Should -Be '2'
                $Watch.Elapsed.TotalSeconds | Should -BeLessThan 20
                Test-Path -LiteralPath (Join-Path $Root 'never-created') | Should -BeFalse
            }
            finally { Remove-TestRoot $Root }
        }

        It 'exposes the documented parameters without running the script' {
            $Names = @((Get-Command $Script:MonitorScript).Parameters.Keys)

            foreach ($Expected in 'LogPath', 'StatePath', 'HeartbeatSeconds', 'RestartGapSeconds', 'NoDocker', 'NoForward',
                                  'EventServer', 'EventBatchSize', 'EventIntervalSeconds', 'OutboxPath', 'EventConfigPath', 'EventTokenPath') {
                $Names | Should -Contain $Expected
            }
        }
    }

    Context 'docker host with a stream of events, then SIGTERM' {

        BeforeAll {
            $script:Sb = New-IntegrationSandbox
            $Events = @(
                (New-DockerEventJson -Action 'create' -Name 'web')
                (New-DockerEventJson -Action 'start'  -Name 'web')
                (New-DockerEventJson -Action 'create' -Type 'network' -Name 'bridge2')
                (New-DockerEventJson -Action 'die'    -Name 'web' -ExitCode '137')
                (New-DockerEventJson -Action 'restart' -Name 'web')
                'garbage that is not json'
            )
            $EventsFile = Join-Path $script:Sb.Root 'events.jsonl'
            Set-Content -LiteralPath $EventsFile -Value $Events

            $script:SleepMarker = [string](Get-Random -Minimum 20000 -Maximum 29999)

            $script:Proc = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-HeartbeatSeconds', '1', '-NoForward') `
                -Environment @{ FAKE_DOCKER_EVENTS = $EventsFile; FAKE_DOCKER_SLEEP = $script:SleepMarker }

            [void](Wait-ForEvent -Handle $script:Proc -Name 'HEARTBEAT' -Count 4 -TimeoutSeconds 40)
            $script:ExitCode = Stop-MonitorProcess $script:Proc
            $script:Records  = @(Read-EventLogRecords $script:Sb.Params.LogPath)
            $script:Names    = @($script:Records | ForEach-Object Event)
        }

        AfterAll {
            if ($script:Proc -and -not $script:Proc.Process.HasExited) { $script:Proc.Process.Kill($true) }
            Remove-TestRoot $script:Sb.Root
        }

        It 'starts up in order: BOOT, SERVICE_START, DOCKER_BOOTED (daemon detected)' {
            $script:Names[0..2] | Should -Be @('BOOT', 'SERVICE_START', 'DOCKER_BOOTED')
        }

        It 'records the script version in SERVICE_START' {
            ($script:Records | Where-Object Event -eq 'SERVICE_START').Data['VERSION'] | Should -Match '^\d+\.\d+\.\d+$'
        }

        It 'maps container events, including start/restart that carry no exitCode (regression)' {
            $Mapped = @($script:Names | Where-Object { $_ -like 'DOCKER_*' -and $_ -ne 'DOCKER_BOOTED' } )
            $Mapped | Should -Be @('DOCKER_CREATED', 'DOCKER_CRASHED', 'DOCKER_RESTARTED')

            @($script:Records | Where-Object { $_.Event -eq 'DOCKER_BOOTED' -and $_.Data.ContainsKey('CONTAINER') }).Count | Should -Be 1
        }

        It 'ignores the network "create" event (regression)' {
            @($script:Records | Where-Object { $_.Data['CONTAINER'] -eq 'bridge2' }).Count | Should -Be 0
        }

        It 'reports an unparseable line as SERVICE_ERROR without dying' {
            @($script:Records | Where-Object { $_.Event -eq 'SERVICE_ERROR' -and $_.Data['COMPONENT'] -eq 'DockerEventParser' }).Count | Should -Be 1
        }

        It 'keeps emitting heartbeats while the Docker daemon is silent (regression: blocking read)' {
            @($script:Names | Where-Object { $_ -eq 'HEARTBEAT' }).Count | Should -BeGreaterOrEqual 4
        }

        It 'invokes docker with separate arguments' {
            (Get-Content -LiteralPath (Join-Path $script:Sb.Root 'docker-args.log') -Raw).Trim() | Should -Be 'events --format {{json .}}'
        }

        It 'logs SERVICE_STOP and exits 0 on SIGTERM (regression: finally never ran)' {
            $script:Names[-1] | Should -Be 'SERVICE_STOP'
            $script:ExitCode  | Should -Be 0
        }

        It 'leaves no docker collector process running' {
            Start-Sleep -Milliseconds 500
            $Orphans = & pgrep -f "sleep $($script:SleepMarker)" 2>$null
            @($Orphans | Where-Object { $_ }).Count | Should -Be 0
        }
    }

    Context 'restart persistence (state.json survives between runs)' {

        BeforeAll { $script:Sb = New-IntegrationSandbox }
        AfterAll  { Remove-TestRoot $script:Sb.Root }

        It 'first run logs BOOT; an immediate restart on the same boot logs neither BOOT nor REBOOT' {
            $First = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
            [void](Wait-ForEvent -Handle $First -Name 'HEARTBEAT' -Count 2)
            [void](Stop-MonitorProcess $First)
            @(Get-EventNames $script:Sb.Params.LogPath) | Should -Contain 'BOOT'

            Remove-Item -LiteralPath $script:Sb.Params.LogPath
            $Second = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
            [void](Wait-ForEvent -Handle $Second -Name 'HEARTBEAT' -Count 2)
            [void](Stop-MonitorProcess $Second)

            $Names = @(Get-EventNames $script:Sb.Params.LogPath)
            $Names | Should -Not -Contain 'BOOT'
            $Names | Should -Not -Contain 'REBOOT'
            $Names | Should -Not -Contain 'SERVICE_ERROR'
        }

        It 'a changed boot time in state.json is reported as BOOT + REBOOT' {
            $State = Get-Content -LiteralPath $script:Sb.Params.StatePath -Raw | ConvertFrom-Json
            $State.BootTime = '2001-01-01T00:00:00.0000000+00:00'
            $State | ConvertTo-Json | Set-Content -LiteralPath $script:Sb.Params.StatePath
            Remove-Item -LiteralPath $script:Sb.Params.LogPath

            $Third = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
            [void](Wait-ForEvent -Handle $Third -Name 'REBOOT')
            [void](Stop-MonitorProcess $Third)

            $Names = @(Get-EventNames $script:Sb.Params.LogPath)
            $Names[0..1] | Should -Be @('BOOT', 'REBOOT')
        }

        It 'a stale heartbeat is reported as START_AFTER_GAP' {
            $State = Get-Content -LiteralPath $script:Sb.Params.StatePath -Raw | ConvertFrom-Json
            $State.LastHeartbeat = [DateTimeOffset]::Now.AddHours(-2).ToString('o', [cultureinfo]::InvariantCulture)
            $State | ConvertTo-Json | Set-Content -LiteralPath $script:Sb.Params.StatePath
            Remove-Item -LiteralPath $script:Sb.Params.LogPath

            $Fourth = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
            [void](Wait-ForEvent -Handle $Fourth -Name 'START_AFTER_GAP')
            [void](Stop-MonitorProcess $Fourth)

            @(Get-EventNames $script:Sb.Params.LogPath) | Should -Contain 'START_AFTER_GAP'
        }

        It 'a corrupt state.json is treated as a first run, not a crash' {
            Set-Content -LiteralPath $script:Sb.Params.StatePath -Value '{ corrupt'
            Remove-Item -LiteralPath $script:Sb.Params.LogPath

            $Fifth = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
            [void](Wait-ForEvent -Handle $Fifth -Name 'HEARTBEAT')
            $Code = Stop-MonitorProcess $Fifth

            $Code | Should -Be 0
            @(Get-EventNames $script:Sb.Params.LogPath)[0] | Should -Be 'BOOT'
        }

        It 'works when the machine culture is German (regression: state read-back threw)' {
            $Sixth = Start-MonitorProcess -Sandbox $script:Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1') `
                -Environment @{ LC_ALL = 'de_DE.UTF-8'; LANG = 'de_DE.UTF-8'; DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = '0' }
            [void](Wait-ForEvent -Handle $Sixth -Name 'HEARTBEAT' -Count 2)
            [void](Stop-MonitorProcess $Sixth)

            $Names = @(Get-EventNames $script:Sb.Params.LogPath)
            $Names | Should -Not -Contain 'SERVICE_ERROR'
            $Names | Should -Not -Contain 'REBOOT'
        }
    }

    Context '-NoDocker' {

        It 'ignores an installed, working docker' {
            $Sb = New-IntegrationSandbox
            try {
                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-NoForward', '-HeartbeatSeconds', '1')
                [void](Wait-ForEvent -Handle $Proc -Name 'HEARTBEAT' -Count 2)
                [void](Stop-MonitorProcess $Proc)

                @(Get-EventNames $Sb.Params.LogPath | Where-Object { $_ -like 'DOCKER_*' }).Count | Should -Be 0
                Test-Path -LiteralPath (Join-Path $Sb.Root 'docker-args.log') | Should -BeFalse
            }
            finally { Remove-TestRoot $Sb.Root }
        }
    }

    Context 'the docker collector itself dies' {

        It 'reports DOCKER_MONITOR_FAILED with exit code and stderr, restarts, and keeps heartbeating' {
            $Sb = New-IntegrationSandbox
            try {
                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoForward', '-HeartbeatSeconds', '1') `
                    -Environment @{ FAKE_DOCKER_EVENTS_EXIT = '3' }

                (Wait-ForEvent -Handle $Proc -Name 'DOCKER_MONITOR_RESTARTED' -TimeoutSeconds 40) | Should -BeTrue
                [void](Stop-MonitorProcess $Proc)

                $Records = @(Read-EventLogRecords $Sb.Params.LogPath)
                $Failed = $Records | Where-Object Event -eq 'DOCKER_MONITOR_FAILED' | Select-Object -First 1
                $Failed.Data['EXIT_CODE'] | Should -Be '3'
                $Failed.Data['MESSAGE']   | Should -Match 'fake daemon error'
                @($Records | Where-Object Event -eq 'HEARTBEAT').Count | Should -BeGreaterThan 0
            }
            finally { Remove-TestRoot $Sb.Root }
        }
    }

    Context 'forwarding to a central server' {

        BeforeAll { $script:Srv = Start-StubEventServer }
        AfterAll  { Stop-StubEventServer $script:Srv }

        BeforeEach { $script:Srv.State.Mode = 'Accept'; $script:Srv.State.Requests.Clear() }

        It 'delivers local events to the server with the bearer token, and drains the outbox' {
            $Sb = New-IntegrationSandbox
            try {
                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-HeartbeatSeconds', '1', '-EventIntervalSeconds', '1') `
                    -Environment @{ GRONGO_EVENT_SERVER = $script:Srv.Url; GRONGO_EVENT_TOKEN = 'e2e-token' }

                (Wait-Until {
                    $All = @($script:Srv.State.Requests | ForEach-Object { ($_.Body | ConvertFrom-Json).events } | ForEach-Object EVENT)
                    ($All -contains 'SERVICE_START') -and ($All -contains 'HEARTBEAT')
                } -TimeoutSeconds 40) | Should -BeTrue

                [void](Stop-MonitorProcess $Proc)

                $script:Srv.State.Requests[0].Authorization | Should -Be 'Bearer e2e-token'
                $script:Srv.State.Requests[0].Path | Should -Be '/api/v1/events/batch'

                # Everything that reached the server is also in the local log (same events).
                $Sent = @($script:Srv.State.Requests | ForEach-Object { ($_.Body | ConvertFrom-Json).events } | ForEach-Object EVENT | Select-Object -Unique)
                $Local = @(Get-EventNames $Sb.Params.LogPath | Select-Object -Unique)
                foreach ($Name in $Sent) { $Local | Should -Contain $Name }

                (Get-Content -LiteralPath $Sb.Params.ForwarderLogPath -Raw) | Should -Match 'Batch delivered'
                (Get-Content -LiteralPath $Sb.Params.ForwarderLogPath -Raw) | Should -Not -Match 'e2e-token'
            }
            finally { Remove-TestRoot $Sb.Root }
        }

        It 'sends the originating machine timestamp offset unchanged on the wire' {
            $Sb = New-IntegrationSandbox
            try {
                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-HeartbeatSeconds', '1', '-EventIntervalSeconds', '1') `
                    -Environment @{ GRONGO_EVENT_SERVER = $script:Srv.Url; GRONGO_EVENT_TOKEN = 't'; TZ = 'Asia/Tokyo' }

                (Wait-Until { $script:Srv.State.Requests.Count -gt 0 } -TimeoutSeconds 40) | Should -BeTrue
                [void](Stop-MonitorProcess $Proc)

                $script:Srv.State.Requests[0].Body | Should -Match '"TIMESTAMP":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+09:00"'
            }
            finally { Remove-TestRoot $Sb.Root }
        }

        It 'local monitoring is unaffected while the server is down; events wait in the outbox' {
            $Sb = New-IntegrationSandbox
            try {
                $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
                $Probe.Start(); $Port = $Probe.LocalEndpoint.Port; $Probe.Stop()

                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-HeartbeatSeconds', '1', '-EventIntervalSeconds', '1') `
                    -Environment @{ GRONGO_EVENT_SERVER = "http://127.0.0.1:$Port"; GRONGO_EVENT_TOKEN = 't' }

                (Wait-ForEvent -Handle $Proc -Name 'HEARTBEAT' -Count 4 -TimeoutSeconds 40) | Should -BeTrue
                (Wait-Until { (Test-Path $Sb.Params.ForwarderLogPath) -and ((Get-Content $Sb.Params.ForwarderLogPath -Raw) -match 'Batch send failed') } -TimeoutSeconds 20) | Should -BeTrue
                $Code = Stop-MonitorProcess $Proc

                $Code | Should -Be 0
                @(Get-OutboxFiles $Sb.Params.OutboxPath).Count | Should -BeGreaterThan 0
                @(Get-EventNames $Sb.Params.LogPath) | Should -Not -Contain 'SERVICE_ERROR'
            }
            finally { Remove-TestRoot $Sb.Root }
        }

        It 'an invalid server URL fails closed: SERVICE_ERROR, local-only, empty outbox' {
            $Sb = New-IntegrationSandbox
            try {
                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-HeartbeatSeconds', '1') `
                    -Environment @{ GRONGO_EVENT_SERVER = 'events.example.com'; GRONGO_EVENT_TOKEN = 't' }

                [void](Wait-ForEvent -Handle $Proc -Name 'HEARTBEAT' -Count 2)
                [void](Stop-MonitorProcess $Proc)

                $Errors = @(Read-EventLogRecords $Sb.Params.LogPath | Where-Object Event -eq 'SERVICE_ERROR')
                $Errors.Count | Should -Be 1
                $Errors[0].Data['MESSAGE'] | Should -Match 'not an absolute http'
                @(Get-OutboxFiles $Sb.Params.OutboxPath).Count | Should -Be 0
            }
            finally { Remove-TestRoot $Sb.Root }
        }

        It 'a token file (not the command line) supplies the credential' {
            $Sb = New-IntegrationSandbox
            try {
                Set-Content -LiteralPath $Sb.Params.EventTokenPath -Value "file-token`n"

                $Proc = Start-MonitorProcess -Sandbox $Sb -ExtraArgs @('-NoDocker', '-HeartbeatSeconds', '1', '-EventIntervalSeconds', '1', '-EventServer', $script:Srv.Url)

                (Wait-Until { $script:Srv.State.Requests.Count -gt 0 } -TimeoutSeconds 40) | Should -BeTrue
                [void](Stop-MonitorProcess $Proc)

                $script:Srv.State.Requests[0].Authorization | Should -Be 'Bearer file-token'
            }
            finally { Remove-TestRoot $Sb.Root }
        }
    }
}
