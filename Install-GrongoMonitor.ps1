#!/usr/bin/env pwsh

# ============================================================
# grongoMonitor installer
# PowerShell 7+
#
# Installs grongoMonitor.ps1 as a native background service for the
# current operating system:
#
#   Windows -> Task Scheduler startup task (runs as SYSTEM)
#   Linux   -> systemd unit                 (runs as root)
#   macOS   -> launchd daemon               (runs as root)
#
# Typical use (from a git checkout):
#
#   Install:      sudo pwsh ./Install-GrongoMonitor.ps1
#   Update:       git pull && sudo pwsh ./Install-GrongoMonitor.ps1 -Reinstall
#   Uninstall:    sudo pwsh ./Install-GrongoMonitor.ps1 -Uninstall
#
# Install with central event forwarding:
#
#   sudo pwsh ./Install-GrongoMonitor.ps1 `
#       -EventServer https://events.example.com
#       (prompts for the bearer token as a SecureString)
#
#   Unattended (Ansible, cloud-init, ...): supply the token from a file
#   (or from $env:GRONGO_EVENT_TOKEN). It is never a command-line value.
#
#   sudo pwsh ./Install-GrongoMonitor.ps1 `
#       -EventServer https://events.example.com `
#       -EventTokenFile /run/secrets/grongo-token
#
# What gets installed where:
#
#   The monitor script is COPIED to a root/admin-owned install directory
#   (default: /opt/grongoMonitor, /usr/local/lib/grongoMonitor, or
#   %ProgramFiles%\grongoMonitor) and the service runs that copy. The
#   service runs as root/SYSTEM, so it must never execute code from a
#   directory ordinary users can write to (a git checkout, a home dir).
#   Use -InPlace to run from the checkout anyway (development only).
#
#   Data (events.log, state.json, outbox, config.json, token) lives in
#   the service account's home: ~/.grongoMonitor for root / SYSTEM.
#
# Everything below is a function; dot-sourcing this file loads them
# without doing anything (that is how tests/Installer.*.Tests.ps1 work).
# ============================================================

[CmdletBinding()]
param(
    [switch]$Uninstall,

    # Replace an existing installation (also the way to apply an update
    # after `git pull`, or to change forwarding settings).
    [switch]$Reinstall,

    # With -Uninstall: also delete the data directory (events.log,
    # state.json, outbox, config, token). Without it, data is kept.
    [switch]$Purge,

    # ------------------------------------------------------------
    # Optional: central event forwarding.
    # Supplying any of these (or -ConfigureEventForwarding) writes
    # config.json + token for the service account.
    # ------------------------------------------------------------

    [string]$EventServer,

    [switch]$ConfigureEventForwarding,

    [ValidateRange(1, 10000)]
    [int]$EventBatchSize,

    [ValidateRange(1, 86400)]
    [int]$EventIntervalSeconds,

    # Read the bearer token from this file (single line) instead of
    # prompting. Order of precedence: -EventTokenFile, then
    # $env:GRONGO_EVENT_TOKEN, then an interactive SecureString prompt.
    [string]$EventTokenFile,

    # ------------------------------------------------------------
    # Where the service's copy of the monitor lives.
    # ------------------------------------------------------------

    [string]$InstallDir,

    # Run the service straight from this checkout instead of a copy.
    [switch]$InPlace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ServiceName       = 'grongoMonitor'
$Script:WindowsTaskName   = 'grongoMonitor'
$Script:MonitorScriptName = 'grongoMonitor.ps1'
$Script:ServiceDescription = 'Lightweight cross-platform system and Docker event monitor.'
$Script:InstallMarkerName = '.installed-by-grongoMonitor'

# ============================================================
# Platform and layout (pure; no side effects)
# ============================================================

function Get-InstallPlatform {
    $Windows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    $Linux   = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)
    $MacOS   = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

    if ($Windows) { return 'Windows' }
    if ($Linux)   { return 'Linux' }
    if ($MacOS)   { return 'macOS' }

    throw 'Unsupported operating system.'
}

