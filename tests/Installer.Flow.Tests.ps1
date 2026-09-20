#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . $Script:InstallScript

    $script:Root = New-TestRoot

    function New-TestLayout {
        # A Linux-shaped layout whose every path lives inside the sandbox.
        param([string]$Name = 'case', [switch]$InPlace)

        $Base = Join-Path $script:Root $Name
        $Src  = Join-Path $Base 'checkout'
        New-Item -ItemType Directory -Path $Src -Force | Out-Null
        Copy-Item -LiteralPath $Script:MonitorScript -Destination (Join-Path $Src 'grongoMonitor.ps1')

        $Systemd = Join-Path $Base 'systemd'
        New-Item -ItemType Directory -Path $Systemd -Force | Out-Null

        return (Get-InstallLayout -Platform Linux -SourceDirectory $Src `
            -InstallDir (Join-Path $Base 'opt/grongoMonitor') `
            -ServiceHome (Join-Path $Base 'home') `
            -SystemdDirectory $Systemd `
            -LaunchdDirectory $Systemd `
            -InPlace:$InPlace)
    }

    function New-TokenFile {
        param([string]$Name, [string]$Content)

        $Path = Join-Path $script:Root $Name
        Set-Content -LiteralPath $Path -Value $Content -NoNewline
        
	if (-not $IsWindows) { & chmod 600 $Path }
        return $Path
    }

    function Set-InstallerMocks {
        # Mocks every function that would touch the real OS.
        $script:Calls = [System.Collections.ArrayList]::new()
        $script:Said  = [System.Collections.ArrayList]::new()

        Mock Write-Host { [void]$script:Said.Add((@($Object) -join ' ')) }
        Mock Test-SystemdAvailable { $true }
        Mock Set-InstallDirectoryPermissions { [void]$script:Calls.Add('perms-installdir') }
        Mock Set-SecureFilePermissions { [void]$script:Calls.Add("perms:$Path") }
        Mock Invoke-Systemctl {
            [void]$script:Calls.Add("systemctl $($args -join ' ')")
            $global:LASTEXITCODE = 0
        }
        Mock Invoke-Launchctl {
            [void]$script:Calls.Add("launchctl $($args -join ' ')")
            $global:LASTEXITCODE = 0
        }
    }
}

AfterAll { Remove-TestRoot $script:Root }

Describe 'Resolve-InstallerToken' {

    BeforeEach {
        $script:SavedToken = $env:GRONGO_EVENT_TOKEN
        $env:GRONGO_EVENT_TOKEN = $null
        $WarningPreference = 'SilentlyContinue'
        Mock Read-ForwarderToken { 'prompted-token' }
    }

    AfterEach { $env:GRONGO_EVENT_TOKEN = $script:SavedToken }

    It 'reads the token from a file, trimming the trailing newline' -TestCases @(
        @{ Suffix = "`n" }, @{ Suffix = "`r`n" }, @{ Suffix = '' }, @{ Suffix = "  `n`n" }
    ) {
        $File = Join-Path $script:Root 'tok'
        Set-Content -LiteralPath $File -Value "abc123$Suffix" -NoNewline

        Resolve-InstallerToken -TokenFile $File | Should -Be 'abc123'
        Should -Invoke Read-ForwarderToken -Times 0
    }

    It 'prefers -EventTokenFile over the environment and the prompt' {
        $File = Join-Path $script:Root 'tok'
        Set-Content -LiteralPath $File -Value 'from-file' -NoNewline
        $env:GRONGO_EVENT_TOKEN = 'from-env'

        Resolve-InstallerToken -TokenFile $File | Should -Be 'from-file'
    }

    It 'falls back to $env:GRONGO_EVENT_TOKEN' {
        $env:GRONGO_EVENT_TOKEN = 'from-env'

        Resolve-InstallerToken | Should -Be 'from-env'
        Should -Invoke Read-ForwarderToken -Times 0
    }

    It 'falls back to the SecureString prompt last' {
        Resolve-InstallerToken | Should -Be 'prompted-token'
        Should -Invoke Read-ForwarderToken -Times 1 -Exactly
    }

    It 'ignores a whitespace-only environment token and prompts instead' {
        $env:GRONGO_EVENT_TOKEN = '   '

        Resolve-InstallerToken | Should -Be 'prompted-token'
    }

    It 'throws for a token file that does not exist' {
        { Resolve-InstallerToken -TokenFile (Join-Path $script:Root 'missing') } | Should -Throw '*not found*'
    }

    It 'throws for an empty token file (never installs an empty credential)' {
        $File = Join-Path $script:Root 'empty'
        Set-Content -LiteralPath $File -Value '' -NoNewline

        { Resolve-InstallerToken -TokenFile $File } | Should -Throw '*required*'
    }

    It 'throws when the prompt returns nothing' {
        Mock Read-ForwarderToken { '' }

        { Resolve-InstallerToken } | Should -Throw '*required*'
    }

    It 'rejects a token containing whitespace (a pasted multi-line value)' {
        $File = Join-Path $script:Root 'multi'
        Set-Content -LiteralPath $File -Value "abc`ndef" -NoNewline

        { Resolve-InstallerToken -TokenFile $File } | Should -Throw '*single line*'
    }

    It 'warns when the token file is readable by other users' -Skip:$isWindows {
        $File = Join-Path $script:Root 'loose'
        Set-Content -LiteralPath $File -Value 'abc' -NoNewline
        & chmod 644 $File

        Resolve-InstallerToken -TokenFile $File -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null

        ($Warned -join ' ') | Should -Match 'readable by other users'
    }

    It 'does not warn for a 600 token file' -Skip:$isWindows {
        $File = Join-Path $script:Root 'tight'
        Set-Content -LiteralPath $File -Value 'abc' -NoNewline
        & chmod 600 $File

        Resolve-InstallerToken -TokenFile $File -WarningVariable Warned -WarningAction SilentlyContinue | Out-Null

        @($Warned).Count | Should -Be 0
    }
}

