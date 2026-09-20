#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $Script:HasDe = Test-CultureAvailable 'de-DE'
    $Script:HasGb = Test-CultureAvailable 'en-GB'
    $Script:OnLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    function Write-TestState {
        # Writes a state.json the way Save-State would, but with a chosen
        # heartbeat age and boot time.
        param(
            [double]$HeartbeatAgeSeconds = 10,
            $BootTime = $null,
            [switch]$OmitBootTime
        )

        $State = [ordered]@{
            LastHeartbeat = [DateTimeOffset]::Now.AddSeconds(-$HeartbeatAgeSeconds).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }

        if (-not $OmitBootTime) {
            $State['BootTime'] = if ($null -ne $BootTime) { ([DateTimeOffset]$BootTime).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
        }

        $State['Hostname'] = 'h'
        $State['Docker']   = $false

        $State | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
    }
}

AfterAll {
    Remove-TestRoot $script:Root
}

Describe 'ConvertFrom-SysctlBootTime' {

    It 'parses the macOS kern.boottime format' {
        $Result = ConvertFrom-SysctlBootTime -Text '{ sec = 1700000000, usec = 123456 } Tue Nov 14 22:13:20 2023'
        $Result.ToUnixTimeSeconds() | Should -Be 1700000000
    }

    It 'tolerates different spacing' {
        (ConvertFrom-SysctlBootTime -Text '{sec=1700000000,usec=1}').ToUnixTimeSeconds() | Should -Be 1700000000
    }

    It 'returns $null for <Case>' -TestCases @(
        @{ Case = 'empty text';  Text = '' }
        @{ Case = 'whitespace';  Text = '   ' }
        @{ Case = 'garbage';     Text = 'sysctl: unknown oid' }
        @{ Case = 'no digits';   Text = '{ sec = , usec = }' }
    ) {
        ConvertFrom-SysctlBootTime -Text $Text | Should -BeNullOrEmpty
    }
}

Describe 'Get-BootTimeLinux' {

    It 'parses btime from /proc/stat' {
        Mock Get-Content { @('cpu  1 2 3', 'btime 1700000000', 'processes 99') } -ParameterFilter { $Path -eq '/proc/stat' -or "$args" -match 'proc/stat' }

        (Get-BootTimeLinux).ToUnixTimeSeconds() | Should -Be 1700000000
    }

    It 'returns $null when there is no btime line' {
        Mock Get-Content { @('cpu  1 2 3', 'processes 99') }

        Get-BootTimeLinux | Should -BeNullOrEmpty
    }

    It 'returns $null when btime is not a number' {
        Mock Get-Content { @('btime soon') }

        Get-BootTimeLinux | Should -BeNullOrEmpty
    }

    It 'uses the first btime line if several are present' {
        Mock Get-Content { @('btime 1700000000', 'btime 1800000000') }

        (Get-BootTimeLinux).ToUnixTimeSeconds() | Should -Be 1700000000
    }

    It 'reads the real /proc/stat on Linux and returns a boot time in the past' -Skip:(-not $Script:OnLinux) {
        $Boot = Get-BootTimeLinux

        $Boot | Should -Not -BeNullOrEmpty
        $Boot | Should -BeLessThan ([DateTimeOffset]::UtcNow)
        $Boot | Should -BeGreaterThan ([DateTimeOffset]::UtcNow.AddYears(-30))
    }
}

Describe 'Get-SystemBootTime' {

    BeforeEach {
        $detectedWindows = $false
        $detectedLinux   = $false
        $detectedMacOS   = $false
        $script:Fixed = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
    }

    It 'dispatches to the Windows implementation on Windows' {
        $detectedWindows = $true
        Mock Get-BootTimeWindows { $script:Fixed }
        Mock Get-BootTimeLinux   { throw 'wrong platform' }

        Get-SystemBootTime | Should -Be $script:Fixed
    }

    It 'dispatches to the Linux implementation on Linux' {
        $detectedLinux = $true
        Mock Get-BootTimeLinux { $script:Fixed }

        Get-SystemBootTime | Should -Be $script:Fixed
    }

    It 'dispatches to the macOS implementation on macOS' {
        $detectedMacOS = $true
        Mock Get-BootTimeMacOS { $script:Fixed }

        Get-SystemBootTime | Should -Be $script:Fixed
    }

    It 'falls through to macOS logic if the Linux lookup yields nothing' {
        $detectedLinux = $true
        $detectedMacOS = $true
        Mock Get-BootTimeLinux { $null }
        Mock Get-BootTimeMacOS { $script:Fixed }

        Get-SystemBootTime | Should -Be $script:Fixed
    }

    It 'returns $null (never throws) when the platform lookup fails' -TestCases @(
        @{ Platform = 'Windows' }
        @{ Platform = 'Linux' }
        @{ Platform = 'MacOS' }
    ) {
        Set-Variable -Name "detected$Platform" -Value $true
        Mock Get-BootTimeWindows { throw 'CIM unavailable' }
        Mock Get-BootTimeLinux   { throw '/proc not mounted' }
        Mock Get-BootTimeMacOS   { throw 'sysctl missing' }

        { Get-SystemBootTime } | Should -Not -Throw
        Get-SystemBootTime | Should -BeNullOrEmpty
    }

    It 'returns $null on an unrecognised platform' {
        Get-SystemBootTime | Should -BeNullOrEmpty
    }
}