function Join-LayoutPath {
    # Joins with the target platform's separator, so a Windows layout can be
    # computed (and tested) on any host. (Join-Path rejects "C:\..." on Linux.)
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Child,
        [Parameter(Mandatory)][string]$Platform
    )

    $Separator = if ($Platform -eq 'Windows') { '\' } else { '/' }

    return $Base.TrimEnd('/', '\') + $Separator + $Child
}

function Get-InstallLayout {
    # Everything the installer needs to know about paths, for one platform.
    # The overrides exist for tests and for unusual hosts.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'Linux', 'macOS')]
        [string]$Platform,

        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [string]$InstallDir,

        [switch]$InPlace,

        [string]$ServiceHome,
        [string]$SystemdDirectory = '/etc/systemd/system',
        [string]$LaunchdDirectory = '/Library/LaunchDaemons'
    )

    # The installed service runs under a fixed identity. Its configuration
    # lives in that identity's home, not the interactive installer's home.
    if ([string]::IsNullOrWhiteSpace($ServiceHome)) {

        $ServiceHome = switch ($Platform) {
            'Windows' {
                $WinDir = [System.Environment]::GetEnvironmentVariable('WINDIR')
                if ([string]::IsNullOrWhiteSpace($WinDir)) { $WinDir = 'C:\Windows' }
                Join-LayoutPath $WinDir 'System32\config\systemprofile' 'Windows'
            }
            'Linux' { '/root' }
            'macOS' { '/var/root' }
        }
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {

        $InstallDir = switch ($Platform) {
            'Windows' {
                $ProgramFiles = [System.Environment]::GetFolderPath('ProgramFiles')
                if ([string]::IsNullOrWhiteSpace($ProgramFiles)) { $ProgramFiles = 'C:\Program Files' }
                Join-LayoutPath $ProgramFiles 'grongoMonitor' 'Windows'
            }
            'Linux' { '/opt/grongoMonitor' }
            'macOS' { '/usr/local/lib/grongoMonitor' }
        }
    }

    $SourceScript = Join-Path $SourceDirectory $Script:MonitorScriptName   # the checkout is always on *this* host

    # Running the checkout in place, or "installing" over the checkout,
    # means there is nothing to copy.
    $SamePlace = $false
    try {
        $SamePlace = ([System.IO.Path]::GetFullPath($InstallDir).TrimEnd('/', '\') -eq
                      [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd('/', '\'))
    }
    catch { }

    $Staged = -not ($InPlace -or $SamePlace)

    $RunDirectory = if ($Staged) { $InstallDir } else { $SourceDirectory }

    $GrongoHome = Join-LayoutPath $ServiceHome '.grongoMonitor' $Platform

    return [pscustomobject]@{
        Platform         = $Platform
        ServiceName      = $Script:ServiceName
        TaskName         = $Script:WindowsTaskName
        Label            = "com.grongodev.$($Script:ServiceName)"
        ServiceHome      = $ServiceHome
        GrongoHome       = $GrongoHome
        ConfigPath       = Join-LayoutPath $GrongoHome 'config.json' $Platform
        TokenPath        = Join-LayoutPath $GrongoHome 'token' $Platform
        SourceDirectory  = $SourceDirectory
        SourceScript     = $SourceScript
        InstallDir       = $InstallDir
        Staged           = $Staged
        WorkingDirectory = $RunDirectory
        ScriptPath       = Join-LayoutPath $RunDirectory $Script:MonitorScriptName $Platform
        SystemdUnitPath  = Join-LayoutPath $SystemdDirectory "$($Script:ServiceName).service" $Platform
        LaunchdPlistPath = Join-LayoutPath $LaunchdDirectory "com.grongodev.$($Script:ServiceName).plist" $Platform
    }
}

# ============================================================
# Service definition text (pure)
# ============================================================

function ConvertTo-SystemdArgument {
    # Quotes/escapes one word of an ExecStart= line. Bare words are left
    # alone so the common case reads naturally; anything else is quoted.
    # systemd expands %specifiers and $VARIABLES inside ExecStart, so
    # literal % and $ are doubled.
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match "[\r\n]") {
        throw 'A path containing a newline cannot be used in a systemd unit.'
    }

    $Escaped = $Value.Replace('\', '\\').Replace('%', '%%').Replace('$', '$$')

    if ($Escaped -match '^[A-Za-z0-9_./:@+=,-]+$') {
        return $Escaped
    }

    return '"' + $Escaped.Replace('"', '\"') + '"'
}

function ConvertTo-SystemdPath {
    # WorkingDirectory= takes an unquoted path; only % needs escaping.
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match "[\r\n]") {
        throw 'A path containing a newline cannot be used in a systemd unit.'
    }

    return $Value.Replace('%', '%%')
}

function New-SystemdUnitText {
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$ServiceHome = '/root',
        [string]$Description = $Script:ServiceDescription
    )

    $ExecStart = @(
        (ConvertTo-SystemdArgument $PwshPath)
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-File'
        (ConvertTo-SystemdArgument $ScriptPath)
    ) -join ' '

    $HomeValue = ConvertTo-SystemdArgument $ServiceHome

    return @"
[Unit]
Description=$Description
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$(ConvertTo-SystemdPath $WorkingDirectory)
ExecStart=$ExecStart
Restart=always
RestartSec=5

# Keep HOME deterministic so the monitor and installer use the same
# configuration directory.
Environment=HOME=$ServiceHome
Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
Environment=POWERSHELL_TELEMETRY_OPTOUT=1
Environment=POWERSHELL_UPDATECHECK=Off

# Keep stdout/stderr in journald.
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"@
}

function New-LaunchdPlistText {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$ServiceHome = '/var/root'
    )

    $XmlLabel  = [System.Security.SecurityElement]::Escape($Label)
    $XmlPwsh   = [System.Security.SecurityElement]::Escape($PwshPath)
    $XmlScript = [System.Security.SecurityElement]::Escape($ScriptPath)
    $XmlHome   = [System.Security.SecurityElement]::Escape($ServiceHome)

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>

    <key>Label</key>
    <string>$XmlLabel</string>

    <key>ProgramArguments</key>
    <array>
        <string>$XmlPwsh</string>
        <string>-NoLogo</string>
        <string>-NoProfile</string>
        <string>-NonInteractive</string>
        <string>-File</string>
        <string>$XmlScript</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>5</integer>

    <key>ProcessType</key>
    <string>Background</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$XmlHome</string>
        <key>POWERSHELL_TELEMETRY_OPTOUT</key>
        <string>1</string>
        <key>POWERSHELL_UPDATECHECK</key>
        <string>Off</string>
    </dict>

</dict>
</plist>
"@
}

function New-WindowsTaskArguments {
    # The scheduled task launches pwsh with a -Command that sets HOME (the
    # service profile) and then runs the monitor. Single quotes inside the
    # embedded PowerShell are doubled so a path such as C:\O'Brien survives.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ServiceHome
    )

    $EscapedHome   = $ServiceHome.Replace("'", "''")
    $EscapedScript = $ScriptPath.Replace("'", "''")

    return "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"`$env:HOME='$EscapedHome'; & '$EscapedScript'`""
}

# ============================================================
# Validation helpers
# ============================================================

function Test-MonitorScriptSyntax {
    # Parses (never runs) the script. Returns the parse errors, empty if OK.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @("File not found: $Path")
    }

    $Tokens = $null
    $Errors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)

    return @($Errors | ForEach-Object { "$($_.Message) (line $($_.Extent.StartLineNumber))" })
}

