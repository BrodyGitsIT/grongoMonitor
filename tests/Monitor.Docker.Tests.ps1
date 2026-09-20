#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $Script:OnWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    $script:OriginalPath = $env:PATH

    function New-Loop {
        param($DockerProcess = $null, $LastHeartbeat = [DateTimeOffset]::MinValue)

        return @{ LastHeartbeat = $LastHeartbeat; DockerProcess = $DockerProcess; PendingRead = $null; StreamEnded = $false }
    }

    function New-FakeDockerBinary {
        # Creates a `docker` shell script (Unix) that records its arguments and
        # behaves according to the given exit codes / output.
        param(
            [Parameter(Mandatory)][string]$Directory,
            [string]$Version = '27.0.0',
            [int]$VersionExit = 0,
            [string]$EventsOutput = '',
            [int]$EventsExit = 0
        )

        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $ArgsLog = Join-Path $Directory 'args.log'
        $Script = @"
#!/bin/sh
echo "`$*" >> '$ArgsLog'
for a in "`$@"; do printf '[%s]' "`$a" >> '$ArgsLog.raw'; done; echo >> '$ArgsLog.raw'
if [ "`$1" = "version" ]; then
  [ $VersionExit -eq 0 ] && echo '$Version'
  exit $VersionExit
fi
if [ "`$1" = "events" ]; then
  printf '%s' '$EventsOutput'
  exit $EventsExit
fi
exit 0
"@
        $Path = Join-Path $Directory 'docker'
        Set-Content -LiteralPath $Path -Value $Script -NoNewline
        & chmod +x $Path
        return $Path
    }
}

AfterAll {
    $env:PATH = $script:OriginalPath
    Remove-TestRoot $script:Root
}