Describe 'Read-PreviousState' {

    BeforeEach { Reset-TestRoot $script:Root }

    It 'returns $null when there is no state file (first run)' {
        Read-PreviousState | Should -BeNullOrEmpty
    }

    It 'returns the parsed state' {
        Write-TestState -HeartbeatAgeSeconds 5 -BootTime ([DateTimeOffset]::FromUnixTimeSeconds(1700000000))

        $State = Read-PreviousState
        (Get-JsonPropertyOrNull $State 'Hostname') | Should -Be 'h'
    }

    It 'returns $null (never throws) for a corrupt state file: <Case>' -TestCases @(
        @{ Case = 'garbage';   Content = 'not json at all' }
        @{ Case = 'empty';     Content = '' }
        @{ Case = 'truncated'; Content = '{"LastHeartbeat":"2026-09-1' }
        @{ Case = 'NUL bytes'; Content = "`0`0`0`0" }
    ) {
        Set-Content -LiteralPath $StatePath -Value $Content -NoNewline

        { Read-PreviousState } | Should -Not -Throw
        Read-PreviousState | Should -BeNullOrEmpty
    }
}

Describe 'Save-State' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:CurrentBootTime = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
        $Script:DockerAvailable = $true
    }

    It 'writes a JSON state file with heartbeat, boot time, hostname and docker flag' {
        Save-State

        $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $State.Hostname | Should -Be $Hostname
        $State.Docker   | Should -BeTrue
        $State.LastHeartbeat | Should -Not -BeNullOrEmpty
        $State.BootTime      | Should -Not -BeNullOrEmpty
    }

    It 'writes an empty BootTime when the boot time is unknown' {
        $Script:CurrentBootTime = $null

        Save-State

        (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).BootTime | Should -Be ''
    }

    It 'leaves no temporary file behind (write-then-rename)' {
        Save-State
        Save-State

        Test-Path -LiteralPath "$StatePath.tmp" | Should -BeFalse
    }

    It 'overwrites the previous state' {
        Save-State
        $First = (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).LastHeartbeat
        Start-Sleep -Milliseconds 1100
        Save-State
        $Second = (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).LastHeartbeat

        $Second | Should -Not -Be $First
    }

    It 'is round-trippable by Read-PreviousState' {
        Save-State

        (Get-JsonPropertyOrNull (Read-PreviousState) 'Hostname') | Should -Be $Hostname
    }

    It 'never leaves a truncated state.json if the write fails midway (old state survives)' {
        Save-State
        $Before = Get-Content -LiteralPath $StatePath -Raw

        Mock Move-Item { throw 'disk full' }
        { Save-State } | Should -Throw

        Get-Content -LiteralPath $StatePath -Raw | Should -Be $Before
    }

    It 'writes ISO-8601 dates regardless of culture' -Skip:(-not $Script:HasDe) {
        Use-Culture 'de-DE' { Save-State }

        (Get-Content -LiteralPath $StatePath -Raw) | Should -Match '"LastHeartbeat": "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d"'
    }
}