Describe 'Write-ForwarderConfigFiles' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "cfg-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    }

    It 'creates the data directory, config.json and token' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://events.example.com' -Token 'tok123'

        Test-Path -LiteralPath $script:L.ConfigPath | Should -BeTrue
        Test-Path -LiteralPath $script:L.TokenPath  | Should -BeTrue
    }

    It 'writes the documented defaults' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://events.example.com' -Token 't'

        $Config = Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json
        $Config.server            | Should -Be 'https://events.example.com'
        $Config.batchSize         | Should -Be 50
        $Config.intervalSeconds   | Should -Be 30
        $Config.maxBackoffSeconds | Should -Be 900
    }

    It 'normalises the server URL (trims whitespace and a trailing slash)' {
        Write-ForwarderConfigFiles -Layout $script:L -Server '  https://events.example.com/  ' -Token 't'

        (Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json).server | Should -Be 'https://events.example.com'
    }

    It 'stores the token exactly, with no newline and no BOM' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 'abc-DEF_123'

        $Bytes = [System.IO.File]::ReadAllBytes($script:L.TokenPath)
        [System.Text.Encoding]::UTF8.GetString($Bytes) | Should -Be 'abc-DEF_123'
    }

    It 'never writes the token into config.json' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 'SECRETVALUE'

        (Get-Content -LiteralPath $script:L.ConfigPath -Raw) | Should -Not -Match 'SECRETVALUE'
    }

    It 'applies batch size and interval overrides' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 't' -BatchSize 75 -IntervalSeconds 45

        $Config = Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json
        $Config.batchSize | Should -Be 75
        $Config.intervalSeconds | Should -Be 45
    }

    It 'preserves existing non-secret settings when they are not overridden' {
        New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
        Set-Content -LiteralPath $script:L.ConfigPath -Value '{"server":"https://old","batchSize":10,"intervalSeconds":15,"maxBackoffSeconds":120}'

        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://new.example' -Token 't'

        $Config = Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json
        $Config.server            | Should -Be 'https://new.example'
        $Config.batchSize         | Should -Be 10
        $Config.intervalSeconds   | Should -Be 15
        $Config.maxBackoffSeconds | Should -Be 120
    }

    It 'lets an explicit override beat the existing value' {
        New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
        Set-Content -LiteralPath $script:L.ConfigPath -Value '{"batchSize":10}'

        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 't' -BatchSize 99

        (Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json).batchSize | Should -Be 99
    }

    It 'falls back to defaults for a corrupt or junk existing config: <Case>' -TestCases @(
        @{ Case = 'invalid JSON';  Content = '{ nope' }
        @{ Case = 'empty';         Content = '' }
        @{ Case = 'an array';      Content = '[1,2]' }
        @{ Case = 'wrong types';   Content = '{"batchSize":"lots","intervalSeconds":-5,"maxBackoffSeconds":0}' }
    ) {
        New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
        Set-Content -LiteralPath $script:L.ConfigPath -Value $Content -NoNewline

        { Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 't' } | Should -Not -Throw

        $Config = Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json
        $Config.batchSize | Should -Be 50
        $Config.intervalSeconds | Should -Be 30
        $Config.maxBackoffSeconds | Should -Be 900
    }

    It 'locks the token file down BEFORE the secret is written (no readable window)' {
        $script:TokenAtLock = 'not-captured'
        Mock Set-SecureFilePermissions {
            if ($Path -eq $script:L.TokenPath) { $script:TokenAtLock = [System.IO.File]::ReadAllText($Path) }
        }

        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 'SECRET'

        $script:TokenAtLock | Should -Be ''
        [System.IO.File]::ReadAllText($script:L.TokenPath) | Should -Be 'SECRET'
    }

    It 'restricts both the data directory and the token file' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 't'

        Should -Invoke Set-SecureFilePermissions -ParameterFilter { $Path -eq $script:L.GrongoHome -and $Directory } -Times 1
        Should -Invoke Set-SecureFilePermissions -ParameterFilter { $Path -eq $script:L.TokenPath } -Times 1
    }

    It 'overwrites an existing token' {
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 'old'
        Write-ForwarderConfigFiles -Layout $script:L -Server 'https://e.example' -Token 'new'

        [System.IO.File]::ReadAllText($script:L.TokenPath) | Should -Be 'new'
    }
}