function Get-MonitorScriptVersion {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $Text = Get-Content -LiteralPath $Path -Raw

    if ($Text -match "GrongoMonitorVersion\s*=\s*'([^']+)'") {
        return $Matches[1]
    }

    return $null
}

function Test-EventServerUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $Parsed = $null

    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$Parsed)) {
        return $false
    }

    return ($Parsed.Scheme -eq 'http' -or $Parsed.Scheme -eq 'https')
}

function Test-SafeInstallDirectory {
    # The install directory can be deleted by -Uninstall, so refuse anything
    # that is a filesystem root, a top-level system directory, or a home dir.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }

    $Full = [System.IO.Path]::GetFullPath($Path).TrimEnd('/', '\')

    if ($Full -eq '') { return $false }                    # "/"
    if ($Full -match '^[A-Za-z]:$') { return $false }      # "C:\"

    $Segments = @($Full -split '[\\/]' | Where-Object { $_ -ne '' -and $_ -notmatch '^[A-Za-z]:$' })

    if ($Segments.Count -lt 2) {
        $Unsafe = @('bin', 'boot', 'dev', 'etc', 'home', 'lib', 'lib64', 'opt', 'proc', 'root', 'run', 'sbin', 'srv',
                    'sys', 'tmp', 'usr', 'var', 'users', 'windows', 'system', 'library', 'applications', 'private',
                    'program files', 'program files (x86)', 'programdata')

        if ($Segments.Count -eq 0 -or $Unsafe -contains $Segments[0].ToLowerInvariant()) {
            return $false
        }
    }

    foreach ($HomeCandidate in @($HOME, '/root', '/var/root')) {
        if (-not [string]::IsNullOrWhiteSpace($HomeCandidate) -and
            $Full -eq ([System.IO.Path]::GetFullPath($HomeCandidate).TrimEnd('/', '\'))) {
            return $false
        }
    }

    return $true
}

function Get-InstallerJsonProperty {
    # StrictMode-safe read of an optional property from parsed JSON.
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -ne $Property) { return $Property.Value }

    return $null
}

# ============================================================
# Privileges and prerequisites (thin wrappers so they can be mocked)
# ============================================================

function Test-IsAdministrator {

    if ((Get-InstallPlatform) -eq 'Windows') {

        $Identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

        return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    return ([System.Environment]::UserName -eq 'root')
}

function Get-PwshPath {
    $Pwsh = Get-Command pwsh -ErrorAction SilentlyContinue

    if ($null -eq $Pwsh) {
        throw @"
PowerShell 7 (pwsh) was not found.

Install PowerShell 7 and run this installer again.
"@
    }

    return (Resolve-Path -LiteralPath $Pwsh.Source).Path
}

function Test-SystemdAvailable {
    # /run/systemd/system exists only when systemd is PID 1 (it is absent in
    # most containers, WSL1 and non-systemd distros such as Alpine/OpenRC).
    return (Test-Path -LiteralPath '/run/systemd/system')
}

function Invoke-Systemctl {
    & systemctl @args
}

function Invoke-Launchctl {
    & launchctl @args
}

function Set-SecureFilePermissions {
    # Restrict a data path to the service identity.
    #   file:      owner read/write only
    #   directory: owner only
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Directory
    )

    if ((Get-InstallPlatform) -eq 'Windows') {

        # SYSTEM and Administrators only; drop inherited access.
        $Grant = if ($Directory) { '(OI)(CI)F' } else { 'F' }

        & icacls.exe $Path /inheritance:r /grant:r "*S-1-5-18:$Grant" "*S-1-5-32-544:$Grant" | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not restrict permissions on: $Path"
        }

        return
    }

    $Mode = if ($Directory) { '700' } else { '600' }

    & chmod $Mode $Path

    if ($LASTEXITCODE -ne 0) {
        throw "chmod $Mode failed for $Path"
    }
}

function Set-InstallDirectoryPermissions {
    # The code the service runs must not be writable by ordinary users.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ScriptFile
    )

    if ((Get-InstallPlatform) -eq 'Windows') {

        # SYSTEM and Administrators full control; Users read + execute.
        & icacls.exe $Directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Could not secure the install directory: $Directory"
        }

        return
    }

    & chmod 755 $Directory
    & chmod 644 $ScriptFile
}