Describe 'Invoke-StartupDetection' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
        $RestartGapSeconds = 300
        $script:Boot = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
    }

    Context 'first run (no previous state)' {

        It 'logs BOOT with the boot time' {
            Invoke-StartupDetection -PreviousState $null -CurrentBootTime $script:Boot

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be 'BOOT'
            $Events[0].Data['BOOT_TIME'] | Should -Match '^2023-11-14T22:13:20'
        }

        It 'logs BOOT with "unknown" when the boot time cannot be determined' {
            Invoke-StartupDetection -PreviousState $null -CurrentBootTime $null

            (Read-EventLogRecords $LogPath)[0].Data['BOOT_TIME'] | Should -Be 'unknown'
        }
    }

    Context 'service restart on the same boot' {

        It 'logs nothing after a short gap' {
            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $script:Boot

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'logs START_AFTER_GAP with the gap after a long interruption' {
            Write-TestState -HeartbeatAgeSeconds 3600 -BootTime $script:Boot

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be 'START_AFTER_GAP'
            [int]$Events[0].Data['GAP_SECONDS'] | Should -BeGreaterOrEqual 3599
            [int]$Events[0].Data['GAP_SECONDS'] | Should -BeLessOrEqual 3610
        }

        It 'respects a custom -RestartGapSeconds threshold' {
            $RestartGapSeconds = 30
            Write-TestState -HeartbeatAgeSeconds 60 -BootTime $script:Boot

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath) | Should -Be @('START_AFTER_GAP')
        }

        It 'treats a gap just under the threshold as normal, just over it as a gap' {
            Write-TestState -HeartbeatAgeSeconds 290 -BootTime $script:Boot
            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot
            @(Get-EventNames $LogPath).Count | Should -Be 0

            Write-TestState -HeartbeatAgeSeconds 310 -BootTime $script:Boot
            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot
            @(Get-EventNames $LogPath) | Should -Be @('START_AFTER_GAP')
        }

        It 'ignores a heartbeat from the future (clock stepped backwards): negative gap' {
            Write-TestState -HeartbeatAgeSeconds -7200 -BootTime $script:Boot

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }
    }

    Context 'reboot detection' {

        It 'logs BOOT then REBOOT when the boot time changed' {
            $Previous = $script:Boot.AddDays(-3)
            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $Previous

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath) | Should -Be @('BOOT', 'REBOOT')

            $Reboot = (Read-EventLogRecords $LogPath)[1]
            $Reboot.Data['PREVIOUS_BOOT'] | Should -Match '^2023-11-11T22:13:20'
            $Reboot.Data['CURRENT_BOOT']  | Should -Match '^2023-11-14T22:13:20'
        }

        It 'reports REBOOT (and not also START_AFTER_GAP) when both a reboot and a long gap apply' {
            Write-TestState -HeartbeatAgeSeconds 7200 -BootTime $script:Boot.AddDays(-1)

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath) | Should -Be @('BOOT', 'REBOOT')
        }

        It 'does not report a reboot when the same boot time is compared across timezone offsets' {
            $Utc   = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
            $Local = $Utc.ToOffset([TimeSpan]::FromHours(-5))
            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $Local

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $Utc

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'does NOT report a reboot for an identical sub-second boot time (regression: precision loss)' {
            $Precise = [DateTimeOffset]'2026-09-13T08:10:15.5000000-05:00'
            $Script:CurrentBootTime = $Precise
            $Script:DockerAvailable = $false
            Save-State

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $Precise

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'treats any difference, even one second, as a reboot (documented current behaviour)' {
            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $script:Boot.AddSeconds(-1)

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath) | Should -Be @('BOOT', 'REBOOT')
        }
    }

    Context 'incomplete boot information' {

        It 'falls back to gap logic when the state has no BootTime property' {
            Write-TestState -HeartbeatAgeSeconds 3600 -OmitBootTime

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath) | Should -Be @('START_AFTER_GAP')
        }

        It 'falls back to gap logic when the saved BootTime is blank' {
            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $null

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot

            @(Get-EventNames $LogPath).Count | Should -Be 0
        }

        It 'falls back to gap logic when the current boot time is unknown' {
            Write-TestState -HeartbeatAgeSeconds 3600 -BootTime $script:Boot

            Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $null

            @(Get-EventNames $LogPath) | Should -Be @('START_AFTER_GAP')
        }
    }

    Context 'unusable previous state' {

        It 'logs one SERVICE_ERROR (and no BOOT) when state has <Case>' -TestCases @(
            @{ Case = 'no LastHeartbeat';       Json = '{"BootTime":"2023-11-14T22:13:20+00:00"}' }
            @{ Case = 'a garbage LastHeartbeat'; Json = '{"LastHeartbeat":"yesterday-ish"}' }
            @{ Case = 'a blank LastHeartbeat';  Json = '{"LastHeartbeat":""}' }
            @{ Case = 'a null LastHeartbeat';   Json = '{"LastHeartbeat":null}' }
            @{ Case = 'a numeric LastHeartbeat'; Json = '{"LastHeartbeat":12}' }
        ) {
            Set-Content -LiteralPath $StatePath -Value $Json
            $State = Read-PreviousState
            $State | Should -Not -BeNullOrEmpty

            Invoke-StartupDetection -PreviousState $State -CurrentBootTime $script:Boot

            $Events = Read-EventLogRecords $LogPath
            @($Events).Count | Should -Be 1
            $Events[0].Event | Should -Be 'SERVICE_ERROR'
            $Events[0].Data['MESSAGE'] | Should -Match 'Failed to process previous state'
        }

        It 'does not throw for a state that is a JSON scalar' {
            Set-Content -LiteralPath $StatePath -Value '5'

            { Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot } | Should -Not -Throw
        }
    }

    Context 'culture independence (regression: en-GB / de-DE could not parse the saved state)' {

        It 'detects a long gap under <Culture> with no SERVICE_ERROR' -TestCases @(
            @{ Culture = 'de-DE'; Available = $Script:HasDe }
            @{ Culture = 'en-GB'; Available = $Script:HasGb }
        ) {
            if (-not $Available) {
                Set-ItResult -Skipped -Because "$Culture is unavailable (invariant globalization)"
                return
            }

            Write-TestState -HeartbeatAgeSeconds 3600 -BootTime $script:Boot

            Use-Culture $Culture {
                Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot
            }

            @(Get-EventNames $LogPath) | Should -Be @('START_AFTER_GAP')
        }

        It 'detects a reboot under <Culture> with no SERVICE_ERROR' -TestCases @(
            @{ Culture = 'de-DE'; Available = $Script:HasDe }
            @{ Culture = 'en-GB'; Available = $Script:HasGb }
        ) {
            if (-not $Available) {
                Set-ItResult -Skipped -Because "$Culture is unavailable (invariant globalization)"
                return
            }

            Write-TestState -HeartbeatAgeSeconds 20 -BootTime $script:Boot.AddDays(-1)

            Use-Culture $Culture {
                Invoke-StartupDetection -PreviousState (Read-PreviousState) -CurrentBootTime $script:Boot
            }

            @(Get-EventNames $LogPath) | Should -Be @('BOOT', 'REBOOT')
        }

        It 'emits ISO-8601 boot times under a non-US culture' -Skip:(-not $Script:HasDe) {
            Use-Culture 'de-DE' { Invoke-StartupDetection -PreviousState $null -CurrentBootTime $script:Boot }

            (Read-EventLogRecords $LogPath)[0].Data['BOOT_TIME'] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d'
        }
    }
}