Describe 'Set-SecureFilePermissions (real chmod)' -Skip:$isWindows {

    It 'makes a file 600 and a directory 700' {
        $Dir  = Join-Path $script:Root 'perm-dir'
        $File = Join-Path $Dir 'token'
        New-Item -ItemType Directory -Path $Dir | Out-Null
        Set-Content -LiteralPath $File -Value 'x'
        & chmod 777 $Dir $File

        Set-SecureFilePermissions -Path $Dir -Directory
        Set-SecureFilePermissions -Path $File

        (& stat -c '%a' $Dir).Trim()  | Should -Be '700'
        (& stat -c '%a' $File).Trim() | Should -Be '600'
    }

    It 'the token file written by the installer ends up 600 inside a 700 directory' {
        $L = New-TestLayout -Name "real-perm-$([guid]::NewGuid().ToString('N').Substring(0,6))"

        Write-ForwarderConfigFiles -Layout $L -Server 'https://e.example' -Token 'tok'

        (& stat -c '%a' $L.TokenPath).Trim() | Should -Be '600'
        (& stat -c '%a' $L.GrongoHome).Trim() | Should -Be '700'
    }
}

Describe 'Install-MonitorFiles / Remove-MonitorFiles' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "stage-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    }

    It 'copies the monitor into the install directory' {
        Install-MonitorFiles -Layout $script:L

        Test-Path -LiteralPath $script:L.ScriptPath | Should -BeTrue
        (Get-FileHash -LiteralPath $script:L.ScriptPath).Hash | Should -Be (Get-FileHash -LiteralPath $script:L.SourceScript).Hash
    }

    It 'writes a marker file so uninstall only deletes what it created' {
        Install-MonitorFiles -Layout $script:L

        $Marker = Join-Path $script:L.InstallDir '.installed-by-grongoMonitor'
        Test-Path -LiteralPath $Marker | Should -BeTrue
        (Get-Content -LiteralPath $Marker -Raw) | Should -Match 'grongoMonitor \d+\.\d+\.\d+ installed'
    }

    It 'locks down the install directory (root-owned, not user-writable)' {
        Install-MonitorFiles -Layout $script:L

        Should -Invoke Set-InstallDirectoryPermissions -Times 1 -Exactly -ParameterFilter { $Directory -eq $script:L.InstallDir }
    }

    It 'replaces an older copy on update' {
        New-Item -ItemType Directory -Path $script:L.InstallDir -Force | Out-Null
        Set-Content -LiteralPath $script:L.ScriptPath -Value '# old version'

        Install-MonitorFiles -Layout $script:L

        (Get-Content -LiteralPath $script:L.ScriptPath -Raw) | Should -Not -Match 'old version'
    }

    It 'does not copy anything with -InPlace' {
        $InPlace = New-TestLayout -Name "inplace-$([guid]::NewGuid().ToString('N').Substring(0,6))" -InPlace

        Install-MonitorFiles -Layout $InPlace

        Test-Path -LiteralPath $InPlace.InstallDir | Should -BeFalse
        $InPlace.ScriptPath | Should -Be $InPlace.SourceScript
    }

    It 'refuses to stage into an unsafe directory' -Skip:$isWindows {
        $Bad = Get-InstallLayout -Platform Linux -SourceDirectory $script:L.SourceDirectory -InstallDir '/usr'

        { Install-MonitorFiles -Layout $Bad } | Should -Throw '*Refusing*'
    }

    It 'Remove-MonitorFiles deletes a directory that carries the marker' {
        Install-MonitorFiles -Layout $script:L

        Remove-MonitorFiles -Layout $script:L

        Test-Path -LiteralPath $script:L.InstallDir | Should -BeFalse
    }

    It 'Remove-MonitorFiles leaves a directory without the marker alone (never deletes what it did not create)' {
        New-Item -ItemType Directory -Path $script:L.InstallDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:L.InstallDir 'precious.txt') -Value 'mine'

        Remove-MonitorFiles -Layout $script:L

        Test-Path -LiteralPath (Join-Path $script:L.InstallDir 'precious.txt') | Should -BeTrue
    }

    It 'Remove-MonitorFiles is a no-op when nothing is installed' {
        { Remove-MonitorFiles -Layout $script:L } | Should -Not -Throw
    }

    It 'Remove-MonitorFiles never touches the checkout when running in place' {
        $InPlace = New-TestLayout -Name "inplace2-$([guid]::NewGuid().ToString('N').Substring(0,6))" -InPlace
        Set-Content -LiteralPath (Join-Path $InPlace.SourceDirectory '.installed-by-grongoMonitor') -Value 'x'

        Remove-MonitorFiles -Layout $InPlace

        Test-Path -LiteralPath $InPlace.SourceScript | Should -BeTrue
    }

    It 'Remove-DataDirectory deletes the .grongoMonitor directory' {
        New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:L.GrongoHome 'events.log') -Value 'x'

        Remove-DataDirectory -Layout $script:L

        Test-Path -LiteralPath $script:L.GrongoHome | Should -BeFalse
    }

    It 'Remove-DataDirectory refuses a directory that is not named .grongoMonitor' {
        $Odd = [pscustomobject]@{ GrongoHome = (Join-Path $script:Root 'important-data') }
        New-Item -ItemType Directory -Path $Odd.GrongoHome -Force | Out-Null

        Remove-DataDirectory -Layout $Odd -WarningAction SilentlyContinue

        Test-Path -LiteralPath $Odd.GrongoHome | Should -BeTrue
    }
}