# ============================================================
# Token handling
# ============================================================

function Read-ForwarderToken {
    param([string]$Prompt = 'Enter grongo event-server bearer token')

    $SecureToken = Read-Host -Prompt $Prompt -AsSecureString

    $BSTR = [IntPtr]::Zero

    try {
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        if ($BSTR -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
    }
}

function Resolve-InstallerToken {
    # -EventTokenFile, then $env:GRONGO_EVENT_TOKEN, then a SecureString
    # prompt. Never a command-line value, so it cannot leak into ps output,
    # shell history, or a scheduled-task definition.
    [CmdletBinding()]
    param([string]$TokenFile)

    $Token = $null

    if (-not [string]::IsNullOrWhiteSpace($TokenFile)) {

        if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
            throw "Token file not found: $TokenFile"
        }

        $Token = Get-Content -LiteralPath $TokenFile -Raw

        if ((Get-InstallPlatform) -ne 'Windows') {
            try {
                $Mode = [int](& stat -c '%a' $TokenFile 2>$null)
                if (($Mode % 100) -ne 0) {
                    Write-Warning "Token file $TokenFile is readable by other users (mode $Mode). Consider chmod 600."
                }
            }
            catch { }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GRONGO_EVENT_TOKEN)) {
        $Token = $env:GRONGO_EVENT_TOKEN
    }
    else {
        $Token = Read-ForwarderToken
    }

    if ($null -ne $Token) { $Token = $Token.Trim() }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'An event-server token is required when forwarding is enabled.'
    }

    if ($Token -match '\s') {
        throw 'The event-server token must be a single line with no whitespace.'
    }

    return $Token
}

# ============================================================
# Forwarder configuration files
# ============================================================

function Write-ForwarderConfigFiles {
    # Writes config.json (non-secret) and token (secret) into the service
    # account's data directory. Existing non-secret settings are preserved
    # unless overridden. The token file is created empty and locked down
    # BEFORE the secret is written, so there is never a readable window.
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Token,
        [int]$BatchSize = 0,
        [int]$IntervalSeconds = 0
    )

    if (-not (Test-Path -LiteralPath $Layout.GrongoHome)) {
        New-Item -ItemType Directory -Path $Layout.GrongoHome -Force | Out-Null
    }

    Set-SecureFilePermissions -Path $Layout.GrongoHome -Directory

    $Existing = $null

    if (Test-Path -LiteralPath $Layout.ConfigPath) {
        try { $Existing = Get-Content -LiteralPath $Layout.ConfigPath -Raw | ConvertFrom-Json } catch { $Existing = $null }
    }

    $Pick = {
        param([int]$Override, [string]$Key, [int]$Default)

        if ($Override -gt 0) { return $Override }

        $Parsed = 0
        $Value  = Get-InstallerJsonProperty $Existing $Key

        if ($null -ne $Value -and [int]::TryParse([string]$Value, [ref]$Parsed) -and $Parsed -gt 0) { return $Parsed }

        return $Default
    }

    $Merged = [ordered]@{
        server            = $Server.Trim().TrimEnd('/')
        batchSize         = (& $Pick $BatchSize 'batchSize' 50)
        intervalSeconds   = (& $Pick $IntervalSeconds 'intervalSeconds' 30)
        maxBackoffSeconds = (& $Pick 0 'maxBackoffSeconds' 900)
    }

    $Merged | ConvertTo-Json | Set-Content -LiteralPath $Layout.ConfigPath -Encoding UTF8

    # Token: create empty, restrict, then fill.
    Set-Content -LiteralPath $Layout.TokenPath -Value '' -NoNewline
    Set-SecureFilePermissions -Path $Layout.TokenPath
    Set-Content -LiteralPath $Layout.TokenPath -Value $Token -Encoding UTF8 -NoNewline
}