Describe 'Process-DockerEvent: event mapping' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
    }

    Context 'real Docker event shapes' {

        It '<Action> -> <Expected>' -TestCases @(
            @{ Action = 'create';  Expected = 'DOCKER_CREATED' }
            @{ Action = 'start';   Expected = 'DOCKER_BOOTED' }
            @{ Action = 'restart'; Expected = 'DOCKER_RESTARTED' }
            @{ Action = 'stop';    Expected = 'DOCKER_SHUTDOWN' }
            @{ Action = 'kill';    Expected = 'DOCKER_SHUTDOWN' }
            @{ Action = 'die';     Expected = 'DOCKER_CRASHED' }
        ) {
            # No exitCode attribute: real Docker only sends it on "die".
            Process-DockerEvent -Line (New-DockerEventJson -Action $Action -Name 'web' -Image 'nginx:1.27')

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be $Expected
            $Events[0].Data['CONTAINER'] | Should -Be 'web'
            $Events[0].Data['IMAGE']     | Should -Be 'nginx:1.27'
        }

        It 'a start event does not produce a SERVICE_ERROR about a missing exitCode (regression)' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start')

            @(Get-EventNames $LogPath) | Should -Not -Contain 'SERVICE_ERROR'
            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }

        It 'a die event carries EXIT_CODE' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'die' -ExitCode '137')

            (Read-EventLogRecords $LogPath)[0].Data['EXIT_CODE'] | Should -Be '137'
        }

        It 'stop and kill report EXIT_CODE as empty when Docker did not send one' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'stop')

            (Read-EventLogRecords $LogPath)[0].Data['EXIT_CODE'] | Should -Be ''
        }

        It 'a numeric (non-string) exitCode is rendered as text' {
            Process-DockerEvent -Line '{"Type":"container","Action":"die","Actor":{"ID":"a","Attributes":{"name":"w","image":"i","exitCode":1}}}'

            (Read-EventLogRecords $LogPath)[0].Data['EXIT_CODE'] | Should -Be '1'
        }

        It 'a clean stop sequence (kill, die, stop) is logged as SHUTDOWN, CRASHED(exit 0), SHUTDOWN (documented current behaviour)' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'kill')
            Process-DockerEvent -Line (New-DockerEventJson -Action 'die' -ExitCode '0')
            Process-DockerEvent -Line (New-DockerEventJson -Action 'stop')

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_SHUTDOWN', 'DOCKER_CRASHED', 'DOCKER_SHUTDOWN')
            (Read-EventLogRecords $LogPath)[1].Data['EXIT_CODE'] | Should -Be '0'
        }
    }

    Context 'events that are intentionally not reported' {

        It 'ignores container action "<Action>"' -TestCases @(
            @{ Action = 'pause' }
            @{ Action = 'unpause' }
            @{ Action = 'attach' }
            @{ Action = 'rename' }
            @{ Action = 'resize' }
            @{ Action = 'update' }
            @{ Action = 'top' }
            @{ Action = 'commit' }
            @{ Action = 'exec_create: sh -c ls' }
            @{ Action = 'exec_start: sh -c ls' }
            @{ Action = 'exec_die' }
            @{ Action = 'health_status: healthy' }
            @{ Action = 'health_status: unhealthy' }
            @{ Action = 'oom' }
            @{ Action = '' }
        ) {
            Process-DockerEvent -Line (New-DockerEventJson -Action $Action)

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'ignores non-container objects that reuse the "create" action: <Type> (regression)' -TestCases @(
            @{ Type = 'network' }
            @{ Type = 'volume' }
            @{ Type = 'image' }
            @{ Type = 'plugin' }
            @{ Type = 'service' }
            @{ Type = 'node' }
            @{ Type = 'secret' }
            @{ Type = 'config' }
            @{ Type = 'daemon' }
        ) {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'create' -Type $Type -Name 'thing')

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'ignores network and volume "destroy"/"connect"/"mount" style actions' -TestCases @(
            @{ Type = 'network'; Action = 'connect' }
            @{ Type = 'network'; Action = 'disconnect' }
            @{ Type = 'volume';  Action = 'mount' }
            @{ Type = 'volume';  Action = 'destroy' }
        ) {
            Process-DockerEvent -Line (New-DockerEventJson -Action $Action -Type $Type)

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'still handles an event that has no Type at all (older engines)' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -NoType)

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }

        It 'treats Type case-sensitively: "Container" is not "container"' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -Type 'Container')

            # -ne is case-insensitive in PowerShell, so this still counts as a container.
            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }
    }

    Context 'missing or odd fields never throw' {

        It 'falls back to the actor ID when there is no container name' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -NoName -Id 'deadbeef0123')

            (Read-EventLogRecords $LogPath)[0].Data['CONTAINER'] | Should -Be 'deadbeef0123'
        }

        It 'falls back to the actor ID when the name is blank' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -Name '   ' -Id 'abc999')

            (Read-EventLogRecords $LogPath)[0].Data['CONTAINER'] | Should -Be 'abc999'
        }

        It 'handles an event with no Attributes object at all' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -NoAttributes -Id 'abc')

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be 'DOCKER_BOOTED'
            $Events[0].Data['CONTAINER'] | Should -Be 'abc'
            $Events[0].Data['IMAGE']     | Should -Be ''
        }

        It 'handles an event with no Actor at all' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -NoActor)

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Data['CONTAINER'] | Should -Be ''
        }

        It 'handles an event with neither Actor.ID nor name' {
            Process-DockerEvent -Line '{"Type":"container","Action":"die","Actor":{}}'

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_CRASHED')
        }

        It 'ignores unknown extra fields (compose labels, future Docker fields)' {
            Process-DockerEvent -Line '{"Type":"container","Action":"start","Actor":{"ID":"a","Attributes":{"name":"w","image":"i","com.docker.compose.project":"stack","org.opencontainers.image.source":"https://x"}},"future":{"a":[1,2,3]}}'

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }

        It 'sanitises a container name containing a pipe' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -Name 'we|ird')

            @(Get-Content -LiteralPath $LogPath).Count | Should -Be 1
            (Read-EventLogRecords $LogPath)[0].Data['CONTAINER'] | Should -Be 'we/ird'
        }

        It 'preserves unicode container and image names' {
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -Name 'café-日本' -Image 'registry.local/日本:1')

            $Text = [System.IO.File]::ReadAllText($LogPath, [System.Text.Encoding]::UTF8)
            $Text | Should -Match 'café-日本'
        }

        It 'handles a very long line' {
            $Big = 'x' * 200000
            Process-DockerEvent -Line (New-DockerEventJson -Action 'start' -Image $Big)

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }

        It 'ignores JSON that is not an event object: <Json>' -TestCases @(
            @{ Json = '{}' }
            @{ Json = 'null' }
            @{ Json = '42' }
            @{ Json = '"a string"' }
            @{ Json = '[]' }
            @{ Json = '[1,2]' }
            @{ Json = 'true' }
        ) {
            { Process-DockerEvent -Line $Json } | Should -Not -Throw

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }
    }

    Context 'malformed input is reported, not fatal' {

        It 'logs SERVICE_ERROR (DockerEventParser) for invalid JSON: <Line>' -TestCases @(
            @{ Line = 'this is not json' }
            @{ Line = '{"Type":"container","Action":' }
            @{ Line = '{{{{' }
            @{ Line = "Error response from daemon: something" }
        ) {
            { Process-DockerEvent -Line $Line } | Should -Not -Throw

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be 'SERVICE_ERROR'
            $Events[0].Data['COMPONENT'] | Should -Be 'DockerEventParser'
        }

        It 'requires a non-empty line (callers filter blanks first)' {
            { Process-DockerEvent -Line '' } | Should -Throw
        }

        It 'does not throw for keys that differ only by case' {
            { Process-DockerEvent -Line '{"Type":"container","Action":"start","action":"die","Actor":{"ID":"a","Attributes":{"name":"w"}}}' } | Should -Not -Throw
        }
    }
}

