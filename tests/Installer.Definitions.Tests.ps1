#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')
    . $Script:InstallScript

    $script:Src = Join-Path ([System.IO.Path]::GetTempPath()) 'gm-src-layout'
}

Describe 'Get-InstallLayout' {

    It 'Linux defaults: root-owned /opt install dir, systemd unit, /root data' {
        $L = Get-InstallLayout -Platform Linux -SourceDirectory $script:Src

        $L.ServiceHome      | Should -Be '/root'
        $L.GrongoHome       | Should -Be '/root/.grongoMonitor'
        $L.ConfigPath       | Should -Be '/root/.grongoMonitor/config.json'
        $L.TokenPath        | Should -Be '/root/.grongoMonitor/token'
        $L.InstallDir       | Should -Be '/opt/grongoMonitor'
        $L.ScriptPath       | Should -Be '/opt/grongoMonitor/grongoMonitor.ps1'
        $L.WorkingDirectory | Should -Be '/opt/grongoMonitor'
        $L.SystemdUnitPath  | Should -Be '/etc/systemd/system/grongoMonitor.service'
        $L.Staged           | Should -BeTrue
    }

    It 'macOS defaults: /usr/local/lib install dir, LaunchDaemon plist, /var/root data' {
        $L = Get-InstallLayout -Platform macOS -SourceDirectory $script:Src

        $L.ServiceHome       | Should -Be '/var/root'
        $L.InstallDir        | Should -Be '/usr/local/lib/grongoMonitor'
        $L.LaunchdPlistPath  | Should -Be '/Library/LaunchDaemons/com.grongodev.grongoMonitor.plist'
        $L.Label             | Should -Be 'com.grongodev.grongoMonitor'
    }

    It 'Windows defaults: SYSTEM profile for data, Program Files for code, a named task' {
        $L = Get-InstallLayout -Platform Windows -SourceDirectory $script:Src

        $L.ServiceHome | Should -Match 'systemprofile$'
        $L.InstallDir  | Should -Match 'grongoMonitor$'
        $L.TaskName    | Should -Be 'grongoMonitor'
        $L.GrongoHome  | Should -Match '\.grongoMonitor$'
    }

    It '-InPlace runs the checkout itself (nothing to copy)' {
        $Platform = Get-InstallPlatform
        $L = Get-InstallLayout -Platform $Platform -SourceDirectory $script:Src -InPlace

        $L.Staged           | Should -BeFalse
        $L.ScriptPath       | Should -Be (Join-Path $script:Src 'grongoMonitor.ps1')
        $L.WorkingDirectory | Should -Be $script:Src
    }

    It 'an install dir equal to the source dir is treated as in place' {
        $L = Get-InstallLayout -Platform Linux -SourceDirectory '/opt/grongoMonitor'

        $L.Staged | Should -BeFalse
    }

    It 'the same-directory check ignores trailing slashes' {
        (Get-InstallLayout -Platform Linux -SourceDirectory '/opt/grongoMonitor/').Staged | Should -BeFalse
    }

    It 'honours a custom -InstallDir' {
        $L = Get-InstallLayout -Platform Linux -SourceDirectory $script:Src -InstallDir '/srv/grongo'

        $L.ScriptPath | Should -Be '/srv/grongo/grongoMonitor.ps1'
    }

    It 'honours ServiceHome and directory overrides (used by tests and unusual hosts)' {
        $L = Get-InstallLayout -Platform Linux -SourceDirectory $script:Src -ServiceHome '/home/svc' `
            -SystemdDirectory '/tmp/units' -LaunchdDirectory '/tmp/plists'

        $L.GrongoHome       | Should -Be '/home/svc/.grongoMonitor'
        $L.SystemdUnitPath  | Should -Be '/tmp/units/grongoMonitor.service'
        $L.LaunchdPlistPath | Should -Be '/tmp/plists/com.grongodev.grongoMonitor.plist'
    }

    It 'rejects an unknown platform' {
        { Get-InstallLayout -Platform Amiga -SourceDirectory $script:Src } | Should -Throw
    }
}

Describe 'Get-InstallPlatform' {

    It 'reports the platform this suite is running on' {
        Get-InstallPlatform | Should -BeIn @('Windows', 'Linux', 'macOS')
    }
}

Describe 'ConvertTo-SystemdArgument' {

    It 'leaves ordinary paths bare: <Value>' -TestCases @(
        @{ Value = '/usr/bin/pwsh' }
        @{ Value = '/opt/grongoMonitor/grongoMonitor.ps1' }
        @{ Value = '-NoProfile' }
        @{ Value = '/root' }
    ) {
        ConvertTo-SystemdArgument $Value | Should -Be $Value
    }

    It 'quotes a path containing a space' {
        ConvertTo-SystemdArgument '/opt/my dir/x.ps1' | Should -Be '"/opt/my dir/x.ps1"'
    }

    It 'escapes an embedded double quote' {
        ConvertTo-SystemdArgument 'a"b' | Should -Be '"a\"b"'
    }

    It 'doubles % (systemd specifier) and $ (variable expansion)' {
        ConvertTo-SystemdArgument '/opt/100%/x' | Should -Be '"/opt/100%%/x"'
        ConvertTo-SystemdArgument '/opt/$HOME/x' | Should -Be '"/opt/$$HOME/x"'
    }

    It 'doubles backslashes' {
        ConvertTo-SystemdArgument 'a\b' | Should -Be '"a\\b"'
    }

    It 'quotes non-ASCII paths' {
        ConvertTo-SystemdArgument '/opt/café/x.ps1' | Should -Be '"/opt/café/x.ps1"'
    }

    It 'refuses a newline (it would inject a second directive)' {
        { ConvertTo-SystemdArgument "/opt/x`nExecStartPost=/bin/evil" } | Should -Throw
    }

    It 'refuses a carriage return' {
        { ConvertTo-SystemdArgument "/opt/x`r/y" } | Should -Throw
    }
}