Describe 'Linux service (systemd) with a mocked systemctl' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "sd-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    }

    It 'writes the unit, then daemon-reload, enable, start - in that order' {
        Install-LinuxService -Layout $script:L -PwshPath '/usr/bin/pwsh' | Out-Null

        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeTrue
        @($script:Calls | Where-Object { $_ -like 'systemctl*' }) | Should -Be @(
            'systemctl daemon-reload', 'systemctl enable grongoMonitor.service', 'systemctl start grongoMonitor.service')
    }

    It 'the unit points at the staged script, not the checkout' {
        Install-LinuxService -Layout $script:L -PwshPath '/usr/bin/pwsh' | Out-Null

        $Unit = Get-Content -LiteralPath $script:L.SystemdUnitPath -Raw
        $Unit | Should -Match ([regex]::Escape("-File $($script:L.ScriptPath)"))
        $Unit | Should -Not -Match ([regex]::Escape($script:L.SourceDirectory))
    }

    It 'throws if <Step> fails' -TestCases @(
        @{ Step = 'daemon-reload'; Fail = 'daemon-reload'; Message = '*daemon-reload*' }
        @{ Step = 'enable';        Fail = 'enable';        Message = '*enable*' }
        @{ Step = 'start';         Fail = 'start';         Message = '*start*' }
    ) {
        $script:FailOn = $Fail
        Mock Invoke-Systemctl { $global:LASTEXITCODE = if ("$args" -match $script:FailOn) { 1 } else { 0 } }

        { Install-LinuxService -Layout $script:L -PwshPath '/usr/bin/pwsh' | Out-Null } | Should -Throw $Message
    }

    It 'Remove-LinuxService stops, disables, deletes the unit and reloads' {
        Install-LinuxService -Layout $script:L -PwshPath '/usr/bin/pwsh' | Out-Null
        $script:Calls.Clear()

        Remove-LinuxService -Layout $script:L

        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeFalse
        @($script:Calls) | Should -Be @('systemctl stop grongoMonitor.service', 'systemctl disable grongoMonitor.service', 'systemctl daemon-reload')
    }

    It 'Test-LinuxServiceInstalled reflects the unit file' {
        Test-LinuxServiceInstalled -Layout $script:L | Should -BeFalse
        Install-LinuxService -Layout $script:L -PwshPath '/usr/bin/pwsh' | Out-Null
        Test-LinuxServiceInstalled -Layout $script:L | Should -BeTrue
    }
}

