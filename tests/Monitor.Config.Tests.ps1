#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $Script:HasDe = Test-CultureAvailable 'de-DE'
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:Root = New-TestRoot
    $MonitorParams = Get-MonitorParameters -Root $script:Root
    . $Script:MonitorScript @MonitorParams

    $script:EnvNames = @(
        'GRONGO_EVENT_SERVER', 'GRONGO_EVENT_TOKEN', 'GRONGO_EVENT_BATCH_SIZE',
        'GRONGO_EVENT_INTERVAL', 'GRONGO_EVENT_MAX_BACKOFF_SECONDS'
    )
}

AfterAll {
    foreach ($EnvName in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($EnvName, $null) }
    Remove-TestRoot $script:Root
}

Describe 'Get-JsonPropertyOrNull' {

    It 'returns $null for a $null object' {
        Get-JsonPropertyOrNull $null 'x' | Should -BeNullOrEmpty
    }

    It 'returns $null (not an exception) for a missing property under StrictMode' {
        $Object = '{"a":1}' | ConvertFrom-Json
        { Get-JsonPropertyOrNull $Object 'missing' } | Should -Not -Throw
        Get-JsonPropertyOrNull $Object 'missing' | Should -BeNullOrEmpty
    }

    It 'returns the value of a present property' {
        Get-JsonPropertyOrNull ('{"a":"hello"}' | ConvertFrom-Json) 'a' | Should -Be 'hello'
    }

    It 'matches property names case-insensitively (like PowerShell itself)' {
        Get-JsonPropertyOrNull ('{"EVENT_ID":"x"}' | ConvertFrom-Json) 'event_id' | Should -Be 'x'
    }

    It 'preserves falsy values instead of treating them as missing' -TestCases @(
        @{ Json = '{"a":0}';     Expected = 0 }
        @{ Json = '{"a":false}'; Expected = $false }
        @{ Json = '{"a":""}';    Expected = '' }
    ) {
        Get-JsonPropertyOrNull ($Json | ConvertFrom-Json) 'a' | Should -Be $Expected
    }

    It 'returns $null for a property that is explicitly null' {
        Get-JsonPropertyOrNull ('{"a":null}' | ConvertFrom-Json) 'a' | Should -BeNullOrEmpty
    }

    It 'does not throw when the "object" is a scalar or an array' -TestCases @(
        @{ Json = '5' }
        @{ Json = '"a string"' }
        @{ Json = '[1,2,3]' }
        @{ Json = 'true' }
    ) {
        { Get-JsonPropertyOrNull ($Json | ConvertFrom-Json) 'server' } | Should -Not -Throw
        Get-JsonPropertyOrNull ($Json | ConvertFrom-Json) 'server' | Should -BeNullOrEmpty
    }

    It 'reads nested values one hop at a time' {
        $Object = '{"Actor":{"Attributes":{"name":"web"}}}' | ConvertFrom-Json
        $Attributes = Get-JsonPropertyOrNull (Get-JsonPropertyOrNull $Object 'Actor') 'Attributes'
        Get-JsonPropertyOrNull $Attributes 'name' | Should -Be 'web'
    }
}

Describe 'ConvertTo-DateTimeOffsetOrNull' {

    It 'returns $null for $null, empty and whitespace' -TestCases @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = '   ' }
    ) {
        ConvertTo-DateTimeOffsetOrNull $Value | Should -BeNullOrEmpty
    }

    It 'returns $null for garbage' -TestCases @(
        @{ Value = 'not a date' }
        @{ Value = '2026-13-45T99:99:99' }
        @{ Value = '{}' }
    ) {
        ConvertTo-DateTimeOffsetOrNull $Value | Should -BeNullOrEmpty
    }

    It 'passes a DateTimeOffset through unchanged' {
        $Value = [DateTimeOffset]'2026-09-13T08:10:15.5000000-05:00'
        (ConvertTo-DateTimeOffsetOrNull $Value) | Should -Be $Value
    }

    It 'converts a [DateTime] (what ConvertFrom-Json produces) without losing sub-second precision' {
        $Original = [DateTimeOffset]'2026-09-13T08:10:15.5000000-05:00'
        $FromJson = ($Original.ToString('o') | ConvertTo-Json | ConvertFrom-Json)

        $Result = ConvertTo-DateTimeOffsetOrNull $FromJson

        $Result | Should -Be $Original
    }

    It 'parses an ISO-8601 round-trip string and keeps the offset instant' {
        $Result = ConvertTo-DateTimeOffsetOrNull '2026-09-13T08:10:15.5000000-05:00'
        $Result.UtcDateTime | Should -Be ([DateTime]::new(2026, 9, 13, 13, 10, 15, 500, [DateTimeKind]::Utc))
    }

    It 'parses identically under a de-DE culture (no culture round trip)' -Skip:(-not $Script:HasDe) {
        $Result = Use-Culture 'de-DE' { ConvertTo-DateTimeOffsetOrNull '2026-09-13T08:10:15.5000000-05:00' }
        $Result.UtcDateTime.Hour | Should -Be 13
    }
}

