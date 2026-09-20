#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the grongoMonitor Pester suite.

.DESCRIPTION
    Requires Pester 5.3 or newer (Windows PowerShell's bundled Pester 3.x will not work):

        Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck

.PARAMETER Path
    A test file or directory. Default: this directory.

.PARAMETER SkipIntegration
    Skips Monitor.Integration.Tests.ps1 (spawns real processes; ~40 s; POSIX only).

.PARAMETER CI
    Writes NUnit results to ./testResults.xml and exits non-zero on any failure.

.PARAMETER Coverage
    Writes JaCoCo coverage for the two scripts to ./coverage.xml.

.EXAMPLE
    ./tests/Invoke-Tests.ps1
    ./tests/Invoke-Tests.ps1 -SkipIntegration
    ./tests/Invoke-Tests.ps1 -Path ./tests/Monitor.Docker.Tests.ps1 -Detailed
#>
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot,
    [switch]$SkipIntegration,
    [switch]$CI,
    [switch]$Coverage,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

$Pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1

if ($null -eq $Pester -or $Pester.Version -lt [version]'5.3.0') {
    throw "Pester 5.3+ is required (found: $(if ($Pester) { $Pester.Version } else { 'none' })). Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck"
}

Import-Module Pester -MinimumVersion 5.3.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$Configuration = New-PesterConfiguration
$Configuration.Run.Path     = $Path
$Configuration.Run.PassThru = $true
$Configuration.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }

if ($SkipIntegration) {
    $Configuration.Run.ExcludePath = @('*Integration*')
}

if ($CI) {
    $Configuration.TestResult.Enabled      = $true
    $Configuration.TestResult.OutputPath   = Join-Path $RepoRoot 'testResults.xml'
    $Configuration.TestResult.OutputFormat = 'NUnitXml'
}

if ($Coverage) {
    $Configuration.CodeCoverage.Enabled    = $true
    $Configuration.CodeCoverage.Path       = @((Join-Path $RepoRoot 'grongoMonitor.ps1'), (Join-Path $RepoRoot 'Install-GrongoMonitor.ps1'))
    $Configuration.CodeCoverage.OutputPath = Join-Path $RepoRoot 'coverage.xml'
}

$Result = Invoke-Pester -Configuration $Configuration

if ($CI -or $Result.FailedCount -gt 0) {
    exit ([int]($Result.FailedCount -gt 0))
}