Describe 'macOS service (launchd) with a mocked launchctl' -Skip:$isWindows {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "mac-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    }

    It 'writes a valid plist and bootstraps it into the system domain' {
        Install-MacOSService -Layout $script:L -PwshPath '/usr/local/bin/pwsh' | Out-Null

        { [xml](Get-Content -LiteralPath $script:L.LaunchdPlistPath -Raw) } | Should -Not -Throw
        @($script:Calls) | Should -Contain "launchctl bootstrap system $($script:L.LaunchdPlistPath)"
    }

    It 'makes the plist 644 (launchd rejects group/world-writable plists)' {
        Install-MacOSService -Layout $script:L -PwshPath '/usr/local/bin/pwsh' | Out-Null

        (& stat -c '%a' $script:L.LaunchdPlistPath 2>$null) | Should -Be '644'
    }

    It 'throws if bootstrap fails' {
        Mock Invoke-Launchctl { $global:LASTEXITCODE = 5 }

        { Install-MacOSService -Layout $script:L -PwshPath '/usr/local/bin/pwsh' | Out-Null } | Should -Throw '*launchd*'
    }

    It 'Remove-MacOSService boots out and deletes the plist' {
        Install-MacOSService -Layout $script:L -PwshPath '/usr/local/bin/pwsh' | Out-Null

        Remove-MacOSService -Layout $script:L

        Test-Path -LiteralPath $script:L.LaunchdPlistPath | Should -BeFalse
        @($script:Calls) | Should -Contain "launchctl bootout system $($script:L.LaunchdPlistPath)"
    }
}