Describe 'ConvertTo-SystemdPath' {

    It 'leaves spaces alone (WorkingDirectory is not quoted) but escapes %' {
        ConvertTo-SystemdPath '/opt/my dir/100%' | Should -Be '/opt/my dir/100%%'
    }

    It 'refuses a newline' {
        { ConvertTo-SystemdPath "/opt/x`ny" } | Should -Throw
    }
}

Describe 'New-SystemdUnitText' {

    BeforeAll {
        $script:Unit = New-SystemdUnitText -PwshPath '/usr/bin/pwsh' -ScriptPath '/opt/grongoMonitor/grongoMonitor.ps1' `
            -WorkingDirectory '/opt/grongoMonitor' -ServiceHome '/root'
    }

    It 'has the three standard sections' {
        $script:Unit | Should -Match '(?m)^\[Unit\]'
        $script:Unit | Should -Match '(?m)^\[Service\]'
        $script:Unit | Should -Match '(?m)^\[Install\]'
    }

    It 'runs the staged script with -File, non-interactively, without a profile' {
        $script:Unit | Should -Match '(?m)^ExecStart=/usr/bin/pwsh -NoLogo -NoProfile -NonInteractive -File /opt/grongoMonitor/grongoMonitor.ps1$'
    }

    It 'runs as root, restarts always, and starts after Docker and the network' {
        $script:Unit | Should -Match '(?m)^User=root$'
        $script:Unit | Should -Match '(?m)^Restart=always$'
        $script:Unit | Should -Match '(?m)^After=network-online\.target docker\.service$'
        $script:Unit | Should -Match '(?m)^WantedBy=multi-user\.target$'
    }

    It 'declares After= only once (the old unit repeated it)' {
        @([regex]::Matches($script:Unit, '(?m)^After=')).Count | Should -Be 1
    }

    It 'pins HOME and turns off PowerShell telemetry and update checks' {
        $script:Unit | Should -Match '(?m)^Environment=HOME=/root$'
        $script:Unit | Should -Match '(?m)^Environment=POWERSHELL_TELEMETRY_OPTOUT=1$'
        $script:Unit | Should -Match '(?m)^Environment=POWERSHELL_UPDATECHECK=Off$'
    }

    It 'sets the working directory' {
        $script:Unit | Should -Match '(?m)^WorkingDirectory=/opt/grongoMonitor$'
    }

    It 'quotes ExecStart words containing spaces' {
        $Unit = New-SystemdUnitText -PwshPath '/opt/pwsh 7/pwsh' -ScriptPath '/opt/my dir/grongoMonitor.ps1' -WorkingDirectory '/opt/my dir'

        $Unit | Should -Match '(?m)^ExecStart="/opt/pwsh 7/pwsh" -NoLogo -NoProfile -NonInteractive -File "/opt/my dir/grongoMonitor.ps1"$'
        $Unit | Should -Match '(?m)^WorkingDirectory=/opt/my dir$'
    }

    It 'a hostile path cannot add extra directives' {
        { New-SystemdUnitText -PwshPath '/usr/bin/pwsh' -ScriptPath "/opt/x`nExecStartPost=/bin/evil" -WorkingDirectory '/opt' } | Should -Throw
    }

    It 'has exactly one ExecStart and no stray blank ExecStart' {
        @([regex]::Matches($script:Unit, '(?m)^ExecStart=')).Count | Should -Be 1
    }

    It 'contains no Windows line endings' {
        $script:Unit | Should -Not -Match "`r"
    }
}