Describe 'Write-ServiceStartEvent' {

    BeforeEach {
        Reset-TestRoot $script:Root
        $Script:ForwardingEnabled = $false
    }

    It 'logs SERVICE_START with version, PowerShell version, OS and platform' {
        Write-ServiceStartEvent

        $Event = (Read-EventLogRecords $LogPath)[0]
        $Event.Event | Should -Be 'SERVICE_START'
        $Event.Data['VERSION']    | Should -Be $Script:GrongoMonitorVersion
        $Event.Data['POWERSHELL'] | Should -Be $PSVersionTable.PSVersion.ToString()
        $Event.Data['OS']         | Should -Not -BeNullOrEmpty
        $Event.Data['PLATFORM']   | Should -BeIn @('Windows', 'Linux', 'macOS')
    }

    It 'reports platform <Expected> for the matching detection flag' -TestCases @(
        @{ Flag = 'detectedWindows'; Expected = 'Windows' }
        @{ Flag = 'detectedLinux';   Expected = 'Linux' }
        @{ Flag = 'detectedMacOS';   Expected = 'macOS' }
    ) {
        $detectedWindows = $false; $detectedLinux = $false; $detectedMacOS = $false
        Set-Variable -Name $Flag -Value $true

        Write-ServiceStartEvent

        (Read-EventLogRecords $LogPath)[0].Data['PLATFORM'] | Should -Be $Expected
    }

    It 'reports "Unknown" when no platform flag is set' {
        $detectedWindows = $false; $detectedLinux = $false; $detectedMacOS = $false

        Write-ServiceStartEvent

        (Read-EventLogRecords $LogPath)[0].Data['PLATFORM'] | Should -Be 'Unknown'
    }

    It 'the version is a semantic version' {
        $Script:GrongoMonitorVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
}