Describe 'Resolve-StringSetting' {

    It 'prefers the parameter over env and file' {
        $env:GRONGO_EVENT_SERVER = 'https://env'
        Resolve-StringSetting -ParamValue 'https://param' -EnvName 'GRONGO_EVENT_SERVER' -FileValue 'https://file' -DefaultValue 'd' |
            Should -Be 'https://param'
    }

    It 'prefers env over file' {
        $env:GRONGO_EVENT_SERVER = 'https://env'
        Resolve-StringSetting -ParamValue '' -EnvName 'GRONGO_EVENT_SERVER' -FileValue 'https://file' -DefaultValue 'd' |
            Should -Be 'https://env'
    }

    It 'prefers file over the default' {
        $env:GRONGO_EVENT_SERVER = $null
        Resolve-StringSetting -ParamValue '' -EnvName 'GRONGO_EVENT_SERVER' -FileValue 'https://file' -DefaultValue 'd' |
            Should -Be 'https://file'
    }

    It 'falls back to the default' {
        $env:GRONGO_EVENT_SERVER = $null
        Resolve-StringSetting -ParamValue '' -EnvName 'GRONGO_EVENT_SERVER' -FileValue $null -DefaultValue 'dflt' |
            Should -Be 'dflt'
    }

    It 'treats whitespace-only values at every level as unset' {
        $env:GRONGO_EVENT_SERVER = '   '
        Resolve-StringSetting -ParamValue '  ' -EnvName 'GRONGO_EVENT_SERVER' -FileValue "`t" -DefaultValue 'dflt' |
            Should -Be 'dflt'
    }

    AfterEach { $env:GRONGO_EVENT_SERVER = $null }
}

Describe 'Resolve-IntSetting' {

    BeforeEach { $env:GRONGO_EVENT_BATCH_SIZE = $null }
    AfterEach  { $env:GRONGO_EVENT_BATCH_SIZE = $null }

    It 'prefers a positive parameter' {
        $env:GRONGO_EVENT_BATCH_SIZE = '7'
        Resolve-IntSetting -ParamValue 9 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 9
    }

    It 'treats a 0 parameter as "not specified"' {
        $env:GRONGO_EVENT_BATCH_SIZE = '7'
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 7
    }

    It 'treats a negative parameter as "not specified"' {
        Resolve-IntSetting -ParamValue -5 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 8
    }

    It 'prefers env over file, then file over default' {
        $env:GRONGO_EVENT_BATCH_SIZE = '7'
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 7
        $env:GRONGO_EVENT_BATCH_SIZE = $null
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 8
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue $null -DefaultValue 50 | Should -Be 50
    }

    It 'skips an invalid env value and continues down the chain' -TestCases @(
        @{ Bad = 'abc' }
        @{ Bad = '0' }
        @{ Bad = '-3' }
        @{ Bad = '12.5' }
        @{ Bad = '99999999999' }
        @{ Bad = '1e3' }
        @{ Bad = '' }
    ) {
        $env:GRONGO_EVENT_BATCH_SIZE = $Bad
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue 8 -DefaultValue 50 | Should -Be 8
    }

    It 'accepts an env value with surrounding whitespace' {
        $env:GRONGO_EVENT_BATCH_SIZE = ' 25 '
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue $null -DefaultValue 50 | Should -Be 25
    }

    It 'skips an invalid file value and falls to the default' -TestCases @(
        @{ Bad = 'abc' }
        @{ Bad = 0 }
        @{ Bad = -1 }
        @{ Bad = 12.5 }
        @{ Bad = $true }
        @{ Bad = @(1, 2) }
    ) {
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue $Bad -DefaultValue 50 | Should -Be 50
    }

    It 'accepts a numeric string from config.json' {
        Resolve-IntSetting -ParamValue 0 -EnvName 'GRONGO_EVENT_BATCH_SIZE' -FileValue '75' -DefaultValue 50 | Should -Be 75
    }
}