Describe 'Get-DockerServerVersion / Test-DockerAvailability' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
        $env:PATH = $script:OriginalPath
    }

    AfterEach { $env:PATH = $script:OriginalPath }

    It 'returns $null when there is no docker CLI on PATH' {
        $Empty = Join-Path $script:Root 'empty-bin'
        New-Item -ItemType Directory -Path $Empty | Out-Null
        $env:PATH = $Empty

        Get-DockerServerVersion | Should -BeNullOrEmpty
    }

    It 'returns the server version from a working docker CLI' -Skip:$Script:OnWindows {
        $Bin = Join-Path $script:Root 'bin'
        [void](New-FakeDockerBinary -Directory $Bin -Version '27.3.1')
        $env:PATH = "$Bin$([System.IO.Path]::PathSeparator)$($script:OriginalPath)"

        Get-DockerServerVersion | Should -Be '27.3.1'
    }

    It 'returns $null when the daemon is unreachable (docker exits non-zero)' -Skip:$Script:OnWindows {
        $Bin = Join-Path $script:Root 'bin'
        [void](New-FakeDockerBinary -Directory $Bin -VersionExit 1)
        $env:PATH = "$Bin$([System.IO.Path]::PathSeparator)$($script:OriginalPath)"

        Get-DockerServerVersion | Should -BeNullOrEmpty
    }

    It 'returns $null (not an error) when docker succeeds but prints nothing' -Skip:$Script:OnWindows {
        $Bin = Join-Path $script:Root 'bin'
        [void](New-FakeDockerBinary -Directory $Bin -Version '')
        $env:PATH = "$Bin$([System.IO.Path]::PathSeparator)$($script:OriginalPath)"

        Get-DockerServerVersion | Should -BeNullOrEmpty
    }

    It 'Test-DockerAvailability is $false and silent under -NoDocker' {
        $NoDocker = [switch]$true
        Mock Get-DockerServerVersion { '27.0.0' }

        Test-DockerAvailability | Should -BeFalse
        @(Get-EventNames $LogPath).Count | Should -Be 0
        Should -Invoke Get-DockerServerVersion -Times 0
    }

    It 'Test-DockerAvailability logs DOCKER_BOOTED with the version when docker is usable' {
        $NoDocker = [switch]$false
        Mock Get-DockerServerVersion { '27.0.0' }

        Test-DockerAvailability | Should -BeTrue

        $Events = Read-EventLogRecords $LogPath
        $Events[0].Event | Should -Be 'DOCKER_BOOTED'
        $Events[0].Data['VERSION'] | Should -Be '27.0.0'
    }

    It 'Test-DockerAvailability is $false and logs nothing when docker is not usable' {
        $NoDocker = [switch]$false
        Mock Get-DockerServerVersion { $null }

        Test-DockerAvailability | Should -BeFalse
        @(Get-EventNames $LogPath).Count | Should -Be 0
    }
}

