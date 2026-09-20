#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    function Set-StopAfterTicks {
        # Makes Test-StopRequested return $false N times, then $true.
        param([int]$Ticks)

        $script:StopCalls = 0
        $script:StopAt    = $Ticks
        Mock Test-StopRequested { $script:StopCalls++; return ($script:StopCalls -gt $script:StopAt) }
    }
}

AfterAll {
    Remove-TestRoot $script:Root
}

Describe 'Test-StopRequested / Register-StopSignalHandler' {

    It 'Test-StopRequested is $false when nobody has asked the monitor to stop' {
        Test-StopRequested | Should -BeFalse
    }

    It 'Register-StopSignalHandler never throws and returns a boolean' {
        { Register-StopSignalHandler } | Should -Not -Throw
        (Register-StopSignalHandler) | Should -BeOfType [bool]
    }

    It 'registration is idempotent' {
        [void](Register-StopSignalHandler)
        { Register-StopSignalHandler } | Should -Not -Throw
    }
}

Describe 'Invoke-GrongoMonitor' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled     = $false
        $Script:ForwarderConfig       = $null
        $Script:SuppressOutboxOnError = $false
        $NoForward = [switch]$false
        $NoDocker  = [switch]$true
        $HeartbeatSeconds = 60

        Mock Start-Sleep { }
        Mock Register-StopSignalHandler { $true }
        Mock Get-SystemBootTime { [DateTimeOffset]::FromUnixTimeSeconds(1700000000) }
        Mock Start-DockerMonitor { $null }
    }

    It 'logs BOOT, SERVICE_START, HEARTBEAT, SERVICE_STOP in order on a clean first run' {
        Set-StopAfterTicks 2

        Invoke-GrongoMonitor

        @(Get-EventNames $LogPath) | Should -Be @('BOOT', 'SERVICE_START', 'HEARTBEAT', 'SERVICE_STOP')
    }

    It 'creates its directories and writes state.json' {
        $LogPath   = Join-Path $script:Root 'fresh/logs/events.log'
        $StatePath = Join-Path $script:Root 'fresh/state/state.json'
        Set-StopAfterTicks 1

        Invoke-GrongoMonitor

        Test-Path -LiteralPath $LogPath   | Should -BeTrue
        Test-Path -LiteralPath $StatePath | Should -BeTrue
    }

    It 'runs the loop until a stop is requested, one tick per iteration' {
        Set-StopAfterTicks 5
        Mock Invoke-MonitorTick { }

        Invoke-GrongoMonitor

        Should -Invoke Invoke-MonitorTick -Times 5 -Exactly
    }

    It 'exits without ticking at all if stop was already requested' {
        Set-StopAfterTicks 0
        Mock Invoke-MonitorTick { }

        Invoke-GrongoMonitor

        Should -Invoke Invoke-MonitorTick -Times 0 -Exactly
        @(Get-EventNames $LogPath) | Should -Contain 'SERVICE_STOP'
    }

    It 'a second run on the same boot logs no BOOT/REBOOT' {
        Set-StopAfterTicks 1
        Invoke-GrongoMonitor
        Remove-Item -LiteralPath $LogPath

        Set-StopAfterTicks 1
        Invoke-GrongoMonitor

        @(Get-EventNames $LogPath) | Should -Be @('SERVICE_START', 'HEARTBEAT', 'SERVICE_STOP')
    }

    It 'a second run after the boot time changed logs BOOT and REBOOT' {
        Set-StopAfterTicks 1
        Invoke-GrongoMonitor
        Remove-Item -LiteralPath $LogPath

        Mock Get-SystemBootTime { [DateTimeOffset]::FromUnixTimeSeconds(1700100000) }
        Set-StopAfterTicks 1
        Invoke-GrongoMonitor

        @(Get-EventNames $LogPath)[0..1] | Should -Be @('BOOT', 'REBOOT')
    }

    It 'a tick that throws logs SERVICE_ERROR then CRASH, rethrows, and still logs SERVICE_STOP' {
        Set-StopAfterTicks 3
        Mock Invoke-MonitorTick { throw [System.InvalidOperationException]::new('kaboom') }

        { Invoke-GrongoMonitor } | Should -Throw '*kaboom*'

        $Events = Read-EventLogRecords $LogPath
        $Names  = @($Events | ForEach-Object Event)
        $Names[-3..-1] | Should -Be @('SERVICE_ERROR', 'CRASH', 'SERVICE_STOP')

        $Error1 = $Events | Where-Object Event -eq 'SERVICE_ERROR' | Select-Object -Last 1
        $Error1.Data['MESSAGE'] | Should -Be 'kaboom'
        $Error1.Data['TYPE']    | Should -Be 'System.InvalidOperationException'
    }

    It 'shuts down the docker collector on exit (kill + dispose)' {
        $Fake = New-FakeDockerProcess
        $Script:DockerAvailable = $true
        Mock Test-DockerAvailability { $true }
        Mock Start-DockerMonitor { $Fake }
        Mock Invoke-MonitorTick { }
        Set-StopAfterTicks 1

        Invoke-GrongoMonitor

        $Fake.Killed   | Should -BeTrue
        $Fake.Disposed | Should -BeTrue
    }

    It 'does not try to kill a collector that already exited' {
        $Fake = New-FakeDockerProcess
        $Fake.HasExited = $true
        Mock Test-DockerAvailability { $true }
        Mock Start-DockerMonitor { $Fake }
        Mock Invoke-MonitorTick { }
        Set-StopAfterTicks 1

        Invoke-GrongoMonitor

        $Fake.Killed   | Should -BeFalse
        $Fake.Disposed | Should -BeTrue
    }

    It 'still logs SERVICE_STOP if docker teardown throws' {
        $Fake = New-FakeDockerProcess
        $Fake | Add-Member -MemberType ScriptMethod -Name Dispose -Force -Value { throw 'already disposed' }
        Mock Test-DockerAvailability { $true }
        Mock Start-DockerMonitor { $Fake }
        Mock Invoke-MonitorTick { }
        Set-StopAfterTicks 1

        { Invoke-GrongoMonitor } | Should -Not -Throw
        @(Get-EventNames $LogPath) | Should -Contain 'SERVICE_STOP'
    }

    It 'still exits cleanly if the final SERVICE_STOP cannot be written' {
        Set-StopAfterTicks 1
        Mock Invoke-MonitorTick { }
        $script:WriteCalls = 0
        Mock Write-EventLog {
            $script:WriteCalls++
            if ($Event -eq 'SERVICE_STOP') { throw 'log unavailable at shutdown' }
        }

        { Invoke-GrongoMonitor } | Should -Not -Throw
    }

    Context 'forwarder lifecycle' {

        BeforeEach {
            $env:GRONGO_EVENT_SERVER = 'https://events.example.test'
            $env:GRONGO_EVENT_TOKEN  = 'tok'
            Mock Start-EventForwarder { }
            Mock Stop-EventForwarder { }
            Mock Invoke-MonitorTick { }
        }

        AfterEach {
            $env:GRONGO_EVENT_SERVER = $null
            $env:GRONGO_EVENT_TOKEN  = $null
        }

        It 'starts the forwarder when a server is configured and stops it on exit' {
            Set-StopAfterTicks 1

            Invoke-GrongoMonitor

            Should -Invoke Start-EventForwarder -Times 1 -Exactly
            Should -Invoke Stop-EventForwarder  -Times 1 -Exactly
        }

        It 'does not start the forwarder without a server' {
            $env:GRONGO_EVENT_SERVER = $null
            Set-StopAfterTicks 1

            Invoke-GrongoMonitor

            Should -Invoke Start-EventForwarder -Times 0 -Exactly
            Should -Invoke Stop-EventForwarder  -Times 0 -Exactly
        }

        It '-NoForward prevents the forwarder from starting' {
            $NoForward = [switch]$true
            Set-StopAfterTicks 1

            Invoke-GrongoMonitor

            Should -Invoke Start-EventForwarder -Times 0 -Exactly
        }

        It 'queues startup events (BOOT, SERVICE_START) into the outbox when forwarding is on' {
            Set-StopAfterTicks 1

            Invoke-GrongoMonitor

            $Names = @(Get-OutboxFiles $OutboxPath | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).EVENT })
            $Names | Should -Contain 'BOOT'
            $Names | Should -Contain 'SERVICE_START'
            $Names | Should -Contain 'SERVICE_STOP'
        }

        It 'keeps monitoring locally if the forwarder fails to start' {
            Mock Start-EventForwarder { throw 'runspace exploded' }
            Set-StopAfterTicks 2

            { Invoke-GrongoMonitor } | Should -Not -Throw

            $Events = Read-EventLogRecords $LogPath
            ($Events | Where-Object { $_.Event -eq 'SERVICE_ERROR' -and $_.Data['MESSAGE'] -match 'Failed to start forwarder' }) | Should -Not -BeNullOrEmpty
            @($Events | ForEach-Object Event) | Should -Contain 'SERVICE_STOP'
            Should -Invoke Stop-EventForwarder -Times 0 -Exactly
        }

        It 'stops the forwarder even when the loop crashes' {
            Mock Invoke-MonitorTick { throw 'boom' }
            Set-StopAfterTicks 1

            { Invoke-GrongoMonitor } | Should -Throw

            Should -Invoke Stop-EventForwarder -Times 1 -Exactly
        }
    }
}
