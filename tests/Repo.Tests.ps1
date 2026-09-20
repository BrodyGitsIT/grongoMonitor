#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.3.0' }

# Repository hygiene: things that rot silently if nothing checks them.

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $Script:PowerShellFiles = @(
        Get-ChildItem -LiteralPath $Script:RepoRoot -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|testResults)[\\/]' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($Script:RepoRoot.Length + 1); Path = $_.FullName } }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1')

    $script:MonitorText = Get-Content -LiteralPath $Script:MonitorScript -Raw
    $script:Docs = @('README.md', 'docs/CONFIGURATION.md', 'docs/DEPLOYMENT.md') |
        ForEach-Object { Join-Path $Script:RepoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
}

Describe 'PowerShell sources' {

    It '<Name> parses without errors' -TestCases $Script:PowerShellFiles {
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$Errors)

        @($Errors).Count | Should -Be 0
    }

    It '<Name> uses LF line endings (a CRLF shebang script fails on Linux)' -TestCases $Script:PowerShellFiles {
        [System.IO.File]::ReadAllText($Path) | Should -Not -Match "`r"
    }

    It '<Name> has no UTF-8 BOM' -TestCases $Script:PowerShellFiles {
        $Bytes = [System.IO.File]::ReadAllBytes($Path)
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'the two entry-point scripts start with a pwsh shebang' -TestCases @(
        @{ Path = $Script:MonitorScript }, @{ Path = $Script:InstallScript }
    ) {
        (Get-Content -LiteralPath $Path -TotalCount 1) | Should -Be '#!/usr/bin/env pwsh'
    }

    It 'both entry-point scripts are dot-source safe (guard present)' -TestCases @(
        @{ Path = $Script:MonitorScript }, @{ Path = $Script:InstallScript }
    ) {
        (Get-Content -LiteralPath $Path -Raw) | Should -Match "if \(\`$MyInvocation\.InvocationName -eq '\.'\) \{\s*return\s*\}"
    }
}

Describe 'Documented events match the code' {

    BeforeAll {
        $script:Emitted  = @([regex]::Matches($script:MonitorText, '(?m)^#\s+EMITTED:(.*)$') | ForEach-Object { $_.Groups[1].Value -split '\s+' } | Where-Object { $_ } | Sort-Object -Unique)
        $script:Reserved = @([regex]::Matches($script:MonitorText, '(?m)^#\s+RESERVED:(.*)$') | ForEach-Object { $_.Groups[1].Value -split '\s+' } | Where-Object { $_ } | Sort-Object -Unique)
        $script:InCode   = @([regex]::Matches($script:MonitorText, '-Event\s+"([A-Z_]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }

    It 'the header lists emitted events' {
        $script:Emitted.Count | Should -BeGreaterThan 10
    }

    It 'every event the code can emit is documented in the header' {
        $Undocumented = @($script:InCode | Where-Object { $_ -notin $script:Emitted })
        $Undocumented | Should -Be @()
    }

    It 'every event the header says is emitted really is emitted' {
        $Phantom = @($script:Emitted | Where-Object { $_ -notin $script:InCode })
        $Phantom | Should -Be @()
    }

    It 'reserved (not yet emitted) events are not emitted anywhere' {
        @($script:Reserved | Where-Object { $_ -in $script:InCode }) | Should -Be @()
    }
}

Describe 'Versioning' {

    It 'CHANGELOG.md has an entry for the current script version' {
        $Version = [regex]::Match($script:MonitorText, "GrongoMonitorVersion\s*=\s*'([^']+)'").Groups[1].Value

        $Changelog = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'CHANGELOG.md') -Raw
        $Changelog | Should -Match "(?m)^## \[$([regex]::Escape($Version))\]"
    }

    It 'the newest CHANGELOG entry is the current version (bump both together)' {
        $Version   = [regex]::Match($script:MonitorText, "GrongoMonitorVersion\s*=\s*'([^']+)'").Groups[1].Value
        $Changelog = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'CHANGELOG.md') -Raw
        $Newest    = [regex]::Match($Changelog, '(?m)^## \[(\d+\.\d+\.\d+)\]').Groups[1].Value

        $Newest | Should -Be $Version
    }
}

Describe 'Nothing personal is baked in (this is meant to be deployed by other people)' {

    It 'no script, doc or test defaults to the author''s own server' {
        $Files = @($Script:MonitorScript, $Script:InstallScript) + $script:Docs

        foreach ($File in $Files) {
            (Get-Content -LiteralPath $File -Raw) | Should -Not -Match 'grongo\.dev' -Because "$File must not point people at someone else's server"
        }
    }

    It 'no script contains a hard-coded home directory other than the platform service homes' {
        foreach ($File in @($Script:MonitorScript, $Script:InstallScript)) {
            (Get-Content -LiteralPath $File -Raw) | Should -Not -Match '/home/[a-z]+' -Because "$File must not contain a specific user's home"
        }
    }
}

Describe 'Documentation' {

    It 'documents every GRONGO_EVENT_* environment variable the code reads' {
        $Vars = @([regex]::Matches($script:MonitorText, 'GRONGO_EVENT_[A-Z_]+') | ForEach-Object Value | Sort-Object -Unique)
        $Config = Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'docs/CONFIGURATION.md') -Raw

        foreach ($Var in $Vars) { $Config | Should -Match $Var }
    }

    It 'documents every installer parameter' {
        $Parameters = @((Get-Command $Script:InstallScript).Parameters.Keys | Where-Object {
            $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters -and
            $_ -notin [System.Management.Automation.PSCmdlet]::OptionalCommonParameters })
        $Text = (Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'README.md') -Raw) + (Get-Content -LiteralPath (Join-Path $Script:RepoRoot 'docs/DEPLOYMENT.md') -Raw)

        foreach ($Parameter in $Parameters) { $Text | Should -Match "-$Parameter\b" -Because "-$Parameter should appear in README or DEPLOYMENT" }
    }

    It 'does not mention the retired -EventToken installer parameter or "sudo -H"' {
        foreach ($File in $script:Docs) {
            $Text = Get-Content -LiteralPath $File -Raw
            $Text | Should -Not -Match '-EventToken(\s|$)'
            $Text | Should -Not -Match 'sudo -H'
        }
    }

    It 'the CI workflow runs the test runner' {
        (Get-Content -LiteralPath (Join-Path $Script:RepoRoot '.github/workflows/ci.yml') -Raw) | Should -Match 'Invoke-Tests\.ps1'
    }

    It '.gitattributes forces LF for PowerShell files' {
        (Get-Content -LiteralPath (Join-Path $Script:RepoRoot '.gitattributes') -Raw) | Should -Match '\*\.ps1\s+text eol=lf'
    }

    It 'the PSScriptAnalyzer settings file is valid' {
        { Import-PowerShellDataFile -LiteralPath (Join-Path $Script:RepoRoot 'PSScriptAnalyzerSettings.psd1') } | Should -Not -Throw
    }
}