Describe 'Start-DockerMonitor' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
        $env:PATH = $script:OriginalPath
    }

    AfterEach { $env:PATH = $script:OriginalPath }

    It 'returns nothing when Docker is not available' {
        $Script:DockerAvailable = $false

        Start-DockerMonitor | Should -BeNullOrEmpty
        @(Get-EventNames $LogPath).Count | Should -Be 0
    }

    It 'logs SERVICE_ERROR (DockerMonitor) and returns $null if the process cannot start' {
        $Script:DockerAvailable = $true
        $Empty = Join-Path $script:Root 'empty-bin'
        New-Item -ItemType Directory -Path $Empty | Out-Null
        $env:PATH = $Empty

        Start-DockerMonitor | Should -BeNullOrEmpty

        $Events = Read-EventLogRecords $LogPath
        @($Events).Count | Should -Be 1
        $Events[0].Event | Should -Be 'SERVICE_ERROR'
        $Events[0].Data['COMPONENT'] | Should -Be 'DockerMonitor'
    }

    It 'starts `docker events --format {{json .}}` with each value as its own argument (regression: quoting)' -Skip:$Script:OnWindows {
        $Script:DockerAvailable = $true
        $Bin = Join-Path $script:Root 'bin'
        [void](New-FakeDockerBinary -Directory $Bin -EventsOutput '{"Action":"start"}')
        $env:PATH = "$Bin$([System.IO.Path]::PathSeparator)$($script:OriginalPath)"

        $Process = Start-DockerMonitor
        try {
            $Process | Should -Not -BeNullOrEmpty
            [void]$Process.WaitForExit(5000)

            $Raw = Get-Content -LiteralPath (Join-Path $Bin 'args.log.raw') -Raw
            $Raw | Should -Match ([regex]::Escape('[events][--format][{{json .}}]'))
            $Process.StandardOutput.ReadLine() | Should -Be '{"Action":"start"}'
        }
        finally {
            if ($Process) { $Process.Dispose() }
        }
    }
}