Describe 'Invoke-GrongoInstall (Linux layout)' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "inst-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $script:SavedToken = $env:GRONGO_EVENT_TOKEN
        $env:GRONGO_EVENT_TOKEN = $null
    }

    AfterEach { $env:GRONGO_EVENT_TOKEN = $script:SavedToken }

    Context 'fresh install' {

        It 'stages the script, installs and starts the service, and reports success' {
            $Result = Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null

            $Result | Should -BeTrue
            Test-Path -LiteralPath $script:L.ScriptPath | Should -BeTrue
            Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeTrue
            @($script:Calls) | Should -Contain 'systemctl start grongoMonitor.service'
        }

        It 'does not create forwarding config unless forwarding was requested' {
            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null | Out-Null

            Test-Path -LiteralPath $script:L.ConfigPath | Should -BeFalse
            Test-Path -LiteralPath $script:L.TokenPath  | Should -BeFalse
        }

        It 'installs with forwarding: config + token written, verified, service started' {
            $TokenFile = New-TokenFile 'install-token' "the-token`n"

            $Result = Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true `
                -Server 'https://events.example.com' -TokenFile $TokenFile -BatchSize 25 6>$null

            $Result | Should -BeTrue
            (Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json).batchSize | Should -Be 25
            [System.IO.File]::ReadAllText($script:L.TokenPath) | Should -Be 'the-token'
        }

        It 'writes configuration BEFORE starting the service (so the first start already forwards)' {
            $TokenFile = New-TokenFile 'order-token' 't'
            $script:ConfigAtStart = $null
            Mock Invoke-Systemctl {
                [void]$script:Calls.Add("systemctl $($args -join ' ')")
                if ("$args" -eq 'start grongoMonitor.service') { $script:ConfigAtStart = Test-Path -LiteralPath $script:L.ConfigPath }
                $global:LASTEXITCODE = 0
            }

            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true `
                -Server 'https://e.example' -TokenFile $TokenFile 6>$null | Out-Null

            $script:ConfigAtStart | Should -BeTrue
        }
    }

    Context 'an installation already exists' {

        BeforeEach {
            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null | Out-Null
            $script:Calls.Clear()
            Set-Content -LiteralPath $script:L.ScriptPath -Value '# marker: previously installed copy'
        }

        It 'without -Reinstall it changes nothing and says so' {
            $Result = Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null

            $Result | Should -BeFalse
            $script:Calls.Count | Should -Be 0
            (Get-Content -LiteralPath $script:L.ScriptPath -Raw) | Should -Match 'previously installed copy'
        }

        It 'without -Reinstall it does not touch forwarding config either' {
            $TokenFile = New-TokenFile 'noreinstall-token' 't'

            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true `
                -Server 'https://e.example' -TokenFile $TokenFile 6>$null | Out-Null

            Test-Path -LiteralPath $script:L.ConfigPath | Should -BeFalse
        }

        It '-Reinstall replaces the service and refreshes the staged script (the update path)' {
            $Result = Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -Reinstall 6>$null

            $Result | Should -BeTrue
            (Get-Content -LiteralPath $script:L.ScriptPath -Raw) | Should -Not -Match 'previously installed copy'
            @($script:Calls | Where-Object { $_ -like 'systemctl stop*' }).Count | Should -Be 1
            @($script:Calls) | Should -Contain 'systemctl start grongoMonitor.service'
        }

        It '-Reinstall keeps existing forwarding configuration and token when none is supplied' {
            New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
            Set-Content -LiteralPath $script:L.ConfigPath -Value '{"server":"https://keep.example"}'
            Set-Content -LiteralPath $script:L.TokenPath -Value 'keep-token' -NoNewline

            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -Reinstall 6>$null | Out-Null

            (Get-Content -LiteralPath $script:L.ConfigPath -Raw) | Should -Match 'keep.example'
            [System.IO.File]::ReadAllText($script:L.TokenPath) | Should -Be 'keep-token'
        }
    }

    Context 'preflight failures leave the machine untouched' {

        It 'a syntax error in the script aborts BEFORE the running service is removed' {
            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null | Out-Null
            $script:Calls.Clear()
            Set-Content -LiteralPath $script:L.SourceScript -Value 'function Broken { if ( '

            { Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -Reinstall 6>$null } | Should -Throw '*syntax errors*'

            $script:Calls.Count | Should -Be 0
            Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeTrue
        }

        It 'no systemd -> a clear error and nothing written' {
            Mock Test-SystemdAvailable { $false }

            { Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null } | Should -Throw '*systemd was not detected*'

            Test-Path -LiteralPath $script:L.InstallDir | Should -BeFalse
            Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeFalse
        }

        It 'an invalid server URL aborts before anything is changed: <Url>' -TestCases @(
            @{ Url = 'events.example.com' }
            @{ Url = 'ftp://x' }
            @{ Url = '' }
        ) {
            { Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true -Server $Url 6>$null } |
                Should -Throw '*invalid*'

            Test-Path -LiteralPath $script:L.InstallDir | Should -BeFalse
            $script:Calls.Count | Should -Be 0
        }

        It 'a missing token file aborts before anything is changed' {
            { Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true `
                -Server 'https://e.example' -TokenFile (Join-Path $script:Root 'nope') 6>$null } | Should -Throw '*not found*'

            Test-Path -LiteralPath $script:L.InstallDir | Should -BeFalse
        }

        It 'an unsafe install directory aborts' -Skip:$isWindows {
            $Bad = Get-InstallLayout -Platform Linux -SourceDirectory $script:L.SourceDirectory -InstallDir '/etc' `
                -SystemdDirectory (Split-Path -Parent $script:L.SystemdUnitPath)

            { Invoke-GrongoInstall -Layout $Bad -PwshPath '/usr/bin/pwsh' 6>$null } | Should -Throw '*Refusing*'
        }

        It 'warns (but proceeds) for an http:// server' {
            $TokenFile = New-TokenFile 'http-token' 't'

            Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' -ForwardingRequested $true `
                -Server 'http://10.0.0.5:8080' -TokenFile $TokenFile -WarningVariable Warned -WarningAction SilentlyContinue 6>$null | Out-Null

            ($Warned -join ' ') | Should -Match 'HTTPS'
            Test-Path -LiteralPath $script:L.ConfigPath | Should -BeTrue
        }
    }
}