Describe 'New-LaunchdPlistText' {

    It 'produces well-formed XML with the expected keys' {
        $Text = New-LaunchdPlistText -Label 'com.grongodev.grongoMonitor' -PwshPath '/usr/local/bin/pwsh' `
            -ScriptPath '/usr/local/lib/grongoMonitor/grongoMonitor.ps1'

        $Xml  = [xml]$Text
        $Keys = @($Xml.SelectNodes('/plist/dict/key') | ForEach-Object { $_.InnerText })

        $Keys | Should -Contain 'Label'
        $Keys | Should -Contain 'ProgramArguments'
        $Keys | Should -Contain 'RunAtLoad'
        $Keys | Should -Contain 'KeepAlive'
        $Keys | Should -Contain 'EnvironmentVariables'
        $Xml.SelectSingleNode('/plist/dict/string[1]').InnerText | Should -Be 'com.grongodev.grongoMonitor'
    }

    It 'lists the program arguments in the right order' {
        $Xml  = [xml](New-LaunchdPlistText -Label 'l' -PwshPath '/p/pwsh' -ScriptPath '/s/grongoMonitor.ps1')
        $Args = @($Xml.SelectNodes('/plist/dict/array/string') | ForEach-Object { $_.InnerText })

        $Args | Should -Be @('/p/pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', '/s/grongoMonitor.ps1')
    }

    It 'XML-escapes special characters in paths' {
        $Text = New-LaunchdPlistText -Label 'l' -PwshPath '/p/pwsh' -ScriptPath "/s/a&b <c> 'd'/grongoMonitor.ps1"

        { [xml]$Text } | Should -Not -Throw
        $Args = @(([xml]$Text).SelectNodes('/plist/dict/array/string') | ForEach-Object { $_.InnerText })
        $Args[-1] | Should -Be "/s/a&b <c> 'd'/grongoMonitor.ps1"
    }

    It 'sets HOME for the daemon' {
        $Text = New-LaunchdPlistText -Label 'l' -PwshPath '/p' -ScriptPath '/s' -ServiceHome '/var/root'

        $Text | Should -Match '<key>HOME</key>\s*<string>/var/root</string>'
    }
}

Describe 'New-WindowsTaskArguments' {

    It 'sets HOME then runs the script' {
        $Args = New-WindowsTaskArguments -ScriptPath 'C:\Program Files\grongoMonitor\grongoMonitor.ps1' `
            -ServiceHome 'C:\Windows\System32\config\systemprofile'

        $Args | Should -Match '^-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "'
        $Args | Should -Match ([regex]::Escape("`$env:HOME='C:\Windows\System32\config\systemprofile'"))
        $Args | Should -Match ([regex]::Escape("& 'C:\Program Files\grongoMonitor\grongoMonitor.ps1'"))
    }

    It "doubles single quotes so a path such as C:\O'Brien is safe" {
        $Args = New-WindowsTaskArguments -ScriptPath "C:\O'Brien\grongoMonitor.ps1" -ServiceHome 'C:\h'

        $Args | Should -Match ([regex]::Escape("& 'C:\O''Brien\grongoMonitor.ps1'"))
    }

    It 'the -Command payload is valid PowerShell' {
        $Args = New-WindowsTaskArguments -ScriptPath "C:\O'Brien\grongoMonitor.ps1" -ServiceHome "C:\h'x"
        $Payload = ($Args -replace '^.*-Command "', '') -replace '"$', ''

        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Payload, [ref]$null, [ref]$Errors)
        @($Errors).Count | Should -Be 0
    }
}