# ============================================================
# Staging the monitor into a root-owned directory
# ============================================================

function Install-MonitorFiles {
    param([Parameter(Mandatory)]$Layout)

    if (-not $Layout.Staged) {
        Write-Host "Running the monitor in place (not copied): $($Layout.ScriptPath)"
        return
    }

    if (-not (Test-SafeInstallDirectory $Layout.InstallDir)) {
        throw "Refusing to use '$($Layout.InstallDir)' as the install directory."
    }

    if (-not (Test-Path -LiteralPath $Layout.InstallDir)) {
        New-Item -ItemType Directory -Path $Layout.InstallDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $Layout.SourceScript -Destination $Layout.ScriptPath -Force

    $Version = Get-MonitorScriptVersion -Path $Layout.ScriptPath

    Set-Content `
        -LiteralPath (Join-Path $Layout.InstallDir $Script:InstallMarkerName) `
        -Value "grongoMonitor $Version installed $([DateTimeOffset]::Now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)) from $($Layout.SourceDirectory)" `
        -Encoding UTF8

    Set-InstallDirectoryPermissions -Directory $Layout.InstallDir -ScriptFile $Layout.ScriptPath

    Write-Host "Installed monitor $Version to: $($Layout.ScriptPath)"
}

function Remove-MonitorFiles {
    # Only ever deletes a directory that carries our marker file.
    param([Parameter(Mandatory)]$Layout)

    if (-not $Layout.Staged) { return }

    $Marker = Join-Path $Layout.InstallDir $Script:InstallMarkerName

    if (-not (Test-Path -LiteralPath $Marker)) { return }

    if (-not (Test-SafeInstallDirectory $Layout.InstallDir)) {
        Write-Warning "Not removing '$($Layout.InstallDir)': it does not look like a dedicated install directory."
        return
    }

    Remove-Item -LiteralPath $Layout.InstallDir -Recurse -Force

    Write-Host "Removed install directory: $($Layout.InstallDir)"
}

function Remove-DataDirectory {
    param([Parameter(Mandatory)]$Layout)

    if ((Split-Path -Leaf $Layout.GrongoHome) -ne '.grongoMonitor') {
        Write-Warning "Not purging '$($Layout.GrongoHome)': unexpected name."
        return
    }

    if (Test-Path -LiteralPath $Layout.GrongoHome) {
        Remove-Item -LiteralPath $Layout.GrongoHome -Recurse -Force
        Write-Host "Removed data directory: $($Layout.GrongoHome)"
    }
}

# ============================================================
# Linux / systemd
# ============================================================

function Test-LinuxServiceInstalled {
    param([Parameter(Mandatory)]$Layout)
    return (Test-Path -LiteralPath $Layout.SystemdUnitPath)
}

function Remove-LinuxService {
    param([Parameter(Mandatory)]$Layout)

    Invoke-Systemctl stop "$($Layout.ServiceName).service" 2>$null
    Invoke-Systemctl disable "$($Layout.ServiceName).service" 2>$null

    if (Test-Path -LiteralPath $Layout.SystemdUnitPath) {
        Remove-Item -LiteralPath $Layout.SystemdUnitPath -Force
    }

    Invoke-Systemctl daemon-reload
}

function Install-LinuxService {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath
    )

    $Unit = New-SystemdUnitText `
        -PwshPath $PwshPath `
        -ScriptPath $Layout.ScriptPath `
        -WorkingDirectory $Layout.WorkingDirectory `
        -ServiceHome $Layout.ServiceHome

    Write-Host 'Installing systemd service...'

    Set-Content -LiteralPath $Layout.SystemdUnitPath -Value $Unit -Encoding UTF8

    Invoke-Systemctl daemon-reload
    if ($LASTEXITCODE -ne 0) { throw 'systemctl daemon-reload failed.' }

    Invoke-Systemctl enable "$($Layout.ServiceName).service"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to enable systemd service.' }

    Invoke-Systemctl start "$($Layout.ServiceName).service"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start systemd service.' }

    Write-Host ''
    Write-Host 'grongoMonitor installed successfully.'
    Write-Host ''
    Write-Host 'Service:'
    Write-Host "  $($Layout.ServiceName).service"
    Write-Host ''
    Write-Host 'Useful commands:'
    Write-Host "  systemctl status $($Layout.ServiceName)"
    Write-Host "  journalctl -u $($Layout.ServiceName) -f"
    Write-Host "  tail -f $($Layout.GrongoHome)/events.log"
    Write-Host ''
}

# ============================================================
# macOS / launchd
# ============================================================

function Test-MacOSServiceInstalled {
    param([Parameter(Mandatory)]$Layout)
    return (Test-Path -LiteralPath $Layout.LaunchdPlistPath)
}

function Remove-MacOSService {
    param([Parameter(Mandatory)]$Layout)

    Invoke-Launchctl bootout system $Layout.LaunchdPlistPath 2>$null

    if (Test-Path -LiteralPath $Layout.LaunchdPlistPath) {
        Remove-Item -LiteralPath $Layout.LaunchdPlistPath -Force
    }
}

function Install-MacOSService {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath
    )

    $Plist = New-LaunchdPlistText `
        -Label $Layout.Label `
        -PwshPath $PwshPath `
        -ScriptPath $Layout.ScriptPath `
        -ServiceHome $Layout.ServiceHome

    Write-Host 'Installing launchd service...'

    Set-Content -LiteralPath $Layout.LaunchdPlistPath -Value $Plist -Encoding UTF8

    # launchd refuses plists that are group/world writable or not root-owned.
    & chmod 644 $Layout.LaunchdPlistPath

    Invoke-Launchctl bootstrap system $Layout.LaunchdPlistPath

    if ($LASTEXITCODE -ne 0) { throw 'Failed to load launchd service.' }

    Write-Host ''
    Write-Host 'grongoMonitor installed successfully.'
    Write-Host ''
    Write-Host 'Service:'
    Write-Host "  $($Layout.Label)"
    Write-Host ''
}

# ============================================================
# Windows / Task Scheduler
# ============================================================

function Test-WindowsServiceInstalled {
    param([Parameter(Mandatory)]$Layout)

    return [bool](Get-ScheduledTask -TaskName $Layout.TaskName -ErrorAction SilentlyContinue)
}

function Remove-WindowsService {
    param([Parameter(Mandatory)]$Layout)

    $ExistingTask = Get-ScheduledTask -TaskName $Layout.TaskName -ErrorAction SilentlyContinue

    if ($ExistingTask) {

        try { Stop-ScheduledTask -TaskName $Layout.TaskName -ErrorAction SilentlyContinue } catch { }

        Unregister-ScheduledTask -TaskName $Layout.TaskName -Confirm:$false -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 1
    }

    # A legacy Windows *service* from an early version of this installer.
    $ExistingService = Get-Service -Name $Layout.ServiceName -ErrorAction SilentlyContinue

    if ($ExistingService) {

        if ($ExistingService.Status -ne 'Stopped') {
            Stop-Service -Name $Layout.ServiceName -Force -ErrorAction SilentlyContinue
        }

        & sc.exe delete $Layout.ServiceName | Out-Null

        if ($LASTEXITCODE -ne 0) { Write-Warning 'Failed to remove legacy Windows service.' }
    }
}

function Install-WindowsService {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath
    )

    Write-Host 'Installing Windows startup task...'
    Write-Host "  Name:        $($Layout.TaskName)"
    Write-Host "  PowerShell:  $PwshPath"
    Write-Host "  Monitor:     $($Layout.ScriptPath)"
    Write-Host '  Run As:      SYSTEM'
    Write-Host '  Trigger:     At startup'

    $Arguments = New-WindowsTaskArguments -ScriptPath $Layout.ScriptPath -ServiceHome $Layout.ServiceHome

    $Action = New-ScheduledTaskAction `
        -Execute $PwshPath `
        -Argument $Arguments `
        -WorkingDirectory $Layout.WorkingDirectory

    $Trigger = New-ScheduledTaskTrigger -AtStartup

    $Principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $Settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -RestartCount 10 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    $Task = New-ScheduledTask `
        -Action $Action `
        -Trigger $Trigger `
        -Principal $Principal `
        -Settings $Settings `
        -Description $Script:ServiceDescription

    Register-ScheduledTask -TaskName $Layout.TaskName -InputObject $Task -Force | Out-Null

    Write-Host ''
    Write-Host 'Starting task...'

    Start-ScheduledTask -TaskName $Layout.TaskName

    Start-Sleep -Seconds 2

    $TaskInfo = Get-ScheduledTaskInfo -TaskName $Layout.TaskName

    Write-Host ''
    Write-Host 'grongoMonitor installed successfully.'
    Write-Host ''
    Write-Host 'Windows startup task:'
    Write-Host "  $($Layout.TaskName)"
    Write-Host ''
    Write-Host 'Status:'
    Write-Host "  $((Get-ScheduledTask -TaskName $Layout.TaskName).State)"
    Write-Host ''
    Write-Host 'Last run:'
    Write-Host "  $($TaskInfo.LastRunTime)"
    Write-Host ''
}

# ============================================================
# Platform dispatch
# ============================================================

function Test-ServiceInstalled {
    param([Parameter(Mandatory)]$Layout)

    switch ($Layout.Platform) {
        'Windows' { return (Test-WindowsServiceInstalled -Layout $Layout) }
        'Linux'   { return (Test-LinuxServiceInstalled -Layout $Layout) }
        'macOS'   { return (Test-MacOSServiceInstalled -Layout $Layout) }
    }
}

function Remove-ServiceDefinition {
    param([Parameter(Mandatory)]$Layout)

    switch ($Layout.Platform) {
        'Windows' { Remove-WindowsService -Layout $Layout }
        'Linux'   { Remove-LinuxService -Layout $Layout }
        'macOS'   { Remove-MacOSService -Layout $Layout }
    }
}

function Install-ServiceDefinition {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath
    )

    switch ($Layout.Platform) {
        'Windows' { Install-WindowsService -Layout $Layout -PwshPath $PwshPath }
        'Linux'   { Install-LinuxService -Layout $Layout -PwshPath $PwshPath }
        'macOS'   { Install-MacOSService -Layout $Layout -PwshPath $PwshPath }
    }
}

# ============================================================
# Orchestration
# ============================================================

function Invoke-GrongoUninstall {
    param(
        [Parameter(Mandatory)]$Layout,
        [switch]$Purge
    )

    $WasInstalled = Test-ServiceInstalled -Layout $Layout

    if ($WasInstalled) {
        Write-Host 'Stopping and removing the service...'
        Remove-ServiceDefinition -Layout $Layout
        Write-Host 'Service removed.'
    }
    else {
        Write-Host 'grongoMonitor is not installed.'
    }

    Remove-MonitorFiles -Layout $Layout

    if ($Purge) {
        Remove-DataDirectory -Layout $Layout
    }
    elseif (Test-Path -LiteralPath $Layout.GrongoHome) {
        Write-Host "Data kept in: $($Layout.GrongoHome) (use -Purge to delete it)"
    }
}

function Invoke-GrongoInstall {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath,
        [switch]$Reinstall,
        [bool]$ForwardingRequested = $false,
        [string]$Server,
        [int]$BatchSize = 0,
        [int]$IntervalSeconds = 0,
        [string]$TokenFile
    )

    # ---- 1. Preflight: everything that can fail, before anything changes ----

    $SyntaxErrors = @(Test-MonitorScriptSyntax -Path $Layout.SourceScript)

    if ($SyntaxErrors.Count -gt 0) {
        throw "The monitor script has syntax errors and will not be installed:`n  $($SyntaxErrors -join "`n  ")"
    }

    if ($Layout.Staged -and -not (Test-SafeInstallDirectory $Layout.InstallDir)) {
        throw "Refusing to use '$($Layout.InstallDir)' as the install directory."
    }

    if ($Layout.Platform -eq 'Linux' -and -not (Test-SystemdAvailable)) {
        throw @"
systemd was not detected on this machine (/run/systemd/system is missing).

This installer supports systemd only on Linux. In a container, WSL1 or a
non-systemd distro, run the monitor under your own supervisor instead:

    pwsh -NoLogo -NoProfile -File $($Layout.ScriptPath)
"@
    }

    if ($PSVersionTable.PSVersion -lt [version]'7.2') {
        Write-Warning "PowerShell $($PSVersionTable.PSVersion) is older than 7.2: 'systemctl stop' will not log SERVICE_STOP. Upgrading is recommended."
    }

    $Token = $null

    if ($ForwardingRequested) {

        if (-not (Test-EventServerUrl $Server)) {
            throw "Event server URL is invalid (must be an absolute http:// or https:// URL): '$Server'"
        }

        if ([System.Uri]::new($Server.Trim()).Scheme -ne 'https') {
            Write-Warning 'Event forwarding sends a bearer token; HTTPS is strongly recommended.'
        }

        $Token = Resolve-InstallerToken -TokenFile $TokenFile
    }

    # ---- 2. Existing installation ----

    if (Test-ServiceInstalled -Layout $Layout) {

        if (-not $Reinstall) {

            Write-Host ''
            Write-Host 'grongoMonitor is already installed. Nothing was changed.'
            Write-Host ''
            Write-Host 'Use -Reinstall to replace it (this is also how you apply an update or change'
            Write-Host 'forwarding settings).'
            Write-Host ''

            return $false
        }

        Write-Host 'Removing existing service...'
        Remove-ServiceDefinition -Layout $Layout
    }

    # ---- 3. Stage code, write config, install service ----

    Install-MonitorFiles -Layout $Layout

    if ($ForwardingRequested) {

        Write-ForwarderConfigFiles `
            -Layout $Layout `
            -Server $Server `
            -Token $Token `
            -BatchSize $BatchSize `
            -IntervalSeconds $IntervalSeconds

        $Token = $null

        Write-Host ''
        Write-Host 'Central forwarding configured.'
        Write-Host "  Server: $($Server.Trim().TrimEnd('/'))"
        Write-Host "  Config: $($Layout.ConfigPath)"
        Write-Host "  Token:  $($Layout.TokenPath)"
        Write-Host ''
    }

    Install-ServiceDefinition -Layout $Layout -PwshPath $PwshPath

    # ---- 4. Verify ----

    if ($ForwardingRequested) {

        if (-not (Test-Path -LiteralPath $Layout.ConfigPath)) {
            throw "Forwarder configuration was not created: $($Layout.ConfigPath)"
        }

        if (-not (Test-Path -LiteralPath $Layout.TokenPath)) {
            throw "Forwarder token was not created: $($Layout.TokenPath)"
        }

        Write-Host 'Forwarder installation verified.'
        Write-Host ''
    }

    return $true
}

function Invoke-GrongoInstaller {
    param(
        [switch]$Uninstall,
        [switch]$Reinstall,
        [switch]$Purge,
        [string]$EventServer,
        [bool]$ForwardingRequested,
        [int]$EventBatchSize,
        [int]$EventIntervalSeconds,
        [string]$EventTokenFile,
        [string]$InstallDir,
        [switch]$InPlace,
        [string]$SourceDirectory
    )

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' grongoMonitor installer'
    Write-Host '============================================================'
    Write-Host ''

    $Platform = Get-InstallPlatform

    if (-not (Test-IsAdministrator)) {
        throw @"
This installer must be run with administrator/root privileges.

Windows:
    Run PowerShell as Administrator.

Linux/macOS:
    sudo pwsh ./Install-GrongoMonitor.ps1
"@
    }

    if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
        $SourceDirectory = (Get-Location).Path
    }

    $Layout = Get-InstallLayout `
        -Platform $Platform `
        -SourceDirectory $SourceDirectory `
        -InstallDir $InstallDir `
        -InPlace:$InPlace

    Write-Host "Platform: $Platform"

    if ($Uninstall) {
        Invoke-GrongoUninstall -Layout $Layout -Purge:$Purge
        Write-Host ''
        return
    }

    if (-not (Test-Path -LiteralPath $Layout.SourceScript)) {
        throw @"
Could not find $($Script:MonitorScriptName) next to this installer.

Expected:

    $SourceDirectory
        ├── Install-GrongoMonitor.ps1
        └── $($Script:MonitorScriptName)
"@
    }

    # Any forwarding option implies forwarding. With no server given
    # there is deliberately NO default: pointing a host at someone else's
    # server by pressing Enter is never what you want.
    if ($ForwardingRequested -and [string]::IsNullOrWhiteSpace($EventServer)) {
        $EventServer = Read-Host 'Event server URL (e.g. https://events.example.com)'
    }

    $PwshPath = Get-PwshPath

    [void](Invoke-GrongoInstall `
        -Layout $Layout `
        -PwshPath $PwshPath `
        -Reinstall:$Reinstall `
        -ForwardingRequested $ForwardingRequested `
        -Server $EventServer `
        -BatchSize $EventBatchSize `
        -IntervalSeconds $EventIntervalSeconds `
        -TokenFile $EventTokenFile)

    Write-Host ''
}

# ============================================================
# Entry point (skipped when dot-sourced)
# ============================================================

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$ScriptDirectory = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($ScriptDirectory)) {
    $ScriptDirectory = (Get-Location).Path
}

$ForwardingRequested = $ConfigureEventForwarding -or
    $PSBoundParameters.ContainsKey('EventServer') -or
    $PSBoundParameters.ContainsKey('EventBatchSize') -or
    $PSBoundParameters.ContainsKey('EventIntervalSeconds') -or
    $PSBoundParameters.ContainsKey('EventTokenFile')

Invoke-GrongoInstaller `
    -Uninstall:$Uninstall `
    -Reinstall:$Reinstall `
    -Purge:$Purge `
    -EventServer $EventServer `
    -ForwardingRequested ([bool]$ForwardingRequested) `
    -EventBatchSize $EventBatchSize `
    -EventIntervalSeconds $EventIntervalSeconds `
    -EventTokenFile $EventTokenFile `
    -InstallDir $InstallDir `
    -InPlace:$InPlace `
    -SourceDirectory $ScriptDirectory