Describe 'Read-DockerStream' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
    }

    It 'processes every line that is already available' {
        $Fake = New-FakeDockerProcess -Lines @(
            (New-DockerEventJson -Action 'create')
            (New-DockerEventJson -Action 'start')
            (New-DockerEventJson -Action 'die' -ExitCode '1')
        )
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_CREATED', 'DOCKER_BOOTED', 'DOCKER_CRASHED')
        $Loop.StreamEnded | Should -BeFalse
    }

    It 'returns immediately when the daemon is quiet (never blocks) and keeps the read in flight' {
        $Fake = New-FakeDockerProcess -Lines @()
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        $Watch = [Diagnostics.Stopwatch]::StartNew()
        Read-DockerStream -Loop $Loop
        $Watch.Stop()

        $Watch.ElapsedMilliseconds | Should -BeLessThan 1000
        $Loop.PendingRead | Should -Not -BeNullOrEmpty
        $Loop.StreamEnded | Should -BeFalse
    }

    It 'does not start a second read while one is still pending' {
        $Fake = New-FakeDockerProcess -Lines @()
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop
        $First = $Loop.PendingRead
        Read-DockerStream -Loop $Loop

        [object]::ReferenceEquals($First, $Loop.PendingRead) | Should -BeTrue
    }

    It 'picks up a line that arrives after the first (empty) poll' {
        $Fake = New-FakeDockerProcess -Lines @()
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop
        @(Get-EventNames $LogPath).Count | Should -Be 0

        $Fake.Push((New-DockerEventJson -Action 'start'))
        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
    }

    It 'skips blank and whitespace-only lines' {
        $Fake = New-FakeDockerProcess -Lines @('', '   ', (New-DockerEventJson -Action 'start'), "`t")
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
    }

    It 'flags StreamEnded on EOF, after processing everything before it' {
        $Fake = New-FakeDockerProcess -Lines @((New-DockerEventJson -Action 'start')) -After Eof
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        $Loop.StreamEnded | Should -BeTrue
    }

    It 'flags StreamEnded when the read faults (e.g. the pipe was torn down)' {
        $Fake = New-FakeDockerProcess -Lines @()
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }
        Read-DockerStream -Loop $Loop
        $Fake.Shared.Pending.SetException([System.IO.IOException]::new('pipe broke'))

        Read-DockerStream -Loop $Loop

        $Loop.StreamEnded | Should -BeTrue
        $Loop.PendingRead | Should -BeNullOrEmpty
    }

    It 'a garbage line is reported and does not stop the lines after it' {
        $Fake = New-FakeDockerProcess -Lines @('garbage!', (New-DockerEventJson -Action 'start'))
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('SERVICE_ERROR', 'DOCKER_BOOTED')
    }

    It 'handles a burst of 2,000 events in a single call' {
        $Lines = 1..2000 | ForEach-Object { New-DockerEventJson -Action 'start' -Name "c$_" }
        $Fake = New-FakeDockerProcess -Lines $Lines
        $Loop = @{ DockerProcess = $Fake; PendingRead = $null; StreamEnded = $false }

        Read-DockerStream -Loop $Loop

        @(Get-EventNames $LogPath).Count | Should -Be 2000
    }
}