Describe 'Test-MonitorScriptSyntax' {

    It 'accepts the real monitor script' {
        @(Test-MonitorScriptSyntax -Path $Script:MonitorScript).Count | Should -Be 0
    }

    It 'reports parse errors with a line number and does not run the file' {
        $Bad = Join-Path ([System.IO.Path]::GetTempPath()) "bad-$([guid]::NewGuid().ToString('N')).ps1"
        $Marker = "$Bad.ran"
        Set-Content -LiteralPath $Bad -Value "Set-Content '$Marker' 'x'`nfunction Broken { if ( `n"

        try {
            $Errors = @(Test-MonitorScriptSyntax -Path $Bad)

            $Errors.Count | Should -BeGreaterThan 0
            $Errors[0] | Should -Match 'line \d+'
            Test-Path -LiteralPath $Marker | Should -BeFalse
        }
        finally { Remove-Item $Bad, $Marker -ErrorAction SilentlyContinue }
    }

    It 'reports a missing file' {
        @(Test-MonitorScriptSyntax -Path '/no/such/file.ps1')[0] | Should -Match 'not found'
    }
}

Describe 'Get-MonitorScriptVersion' {

    It 'reads the version from the real script' {
        Get-MonitorScriptVersion -Path $Script:MonitorScript | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'matches the version the script reports at runtime' {
        . $Script:MonitorScript -LogPath (Join-Path ([System.IO.Path]::GetTempPath()) 'x.log')
        Get-MonitorScriptVersion -Path $Script:MonitorScript | Should -Be $Script:GrongoMonitorVersion
    }

    It 'returns $null when there is no version constant or no file' {
        $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "v-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $Tmp -Value 'Write-Host hi'
        try { Get-MonitorScriptVersion -Path $Tmp | Should -BeNullOrEmpty }
        finally { Remove-Item $Tmp -ErrorAction SilentlyContinue }

        Get-MonitorScriptVersion -Path '/no/such' | Should -BeNullOrEmpty
    }
}

Describe 'Test-EventServerUrl' {

    It 'accepts <Url>' -TestCases @(
        @{ Url = 'https://events.example.com' }
        @{ Url = 'http://10.0.0.5:8080' }
        @{ Url = 'https://host/prefix' }
        @{ Url = ' https://events.example.com ' }
    ) { Test-EventServerUrl $Url | Should -BeTrue }

    It 'rejects <Url>' -TestCases @(
        @{ Url = $null }
        @{ Url = '' }
        @{ Url = 'events.example.com' }
        @{ Url = 'ftp://events.example.com' }
        @{ Url = 'https://' }
        @{ Url = 'not a url' }
    ) { Test-EventServerUrl $Url | Should -BeFalse }
}

Describe 'Test-SafeInstallDirectory' -Skip:$isWindows {

    It 'accepts <Path>' -TestCases @(
        @{ Path = '/opt/grongoMonitor' }
        @{ Path = '/opt/grongoMonitor/' }
        @{ Path = '/usr/local/lib/grongoMonitor' }
        @{ Path = '/srv/grongo' }
        @{ Path = '/tmp/some-test-dir' }
    ) { Test-SafeInstallDirectory $Path | Should -BeTrue }

    It 'rejects <Path>' -TestCases @(
        @{ Path = '/' }
        @{ Path = '/opt' }
        @{ Path = '/usr' }
        @{ Path = '/etc' }
        @{ Path = '/root' }
        @{ Path = '/home' }
        @{ Path = '/tmp' }
        @{ Path = '' }
        @{ Path = $null }
        @{ Path = 'relative/dir' }
        @{ Path = './here' }
        @{ Path = '/opt/grongoMonitor/../..' }
        @{ Path = '/opt/x/../../..' }
    ) { Test-SafeInstallDirectory $Path | Should -BeFalse }

    It 'rejects the current user home directory' {
        Test-SafeInstallDirectory $HOME | Should -BeFalse
    }
}

Describe 'Get-InstallerJsonProperty' {

    It 'is safe for $null, scalars, arrays and missing keys under StrictMode' -TestCases @(
        @{ Json = 'null' }, @{ Json = '5' }, @{ Json = '"s"' }, @{ Json = '[1,2]' }, @{ Json = '{}' }
    ) {
        $Parsed = $Json | ConvertFrom-Json
        { Get-InstallerJsonProperty $Parsed 'x' } | Should -Not -Throw
        Get-InstallerJsonProperty $Parsed 'x' | Should -BeNullOrEmpty
    }

    It 'returns a present value' {
        Get-InstallerJsonProperty ('{"batchSize":75}' | ConvertFrom-Json) 'batchSize' | Should -Be 75
    }
}