Describe 'Test-ForwarderServerUrl' {

    It 'accepts <Url>' -TestCases @(
        @{ Url = 'https://events.example.com' }
        @{ Url = 'https://events.example.com/' }
        @{ Url = 'http://10.0.0.5:8080' }
        @{ Url = 'https://host/prefix/path' }
        @{ Url = 'HTTPS://EVENTS.EXAMPLE.COM' }
        @{ Url = '  https://events.example.com  ' }
    ) {
        Test-ForwarderServerUrl -Url $Url | Should -BeTrue
    }

    It 'rejects <Url>' -TestCases @(
        @{ Url = $null }
        @{ Url = '' }
        @{ Url = '   ' }
        @{ Url = 'events.example.com' }
        @{ Url = 'events.example.com:8080' }
        @{ Url = 'ftp://events.example.com' }
        @{ Url = 'file:///etc/passwd' }
        @{ Url = 'https://' }
        @{ Url = '//events.example.com' }
        @{ Url = 'not a url' }
    ) {
        Test-ForwarderServerUrl -Url $Url | Should -BeFalse
    }
}

Describe 'Get-EventForwarderConfig' {

    BeforeEach {
        Reset-TestRoot $script:Root
        foreach ($EnvName in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($EnvName, $null) }
    }

    It 'returns defaults and no server when nothing is configured' {
        $Config = Get-EventForwarderConfig

        $Config.ServerUrl         | Should -BeNullOrEmpty
        $Config.Token             | Should -BeNullOrEmpty
        $Config.BatchSize         | Should -Be 50
        $Config.IntervalSeconds   | Should -Be 30
        $Config.MaxBackoffSeconds | Should -Be 900
    }

    It 'reads every key from config.json' {
        Set-Content -LiteralPath $EventConfigPath -Value '{"server":"https://a.example","batchSize":75,"intervalSeconds":45,"maxBackoffSeconds":120}'

        $Config = Get-EventForwarderConfig

        $Config.ServerUrl         | Should -Be 'https://a.example'
        $Config.BatchSize         | Should -Be 75
        $Config.IntervalSeconds   | Should -Be 45
        $Config.MaxBackoffSeconds | Should -Be 120
    }

    It 'accepts a partial config.json and defaults the rest' {
        Set-Content -LiteralPath $EventConfigPath -Value '{"server":"https://a.example"}'

        $Config = Get-EventForwarderConfig

        $Config.ServerUrl | Should -Be 'https://a.example'
        $Config.BatchSize | Should -Be 50
    }

    It 'lets environment variables override config.json' {
        Set-Content -LiteralPath $EventConfigPath -Value '{"server":"https://file","batchSize":10}'
        $env:GRONGO_EVENT_SERVER     = 'https://env'
        $env:GRONGO_EVENT_BATCH_SIZE = '20'

        $Config = Get-EventForwarderConfig

        $Config.ServerUrl | Should -Be 'https://env'
        $Config.BatchSize | Should -Be 20
    }

    It 'lets explicit parameters override environment variables' {
        $env:GRONGO_EVENT_SERVER = 'https://env'
        $EventServer      = 'https://param'
        $EventBatchSize   = 5
        $EventIntervalSeconds = 9

        $Config = Get-EventForwarderConfig

        $Config.ServerUrl       | Should -Be 'https://param'
        $Config.BatchSize       | Should -Be 5
        $Config.IntervalSeconds | Should -Be 9
    }

    It 'honours GRONGO_EVENT_MAX_BACKOFF_SECONDS' {
        $env:GRONGO_EVENT_MAX_BACKOFF_SECONDS = '60'
        (Get-EventForwarderConfig).MaxBackoffSeconds | Should -Be 60
    }

    It 'trims whitespace around the server URL' {
        $env:GRONGO_EVENT_SERVER = "  https://a.example/ `n"
        (Get-EventForwarderConfig).ServerUrl | Should -Be 'https://a.example/'
    }

    It 'ignores a config.json that is <Case>' -TestCases @(
        @{ Case = 'invalid JSON';        Content = '{ this is not json' }
        @{ Case = 'empty';               Content = '' }
        @{ Case = 'a JSON array';        Content = '[1,2,3]' }
        @{ Case = 'a JSON string';       Content = '"hello"' }
        @{ Case = 'a JSON number';       Content = '5' }
        @{ Case = 'JSON null';           Content = 'null' }
        @{ Case = 'truncated mid-write'; Content = '{"server":"https://a.exam' }
    ) {
        Set-Content -LiteralPath $EventConfigPath -Value $Content -NoNewline

        { Get-EventForwarderConfig } | Should -Not -Throw

        $Config = Get-EventForwarderConfig
        $Config.ServerUrl | Should -BeNullOrEmpty
        $Config.BatchSize | Should -Be 50
    }

    It 'survives wrong-typed values in config.json' {
        Set-Content -LiteralPath $EventConfigPath -Value '{"server":123,"batchSize":"lots","intervalSeconds":[1,2],"maxBackoffSeconds":null}'

        { Get-EventForwarderConfig } | Should -Not -Throw

        $Config = Get-EventForwarderConfig
        $Config.BatchSize         | Should -Be 50
        $Config.IntervalSeconds   | Should -Be 30
        $Config.MaxBackoffSeconds | Should -Be 900
    }

    Context 'token' {

        It 'comes from the environment variable' {
            $env:GRONGO_EVENT_TOKEN = 'env-token'
            (Get-EventForwarderConfig).Token | Should -Be 'env-token'
        }

        It 'comes from the token file when the env var is unset' {
            Set-Content -LiteralPath $EventTokenPath -Value 'file-token'
            (Get-EventForwarderConfig).Token | Should -Be 'file-token'
        }

        It 'prefers the env var over the token file' {
            Set-Content -LiteralPath $EventTokenPath -Value 'file-token'
            $env:GRONGO_EVENT_TOKEN = 'env-token'
            (Get-EventForwarderConfig).Token | Should -Be 'env-token'
        }

        It 'trims a trailing newline / CRLF from the token file' -TestCases @(
            @{ Suffix = "`n" }
            @{ Suffix = "`r`n" }
            @{ Suffix = "  `n`n" }
        ) {
            Set-Content -LiteralPath $EventTokenPath -Value "abc123$Suffix" -NoNewline
            (Get-EventForwarderConfig).Token | Should -Be 'abc123'
        }

        It 'trims whitespace from the env var too (a stray newline would break the header)' {
            $env:GRONGO_EVENT_TOKEN = "abc123`n"
            (Get-EventForwarderConfig).Token | Should -Be 'abc123'
        }

        It 'yields an empty token for an empty token file' {
            Set-Content -LiteralPath $EventTokenPath -Value '' -NoNewline
            (Get-EventForwarderConfig).Token | Should -BeNullOrEmpty
        }

        It 'never reads the token from config.json' {
            Set-Content -LiteralPath $EventConfigPath -Value '{"server":"https://a.example","token":"leaked"}'
            (Get-EventForwarderConfig).Token | Should -BeNullOrEmpty
        }
    }
}