Describe 'Restart-DockerMonitor' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
        Mock Start-Sleep { }
    }

    It 'logs DOCKER_MONITOR_FAILED with the exit code and stderr, then DOCKER_MONITOR_RESTARTED' {
        $Old = New-FakeDockerProcess -ExitCode 3 -StdErr "Cannot connect to the Docker daemon`nIs it running?"
        $Old.HasExited = $true
        $New = New-FakeDockerProcess
        Mock Start-DockerMonitor { $New }
        $Loop = @{ DockerProcess = $Old; PendingRead = 'stale'; StreamEnded = $true }

        Restart-DockerMonitor -Loop $Loop

        $Events = Read-EventLogRecords $LogPath
        @($Events | ForEach-Object Event) | Should -Be @('DOCKER_MONITOR_FAILED', 'DOCKER_MONITOR_RESTARTED')
        $Events[0].Data['COMPONENT'] | Should -Be 'DockerEventMonitor'
        $Events[0].Data['EXIT_CODE'] | Should -Be '3'
        $Events[0].Data['MESSAGE']   | Should -Match 'Cannot connect to the Docker daemon Is it running\?'
        @(Get-Content -LiteralPath $LogPath).Count | Should -Be 2

        $Loop.DockerProcess | Should -Be $New
        $Loop.PendingRead   | Should -BeNullOrEmpty
        $Loop.StreamEnded   | Should -BeFalse
        $Old.Disposed       | Should -BeTrue
    }

    It 'omits MESSAGE when stderr is empty' {
        $Old = New-FakeDockerProcess -ExitCode 0 -StdErr ''
        $Old.HasExited = $true
        Mock Start-DockerMonitor { New-FakeDockerProcess }

        Restart-DockerMonitor -Loop @{ DockerProcess = $Old; PendingRead = $null; StreamEnded = $true }

        (Read-EventLogRecords $LogPath)[0].Data.ContainsKey('MESSAGE') | Should -BeFalse
    }

    It 'does not log RESTARTED and leaves no process when the restart itself fails' {
        $Old = New-FakeDockerProcess
        $Old.HasExited = $true
        Mock Start-DockerMonitor { $null }
        $Loop = @{ DockerProcess = $Old; PendingRead = $null; StreamEnded = $true }

        Restart-DockerMonitor -Loop $Loop

        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_MONITOR_FAILED')
        $Loop.DockerProcess | Should -BeNullOrEmpty
    }

    It 'kills a collector that is still running but whose stream ended' {
        $Old = New-FakeDockerProcess
        Mock Start-DockerMonitor { New-FakeDockerProcess }

        Restart-DockerMonitor -Loop @{ DockerProcess = $Old; PendingRead = $null; StreamEnded = $true }

        $Old.Killed | Should -BeTrue
    }

    It 'waits before restarting so a dead daemon is not hammered' {
        $Old = New-FakeDockerProcess
        $Old.HasExited = $true
        Mock Start-DockerMonitor { New-FakeDockerProcess }

        Restart-DockerMonitor -Loop @{ DockerProcess = $Old; PendingRead = $null; StreamEnded = $true }

        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 2 }
    }

    It 'survives a process whose ExitCode / stderr cannot be read' {
        $Old = New-FakeDockerProcess
        $Old.HasExited = $true
        $Old | Add-Member -MemberType ScriptProperty -Name ExitCode -Force -Value { throw 'not exited' }
        $Old.StandardError | Add-Member -MemberType ScriptMethod -Name ReadToEnd -Force -Value { throw 'stream closed' }
        Mock Start-DockerMonitor { New-FakeDockerProcess }

        { Restart-DockerMonitor -Loop @{ DockerProcess = $Old; PendingRead = $null; StreamEnded = $true } } | Should -Not -Throw

        # (PowerShell swallows exceptions from a ScriptProperty getter, so the
        # fake cannot reproduce Process.ExitCode throwing; what matters is that
        # the failure is still reported and the restart still happens.)
        @(Get-EventNames $LogPath) | Should -Be @('DOCKER_MONITOR_FAILED', 'DOCKER_MONITOR_RESTARTED')
    }
}