Describe 'Invoke-GrongoUninstall' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "un-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Invoke-GrongoInstall -Layout $script:L -PwshPath '/usr/bin/pwsh' 6>$null | Out-Null
        New-Item -ItemType Directory -Path $script:L.GrongoHome -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:L.GrongoHome 'events.log') -Value 'history'
        $script:Calls.Clear()
    }

    It 'removes the service and the staged code but keeps the data by default' {
        Invoke-GrongoUninstall -Layout $script:L 6>$null

        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeFalse
        Test-Path -LiteralPath $script:L.InstallDir | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:L.GrongoHome 'events.log') | Should -BeTrue
    }

    It '-Purge also deletes the data directory' {
        Invoke-GrongoUninstall -Layout $script:L -Purge 6>$null

        Test-Path -LiteralPath $script:L.GrongoHome | Should -BeFalse
    }

    It 'is idempotent: uninstalling twice is not an error' {
        Invoke-GrongoUninstall -Layout $script:L 6>$null

        { Invoke-GrongoUninstall -Layout $script:L 6>$null } | Should -Not -Throw
    }

    It 'says so when nothing is installed' {
        Invoke-GrongoUninstall -Layout $script:L 6>$null
        Invoke-GrongoUninstall -Layout $script:L

        ($script:Said -join "`n") | Should -Match 'not installed'
    }
}

Describe 'Invoke-GrongoInstaller (top level)' {

    BeforeEach {
        Set-InstallerMocks
        $script:L = New-TestLayout -Name "top-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Mock Get-InstallPlatform { 'Linux' }
        Mock Test-IsAdministrator { $true }
        Mock Get-PwshPath { '/usr/bin/pwsh' }
        Mock Get-InstallLayout { $script:L }
    }

    It 'refuses to run without administrator / root privileges' {
        Mock Test-IsAdministrator { $false }

        { Invoke-GrongoInstaller -SourceDirectory $script:L.SourceDirectory 6>$null } | Should -Throw '*administrator/root*'
    }

    It 'fails clearly when the monitor script is not next to the installer' {
        Remove-Item -LiteralPath $script:L.SourceScript

        { Invoke-GrongoInstaller -SourceDirectory $script:L.SourceDirectory 6>$null } | Should -Throw '*Could not find grongoMonitor.ps1*'
    }

    It 'installs end to end' {
        Invoke-GrongoInstaller -SourceDirectory $script:L.SourceDirectory 6>$null

        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeTrue
    }

    It '-Uninstall does not need the monitor script and removes the service' {
        Invoke-GrongoInstaller -SourceDirectory $script:L.SourceDirectory 6>$null
        Remove-Item -LiteralPath $script:L.SourceScript

        Invoke-GrongoInstaller -Uninstall -SourceDirectory $script:L.SourceDirectory 6>$null

        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeFalse
    }

    It 'prompts for the server with NO default when forwarding is requested without one' {
        Mock Read-Host { '' }

        { Invoke-GrongoInstaller -ForwardingRequested $true -SourceDirectory $script:L.SourceDirectory 6>$null } | Should -Throw '*invalid*'

        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { $Prompt -notmatch 'grongo\.dev' }
        Test-Path -LiteralPath $script:L.SystemdUnitPath | Should -BeFalse
    }

    It 'uses the server typed at the prompt' {
        Mock Read-Host { 'https://typed.example.com' }
        $TokenFile = New-TokenFile 'top-token' 't'

        Invoke-GrongoInstaller -ForwardingRequested $true -EventTokenFile $TokenFile -SourceDirectory $script:L.SourceDirectory 6>$null

        (Get-Content -LiteralPath $script:L.ConfigPath -Raw | ConvertFrom-Json).server | Should -Be 'https://typed.example.com'
    }
}

Describe 'Get-PwshPath' {

    It 'returns an existing path to pwsh' {
        Test-Path -LiteralPath (Get-PwshPath) | Should -BeTrue
    }

    It 'throws a helpful message when pwsh is not on PATH' {
        $Saved = $env:PATH
        try {
            $env:PATH = Join-Path $script:Root 'nothing-here'
            { Get-PwshPath } | Should -Throw '*PowerShell 7*'
        }
        finally { $env:PATH = $Saved }
    }
}