Describe 'Initialize-Forwarder' {

    BeforeEach {
        Reset-TestRoot $script:Root
        foreach ($EnvName in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($EnvName, $null) }
        $Script:ForwardingEnabled     = $false
        $Script:ForwarderConfig       = $null
        $Script:SuppressOutboxOnError = $false
    }

    It 'stays disabled (and adds zero overhead) when no server is configured anywhere' {
        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeFalse
        @(Get-EventNames $LogPath).Count | Should -Be 0
    }

    It 'enables forwarding for a server from an explicit parameter' {
        $EventServer = 'https://a.example'
        $env:GRONGO_EVENT_TOKEN = 't'

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeTrue
        $Script:ForwarderConfig.ServerUrl | Should -Be 'https://a.example'
    }

    It 'enables forwarding for a server from the environment' {
        $env:GRONGO_EVENT_SERVER = 'https://a.example'
        $env:GRONGO_EVENT_TOKEN  = 't'

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeTrue
    }

    It 'enables forwarding for a server from config.json' {
        Set-Content -LiteralPath $EventConfigPath -Value '{"server":"https://a.example"}'
        $env:GRONGO_EVENT_TOKEN = 't'

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeTrue
    }

    It '-NoForward wins even when a server is configured' {
        $env:GRONGO_EVENT_SERVER = 'https://a.example'
        $NoForward = [switch]$true

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeFalse
    }

    It 'warns once via SERVICE_ERROR (but stays enabled) when there is no token' {
        $env:GRONGO_EVENT_SERVER = 'https://a.example'

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeTrue

        $Errors = @(Read-EventLogRecords $LogPath | Where-Object Event -eq 'SERVICE_ERROR')
        $Errors.Count | Should -Be 1
        $Errors[0].Data['COMPONENT'] | Should -Be 'EventForwarder'
        $Errors[0].Data['MESSAGE']   | Should -Match 'no token'
    }

    It 'does not warn when a token is present' {
        $env:GRONGO_EVENT_SERVER = 'https://a.example'
        $env:GRONGO_EVENT_TOKEN  = 't'

        Initialize-Forwarder

        @(Get-EventNames $LogPath).Count | Should -Be 0
    }

    It 'fails closed to local-only, and says so, for an invalid server URL: <Url>' -TestCases @(
        @{ Url = 'events.example.com' }
        @{ Url = 'ftp://events.example.com' }
        @{ Url = 'https://' }
    ) {
        $env:GRONGO_EVENT_SERVER = $Url
        $env:GRONGO_EVENT_TOKEN  = 't'

        Initialize-Forwarder

        $Script:ForwardingEnabled | Should -BeFalse

        $Errors = @(Read-EventLogRecords $LogPath | Where-Object Event -eq 'SERVICE_ERROR')
        $Errors.Count | Should -Be 1
        $Errors[0].Data['MESSAGE'] | Should -Match 'not an absolute http'
    }

    It 'does not enqueue the invalid-URL error into the outbox (forwarding is off)' {
        $env:GRONGO_EVENT_SERVER = 'nonsense'
        Initialize-Forwarder

        @(Get-OutboxFiles $OutboxPath).Count | Should -Be 0
    }

    It 'leaves the monitor running local-only if configuration blows up' {
        $env:GRONGO_EVENT_SERVER = 'https://a.example'
        Mock Get-EventForwarderConfig { throw 'boom' }

        { Initialize-Forwarder } | Should -Not -Throw
        $Script:ForwardingEnabled | Should -BeFalse
    }

    It 'creates the forwarder log directory if it is missing' {
        $ForwarderLogPath = Join-Path $script:Root 'sub/dir/grongoMonitor.log'
        $env:GRONGO_EVENT_SERVER = 'https://a.example'
        $env:GRONGO_EVENT_TOKEN  = 't'

        Initialize-Forwarder

        Test-Path -LiteralPath (Join-Path $script:Root 'sub/dir') | Should -BeTrue
    }
}

Describe 'Initialize-MonitorEnvironment' {

    BeforeEach { Reset-TestRoot $script:Root }

    It 'creates the log directory, state directory and outbox' {
        $LogPath    = Join-Path $script:Root 'a/logs/events.log'
        $StatePath  = Join-Path $script:Root 'b/state/state.json'
        $OutboxPath = Join-Path $script:Root 'c/outbox'

        Initialize-MonitorEnvironment

        Test-Path -LiteralPath (Join-Path $script:Root 'a/logs')  | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'b/state') | Should -BeTrue
        Test-Path -LiteralPath $OutboxPath                        | Should -BeTrue
    }

    It 'is idempotent' {
        Initialize-MonitorEnvironment
        { Initialize-MonitorEnvironment } | Should -Not -Throw
    }

    It 'tolerates bare filenames with no parent directory' {
        $LogPath   = 'events.log'
        $StatePath = 'state.json'

        { Initialize-MonitorEnvironment } | Should -Not -Throw
    }
}