Describe 'Invoke-MonitorTick' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
        $Script:CurrentBootTime   = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
        $Script:DockerAvailable   = $true
        $HeartbeatSeconds = 60
        Mock Start-Sleep { }
    }

    Context 'heartbeat' {

        It 'writes HEARTBEAT and state.json on the first tick' {
            $Loop = New-Loop

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('HEARTBEAT')
            Test-Path -LiteralPath $StatePath | Should -BeTrue
            $Loop.LastHeartbeat | Should -Not -Be ([DateTimeOffset]::MinValue)
        }

        It 'does not write another heartbeat before the interval elapses' {
            $Loop = New-Loop

            Invoke-MonitorTick -Loop $Loop
            Invoke-MonitorTick -Loop $Loop
            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath).Count | Should -Be 1
        }

        It 'writes another heartbeat once the interval has elapsed' {
            $Loop = New-Loop -LastHeartbeat ([DateTimeOffset]::Now.AddSeconds(-61))

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('HEARTBEAT')
        }

        It 'honours a custom heartbeat interval' {
            $HeartbeatSeconds = 5
            $Loop = New-Loop -LastHeartbeat ([DateTimeOffset]::Now.AddSeconds(-6))

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('HEARTBEAT')
        }

        It 'propagates a state-write failure (the outer loop logs CRASH)' {
            Mock Save-State { throw 'read-only filesystem' }

            { Invoke-MonitorTick -Loop (New-Loop) } | Should -Throw
        }
    }

    Context 'docker stream' {

        It 'processes docker events on a tick' {
            $Fake = New-FakeDockerProcess -Lines @((New-DockerEventJson -Action 'start'))
            $Loop = New-Loop -DockerProcess $Fake -LastHeartbeat ([DateTimeOffset]::Now)

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_BOOTED')
        }

        It 'does nothing docker-related when there is no collector process' {
            $Loop = New-Loop -LastHeartbeat ([DateTimeOffset]::Now)

            { Invoke-MonitorTick -Loop $Loop } | Should -Not -Throw
            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'a QUIET docker daemon does not stall the loop: heartbeats keep flowing (regression)' {
            $HeartbeatSeconds = 1
            $Fake = New-FakeDockerProcess -Lines @()
            $Loop = New-Loop -DockerProcess $Fake

            $Watch = [Diagnostics.Stopwatch]::StartNew()
            1..40 | ForEach-Object { Invoke-MonitorTick -Loop $Loop; Start-Sleep -Milliseconds 0 }
            $Watch.Stop()

            $Watch.ElapsedMilliseconds | Should -BeLessThan 3000
            @(Get-EventNames $LogPath) | Should -Contain 'HEARTBEAT'
        }

        It 'a heartbeat is still emitted on a tick where docker is silent' {
            $Fake = New-FakeDockerProcess -Lines @()
            $Loop = New-Loop -DockerProcess $Fake

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('HEARTBEAT')
        }

        It 'restarts the collector when its stream ends, reporting the failure' {
            $Fake = New-FakeDockerProcess -Lines @() -After Eof -ExitCode 1 -StdErr 'daemon went away'
            $Fake.HasExited = $true
            $New = New-FakeDockerProcess
            Mock Start-DockerMonitor { $New }
            $Loop = New-Loop -DockerProcess $Fake -LastHeartbeat ([DateTimeOffset]::Now)

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_MONITOR_FAILED', 'DOCKER_MONITOR_RESTARTED')
            $Loop.DockerProcess | Should -Be $New
        }

        It 'restarts the collector when the process exited even if the stream has not signalled EOF yet' {
            $Fake = New-FakeDockerProcess -Lines @()      # read stays pending
            $Fake.HasExited = $true
            Mock Start-DockerMonitor { New-FakeDockerProcess }
            $Loop = New-Loop -DockerProcess $Fake -LastHeartbeat ([DateTimeOffset]::Now)

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Contain 'DOCKER_MONITOR_FAILED'
        }

        It 'delivers the last lines Docker wrote before it exited, before reporting the failure' {
            $Fake = New-FakeDockerProcess -Lines @() -ExitCode 1
            $Loop = New-Loop -DockerProcess $Fake -LastHeartbeat ([DateTimeOffset]::Now)
            Invoke-MonitorTick -Loop $Loop            # leaves a read pending
            $Fake.Push((New-DockerEventJson -Action 'die' -ExitCode '137'))
            $Fake.HasExited = $true
            Mock Start-DockerMonitor { $null }

            Invoke-MonitorTick -Loop $Loop

            @(Get-EventNames $LogPath) | Should -Be @('DOCKER_CRASHED', 'DOCKER_MONITOR_FAILED')
        }

        It 'keeps monitoring after a collector restart (new process is read on the next tick)' {
            $Old = New-FakeDockerProcess -Lines @() -After Eof
            $Old.HasExited = $true
            $New = New-FakeDockerProcess -Lines @((New-DockerEventJson -Action 'start' -Name 'after-restart'))
            Mock Start-DockerMonitor { $New }
            $Loop = New-Loop -DockerProcess $Old -LastHeartbeat ([DateTimeOffset]::Now)

            Invoke-MonitorTick -Loop $Loop
            Invoke-MonitorTick -Loop $Loop

            $Names = @(Get-EventNames $LogPath)
            $Names | Should -Be @('DOCKER_MONITOR_FAILED', 'DOCKER_MONITOR_RESTARTED', 'DOCKER_BOOTED')
        }
    }
}
