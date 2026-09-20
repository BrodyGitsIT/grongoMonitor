#!/usr/bin/env pwsh

# ============================================================
# grongoMonitor
# PowerShell 7+ (7.2+ recommended: graceful SIGTERM handling)
#
# Lightweight cross-platform system + Docker event monitor.
#
# Log format:
#   ISO_TIMESTAMP | HOST=name | EVENT=TYPE | KEY=value
#
# Designed for:
#   - Hermes / LLM agents
#   - Scripts
#   - Graylog ingestion
#   - Monitoring dashboards
#   - Human-readable troubleshooting
#
# Optional central forwarding:
#   Every event written locally is also enqueued to a durable
#   on-disk outbox. An independent background runspace batches
#   the outbox and transmits it over HTTPS to a central
#   grongo event server, with retries and exponential backoff.
#   This is purely additive - with no server configured,
#   grongoMonitor behaves exactly as it always has, and the
#   central server is never a dependency of local monitoring.
#   See docs/CONFIGURATION.md.
#
# Emitted events (kept in sync with the code by tests/Repo.Tests.ps1):
#
#   EMITTED: BOOT REBOOT START_AFTER_GAP
#   EMITTED: SERVICE_START SERVICE_STOP SERVICE_ERROR HEARTBEAT CRASH
#   EMITTED: DOCKER_CREATED DOCKER_RESTARTED DOCKER_SHUTDOWN
#   EMITTED: DOCKER_CRASHED DOCKER_BOOTED
#   EMITTED: DOCKER_MONITOR_FAILED DOCKER_MONITOR_RESTARTED
#
# Reserved names (documented for consumers, NOT emitted yet):
#
#   RESERVED: SHUTDOWN OOM DISK_ERROR NETWORK_CHANGE TIME_CHANGE
#
# Code layout:
#   Everything below is a function. The script only *runs* when
#   invoked normally (pwsh -File / & script). When dot-sourced
#   (. ./grongoMonitor.ps1) it loads definitions and returns,
#   which is how the Pester suite in tests/ exercises it.
# ============================================================

[CmdletBinding()]
param(
    [string]$LogPath = "$HOME/.grongoMonitor/events.log",

    [string]$StatePath = "$HOME/.grongoMonitor/state.json",

    [int]$HeartbeatSeconds = 60,

    # A gap larger than this is treated as a possible reboot,
    # shutdown, crash, or service interruption.
    [int]$RestartGapSeconds = 300,

    # Reserved. Docker events are streamed from a long-lived
    # `docker events` process, not polled, so this is currently unused.
    [int]$DockerPollSeconds = 2,

    # Disable Docker monitoring if desired.
    [switch]$NoDocker,

    # ------------------------------------------------------------
    # Central event server (optional forwarder)
    #
    # None of this is required. With no server configured,
    # grongoMonitor behaves exactly as it always has: local log
    # and local state only. See docs/CONFIGURATION.md.
    #
    # Precedence for every forwarder setting below is:
    #   explicit parameter > environment variable > config.json > default
    # ------------------------------------------------------------

    [string]$OutboxPath = "$HOME/.grongoMonitor/outbox",

    [string]$ForwarderLogPath = "$HOME/.grongoMonitor/grongoMonitor.log",

    [string]$EventConfigPath = "$HOME/.grongoMonitor/config.json",

    [string]$EventTokenPath = "$HOME/.grongoMonitor/token",

    # Central server base URL, e.g. https://events.example.com
    # Falls back to $env:GRONGO_EVENT_SERVER, then config.json.
    [string]$EventServer = $null,

    # Falls back to $env:GRONGO_EVENT_BATCH_SIZE, then config.json,
    # then a default of 50. 0 means "not explicitly specified".
    [int]$EventBatchSize = 0,

    # Falls back to $env:GRONGO_EVENT_INTERVAL, then config.json,
    # then a default of 30 seconds. 0 means "not explicitly specified".
    [int]$EventIntervalSeconds = 0,

    # Disable the forwarder entirely, even if a server is configured.
    [switch]$NoForward
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:GrongoMonitorVersion = '1.0.0'

# Every date/time we format or parse goes through this culture. The
# machine's culture must never change what lands in a log line, an
# outbox file, or state.json (fi-FI would emit 21.25.23, th-TH a
# Buddhist-era year, en-GB/de-DE cannot parse a US-formatted string).
$Script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ============================================================
# Platform detection (no side effects)
# ============================================================

$Hostname = [System.Net.Dns]::GetHostName()

$detectedWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)

$detectedLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Linux
)

$detectedMacOS = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::OSX
)

# ============================================================
# Runtime state
#
# Mutable state is always addressed as $Script:Name so that the
# functions below behave identically whether the file is run as a
# script or dot-sourced by tests.
# ============================================================

$Script:ForwardingEnabled     = $false
$Script:ForwarderConfig       = $null
$Script:DockerAvailable       = $false
$Script:CurrentBootTime       = $null
$Script:SuppressOutboxOnError = $false
$Script:ForwarderPendingCount = 0
$Script:ForwarderWakeSignal   = [System.Threading.AutoResetEvent]::new($false)
$Script:ForwarderControl      = [hashtable]::Synchronized(@{ Stop = $false })
$Script:ForwarderPowerShell   = $null
$Script:ForwarderRunspace     = $null
$Script:ForwarderHandle       = $null

# ============================================================
# Small helpers
# ============================================================

function Get-JsonPropertyOrNull {
    # Set-StrictMode -Version Latest throws on access to a
    # non-existent property, so every read of a value that may or
    # may not be present in user-edited or externally produced JSON
    # (config.json, state.json, `docker events` output) goes through
    # this helper.
    param(
        $Object,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    # Indexing the property collection by name is safe for every input:
    # objects, scalars ("5"), arrays and strings. (Enumerating
    # `.Properties.Name` is not - on a scalar it is an empty collection and
    # StrictMode turns `.Name` into a terminating error.)
    $Property = $Object.PSObject.Properties[$Name]

    if ($null -ne $Property) {
        # The leading comma stops PowerShell unrolling an empty array
        # into $null, so "present but empty" stays distinguishable from
        # "missing".
        return , $Property.Value
    }

    return $null
}

function ConvertTo-DateTimeOffsetOrNull {
    # ConvertFrom-Json silently turns ISO-8601 strings into [DateTime].
    # Casting that back through [string] and [DateTimeOffset]::Parse is
    # both culture-dependent and lossy (sub-second precision), so state
    # read-back accepts either representation and never round-trips
    # through the current culture.
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [DateTimeOffset]) {
        return $Value
    }

    if ($Value -is [DateTime]) {
        # ConvertFrom-Json may materialize ISO-8601 values as [DateTime],
        # losing the original offset. Normalize that representation back to
        # UTC so the instant (and canonical event timestamp) is preserved.
        return [DateTimeOffset]$Value.ToUniversalTime()
    }

    $Text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $Parsed = [DateTimeOffset]::MinValue

    if ([DateTimeOffset]::TryParse(
            $Text,
            $Script:Invariant,
            [System.Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$Parsed)) {
        return $Parsed
    }

    return $null
}

function Get-EventTimestamp {
    [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:ssK", $Script:Invariant)
}
# ============================================================
# Logging
# ============================================================

function Write-EventLog {
    param(
        [Parameter(Mandatory)]
        [string]$Event,

        [hashtable]$Data = @{}
    )

    # Stable identifier for this event, used only by the outbox /
    # forwarder pipeline for idempotent delivery. It is
    # intentionally NOT written into events.log - the local log
    # format is unchanged.
    $EventId = [guid]::NewGuid().ToString()

    $Timestamp = Get-EventTimestamp

    $Fields = @(
        $Timestamp
        "HOST=$Hostname"
        "EVENT=$Event"
    )

    foreach ($Key in $Data.Keys) {

        $Value = [string]$Data[$Key]

        # Keep every event on exactly one line.
        $Value = $Value -replace '\|', '/'
        $Value = $Value -replace "`r|`n", ' '

        $Fields += "$Key=$Value"
    }

    $Line = $Fields -join " | "

    Add-Content `
        -LiteralPath $LogPath `
        -Value $Line `
        -Encoding UTF8

    # ------------------------------------------------------------
    # Durable outbound queue.
    #
    # This is local disk I/O only - never network I/O - so it
    # cannot block or delay event detection. Transmission happens
    # independently in the forwarder runspace.
    #
    # $Script:SuppressOutboxOnError guards against unbounded
    # recursion if the outbox itself is failing (e.g. disk full):
    # Add-OutboxEvent logs a single SERVICE_ERROR through this
    # same function on failure, and that nested call must not
    # attempt to enqueue itself.
    # ------------------------------------------------------------

    if ($Script:ForwardingEnabled -and -not $Script:SuppressOutboxOnError) {

        Add-OutboxEvent `
            -EventId $EventId `
            -Timestamp $Timestamp `
            -EventType $Event `
            -Data $Data
    }
}

# ============================================================
# Event forwarder: configuration
# ============================================================

function Resolve-StringSetting {
    param(
        [string]$ParamValue,
        [Parameter(Mandatory)]
        [string]$EnvName,
        $FileValue,
        [string]$DefaultValue
    )

    if (-not [string]::IsNullOrWhiteSpace($ParamValue)) {
        return $ParamValue
    }

    $EnvValue = [System.Environment]::GetEnvironmentVariable($EnvName)

    if (-not [string]::IsNullOrWhiteSpace($EnvValue)) {
        return $EnvValue
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$FileValue)) {
        return [string]$FileValue
    }

    return $DefaultValue
}

function Resolve-IntSetting {
    param(
        [int]$ParamValue,
        [Parameter(Mandatory)]
        [string]$EnvName,
        $FileValue,
        [Parameter(Mandatory)]
        [int]$DefaultValue
    )

    if ($ParamValue -gt 0) {
        return $ParamValue
    }

    $EnvValue = [System.Environment]::GetEnvironmentVariable($EnvName)

    if (-not [string]::IsNullOrWhiteSpace($EnvValue)) {

        $Parsed = 0

        if ([int]::TryParse($EnvValue, [ref]$Parsed) -and $Parsed -gt 0) {
            return $Parsed
        }
    }

    if ($null -ne $FileValue) {

        $ParsedFile = 0

        if ([int]::TryParse([string]$FileValue, [ref]$ParsedFile) -and $ParsedFile -gt 0) {
            return $ParsedFile
        }
    }

    return $DefaultValue
}

function Test-ForwarderServerUrl {
    # A server URL must be an absolute http(s) URL. Anything else
    # (a bare hostname, "ftp://...", a typo) can never succeed and
    # would otherwise fail silently, forever, in grongoMonitor.log
    # while the outbox grows.
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $false
    }

    $Parsed = $null

    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$Parsed)) {
        return $false
    }

    return ($Parsed.Scheme -eq 'http' -or $Parsed.Scheme -eq 'https')
}

function Get-EventForwarderConfig {

    $FileConfig = $null

    if (Test-Path -LiteralPath $EventConfigPath) {

        try {
            $FileConfig = Get-Content -LiteralPath $EventConfigPath -Raw |
                ConvertFrom-Json
        }
        catch {
            $FileConfig = $null
        }
    }

    $ServerValue = Resolve-StringSetting `
        -ParamValue $EventServer `
        -EnvName "GRONGO_EVENT_SERVER" `
        -FileValue (Get-JsonPropertyOrNull $FileConfig "server") `
        -DefaultValue $null

    if ($null -ne $ServerValue) {
        $ServerValue = $ServerValue.Trim()
    }

    $BatchSizeValue = Resolve-IntSetting `
        -ParamValue $EventBatchSize `
        -EnvName "GRONGO_EVENT_BATCH_SIZE" `
        -FileValue (Get-JsonPropertyOrNull $FileConfig "batchSize") `
        -DefaultValue 50

    $IntervalValue = Resolve-IntSetting `
        -ParamValue $EventIntervalSeconds `
        -EnvName "GRONGO_EVENT_INTERVAL" `
        -FileValue (Get-JsonPropertyOrNull $FileConfig "intervalSeconds") `
        -DefaultValue 30

    $MaxBackoffValue = Resolve-IntSetting `
        -ParamValue 0 `
        -EnvName "GRONGO_EVENT_MAX_BACKOFF_SECONDS" `
        -FileValue (Get-JsonPropertyOrNull $FileConfig "maxBackoffSeconds") `
        -DefaultValue 900

    $TokenValue = [System.Environment]::GetEnvironmentVariable("GRONGO_EVENT_TOKEN")

    if ([string]::IsNullOrWhiteSpace($TokenValue) -and
        (Test-Path -LiteralPath $EventTokenPath)) {

        try {
            $TokenValue = Get-Content -LiteralPath $EventTokenPath -Raw
        }
        catch {
            $TokenValue = $null
        }
    }

    # A stray newline in a token file or env var would otherwise make
    # the Authorization header invalid and every request fail.
    if ($null -ne $TokenValue) {
        $TokenValue = $TokenValue.Trim()
    }

    return [ordered]@{
        ServerUrl         = $ServerValue
        Token             = $TokenValue
        BatchSize         = $BatchSizeValue
        IntervalSeconds   = $IntervalValue
        MaxBackoffSeconds = $MaxBackoffValue
    }
}

function Initialize-MonitorEnvironment {
    # Create every directory the monitor writes into. The state file
    # and the log may live in different directories (-StatePath /
    # -LogPath are independent), and a bare filename has no parent.
    foreach ($FilePath in @($LogPath, $StatePath)) {

        $Directory = Split-Path -Parent $FilePath

        if (-not [string]::IsNullOrWhiteSpace($Directory) -and
            -not (Test-Path -LiteralPath $Directory)) {

            New-Item -ItemType Directory -Path $Directory -Force |
                Out-Null
        }
    }

    # The outbox is created unconditionally and cheaply. Whether
    # it is actually used depends on whether forwarding ends up
    # enabled - see Initialize-Forwarder.
    if (-not (Test-Path -LiteralPath $OutboxPath)) {
        New-Item -ItemType Directory -Path $OutboxPath -Force |
            Out-Null
    }
}

function Initialize-Forwarder {
    # Resolve configuration and decide whether forwarding is active.
    #
    # Forwarding is opt-in: with no server configured anywhere
    # (parameter, environment, or config.json), nothing is enqueued
    # and no background runspace is started, so there is zero added
    # overhead for anyone not using this feature.

    $Script:ForwardingEnabled = $false
    $Script:ForwarderConfig   = $null

    if ($NoForward) {
        return
    }

    try {

        $ForwarderLogDirectory = Split-Path -Parent $ForwarderLogPath

        if (-not [string]::IsNullOrWhiteSpace($ForwarderLogDirectory) -and
            -not (Test-Path -LiteralPath $ForwarderLogDirectory)) {

            New-Item -ItemType Directory -Path $ForwarderLogDirectory -Force |
                Out-Null
        }

        $Script:ForwarderConfig = Get-EventForwarderConfig

        if (-not [string]::IsNullOrWhiteSpace($Script:ForwarderConfig.ServerUrl)) {

            if (-not (Test-ForwarderServerUrl -Url $Script:ForwarderConfig.ServerUrl)) {

                # Fail closed to local-only monitoring, and say so.
                Write-EventLog -Event "SERVICE_ERROR" -Data @{
                    COMPONENT = "EventForwarder"
                    MESSAGE   = "Configured event server '$($Script:ForwarderConfig.ServerUrl)' is not an absolute http(s) URL; forwarding is disabled."
                }

                return
            }

            $Script:ForwardingEnabled = $true

            if ([string]::IsNullOrWhiteSpace($Script:ForwarderConfig.Token)) {

                Write-EventLog -Event "SERVICE_ERROR" -Data @{
                    COMPONENT = "EventForwarder"
                    MESSAGE   = "GRONGO_EVENT_SERVER is configured but no token was found; requests will be sent unauthenticated."
                }
            }
        }
    }
    catch {
        # Forwarding is an enhancement. Any setup failure here
        # simply leaves grongoMonitor running local-only.
        $Script:ForwardingEnabled = $false
    }
}

# ============================================================
# Event forwarder: durable outbox (main thread, local disk only)
# ============================================================

function New-OutboxFileName {
    param(
        [Parameter(Mandatory)]
        [string]$EventId
    )

    # Zero-padded UTC ticks sort lexicographically in chronological
    # order regardless of local clock/timezone/DST changes, so the
    # forwarder can pick "oldest first" with a plain Sort-Object
    # Name instead of parsing every file.
    $Ticks = [DateTimeOffset]::UtcNow.Ticks.ToString("D19", $Script:Invariant)

    return "${Ticks}_$EventId.json"
}

function Add-OutboxEvent {
    param(
        [Parameter(Mandatory)]
        [string]$EventId,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [Parameter(Mandatory)]
        [string]$EventType,

        [hashtable]$Data = @{}
    )

    try {

        $Record = [ordered]@{
            EVENT_ID  = $EventId
            TIMESTAMP = $Timestamp
            HOST      = $Hostname
            EVENT     = $EventType
            DATA      = $Data
        }

        $Json = $Record | ConvertTo-Json -Depth 6 -Compress

        $FileName  = New-OutboxFileName -EventId $EventId
        $FinalPath = Join-Path $OutboxPath $FileName
        $TempPath  = Join-Path $OutboxPath ".tmp-$EventId"

        # Write to a temp file, then rename. The rename is atomic
        # on both POSIX and Windows for a same-volume move, so the
        # forwarder (reading the directory concurrently on another
        # thread) never observes a partially-written event file.
        Set-Content `
            -LiteralPath $TempPath `
            -Value $Json `
            -Encoding UTF8 `
            -NoNewline

        Move-Item `
            -LiteralPath $TempPath `
            -Destination $FinalPath `
            -Force

        $Script:ForwarderPendingCount++

        if ($Script:ForwarderPendingCount -ge $Script:ForwarderConfig.BatchSize) {

            $Script:ForwarderPendingCount = 0

            if ($null -ne $Script:ForwarderWakeSignal) {
                $Script:ForwarderWakeSignal.Set() | Out-Null
            }
        }
    }
    catch {

        if (-not $Script:SuppressOutboxOnError) {

            $Script:SuppressOutboxOnError = $true

            try {
                Write-EventLog -Event "SERVICE_ERROR" -Data @{
                    COMPONENT = "EventForwarder"
                    MESSAGE   = "Failed to enqueue event: $($_.Exception.Message)"
                }
            }
            catch {
                # Nothing further can safely be done here.
            }
            finally {
                $Script:SuppressOutboxOnError = $false
            }
        }
    }
}

# ============================================================
# Event forwarder: background runspace
#
# Everything from here to Stop-EventForwarder is injected, as
# text, into an independent runspace (see Get-ForwarderRunspaceScript).
# These functions therefore must not close over, or depend on, any
# variable or function defined on the main thread. Everything they
# need is passed in as a parameter. Keeping them as real functions
# (rather than one opaque script block) is what makes each piece
# unit-testable.
# ============================================================

function Write-ForwarderDiag {
    # Diagnostics for the forwarder go to grongoMonitor.log, never to
    # events.log. Best-effort only: diagnostics must not be able to
    # break delivery.
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Message,

        [long]$MaxBytes = 5MB
    )

    try {
        $Stamp = [DateTimeOffset]::Now.ToString(
            "yyyy-MM-ddTHH:mm:ssK",
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        Add-Content -LiteralPath $Path -Value "$Stamp | $Message" -Encoding UTF8

        # Simple size-based rollover so a long outage cannot
        # grow this file without bound.
        $FileInfo = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue

        if ($null -ne $FileInfo -and $FileInfo.Length -gt $MaxBytes) {

            Move-Item `
                -LiteralPath $Path `
                -Destination "$Path.old" `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Diagnostics are best-effort only.
    }
}

function Get-NextForwarderInterval {
    # Pure backoff policy.
    #   Failed / Error -> double, capped (never below the base interval)
    #   Delivered / NoAck -> reset to base (connectivity is fine)
    #   Idle -> unchanged
    param(
        [Parameter(Mandatory)]
        [int]$Current,

        [Parameter(Mandatory)]
        [int]$Base,

        [Parameter(Mandatory)]
        [int]$Max,

        [Parameter(Mandatory)]
        [string]$Outcome
    )

    switch ($Outcome) {

        { $_ -in 'Failed', 'Error' } {
            $Cap = [Math]::Max([long]$Max, [long]$Base)
            return [int][Math]::Min([long]$Current * 2, $Cap)
        }

        { $_ -in 'Delivered', 'NoAck' } {
            return $Base
        }

        default {
            return $Current
        }
    }
}

function Invoke-ForwarderCycle {
    # One pass of the forwarder: sweep stale temp files, read the oldest
    # batch, quarantine unreadable files, POST, delete only what the server
    # acknowledged by EVENT_ID.
    #
    # Returns an object whose Outcome is one of:
    #   Idle       nothing to send
    #   Delivered  2xx with a usable 'accepted' list
    #   NoAck      2xx but no usable 'accepted' list (nothing deleted)
    #   Failed     any transport error or non-2xx (nothing deleted)
    param(
        [Parameter(Mandatory)]
        [string]$OutboxPath,

        [Parameter(Mandatory)]
        [string]$EndpointUri,

        [string]$Token,

        [Parameter(Mandatory)]
        [int]$BatchSize,

        [Parameter(Mandatory)]
        [string]$Hostname,

        [Parameter(Mandatory)]
        [string]$DiagLogPath,

        [int]$TimeoutSec = 15
    )

    $Result = [ordered]@{
        Outcome     = 'Idle'
        Sent        = 0
        Accepted    = 0
        Quarantined = 0
        StatusCode  = $null
        Error       = $null
    }

    # Safety net for the extremely narrow crash window between
    # writing a temp file and the atomic rename in
    # Add-OutboxEvent: sweep any leftovers old enough that
    # they cannot possibly still be in progress.
    $StaleTempFiles = Get-ChildItem -LiteralPath $OutboxPath -Filter ".tmp-*" -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-5) }

    foreach ($StaleFile in $StaleTempFiles) {
        Remove-Item -LiteralPath $StaleFile.FullName -Force -ErrorAction SilentlyContinue
    }

    $Files = Get-ChildItem -LiteralPath $OutboxPath -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First $BatchSize

    if ($null -eq $Files -or @($Files).Count -eq 0) {
        return [pscustomobject]$Result
    }

    # The raw file text is what goes on the wire. It is parsed only to
    # validate it and to learn its EVENT_ID. Re-serialising the parsed
    # object would rewrite TIMESTAMP / BOOT_TIME (ConvertFrom-Json turns
    # ISO-8601 strings into local-time DateTime values), violating the
    # API contract that the originating machine's offset is preserved.
    $RawEvents = New-Object System.Collections.Generic.List[string]
    $FilesById = @{}

    foreach ($File in $Files) {

        try {

            $Raw = (Get-Content -LiteralPath $File.FullName -Raw).Trim()

            # Must be a single JSON object. (ConvertFrom-Json unrolls a
            # one-element array, which would otherwise slip through and be
            # embedded as a nested array in the request body.)
            if (-not $Raw.StartsWith('{')) {
                throw "Outbox file is not a JSON object"
            }

            $Parsed = $Raw | ConvertFrom-Json

            $ParsedId = Get-JsonPropertyOrNull $Parsed "EVENT_ID"

            if ([string]::IsNullOrWhiteSpace([string]$ParsedId)) {
                throw "Outbox file is missing EVENT_ID"
            }

            $RawEvents.Add($Raw)

            $Id = [string]$ParsedId

            if (-not $FilesById.ContainsKey($Id)) {
                $FilesById[$Id] = New-Object System.Collections.Generic.List[string]
            }

            $FilesById[$Id].Add($File.FullName)
        }
        catch {

            $Result.Quarantined++

            Write-ForwarderDiag -Path $DiagLogPath -Message "Quarantining unreadable outbox file: $($File.Name) ($($_.Exception.Message))"

            try {
                Move-Item `
                    -LiteralPath $File.FullName `
                    -Destination "$($File.FullName).corrupt" `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            catch {
                # If it can't even be moved, it will be
                # retried (and re-quarantined) next cycle.
            }
        }
    }

    if ($RawEvents.Count -eq 0) {
        return [pscustomobject]$Result
    }

    $Result.Sent = $RawEvents.Count

    $HostJson = ConvertTo-Json -InputObject $Hostname -Compress
    $Body     = '{"host":' + $HostJson + ',"events":[' + ($RawEvents -join ',') + ']}'

    $Headers = @{}

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $Headers['Authorization'] = "Bearer $Token"
    }

    try {

        $Response = Invoke-RestMethod `
            -Uri $EndpointUri `
            -Method Post `
            -Body $Body `
            -ContentType "application/json" `
            -Headers $Headers `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop

        $Accepted = $null

        # (Index the property collection: `.Properties.Name` throws under
        # StrictMode for an empty object, e.g. a server that replies `{}`.)
        $AcceptedValue = $null

        if ($null -ne $Response) {
            $AcceptedValue = Get-JsonPropertyOrNull $Response "accepted"
        }

        if ($null -ne $AcceptedValue) {

            $Accepted = @($AcceptedValue)
        }

        if ($null -ne $Accepted) {

            foreach ($AcceptedId in $Accepted) {

                $Key = [string]$AcceptedId

                if ($FilesById.ContainsKey($Key)) {

                    foreach ($Path in $FilesById[$Key]) {
                        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $Result.Outcome  = 'Delivered'
            $Result.Accepted = $Accepted.Count

            Write-ForwarderDiag -Path $DiagLogPath -Message "Batch delivered. Sent=$($RawEvents.Count) Accepted=$($Accepted.Count)"
        }
        else {

            # Successful HTTP exchange but no usable
            # acknowledgement body. Treat conservatively:
            # leave every event queued for retry. Server-
            # side dedup on EVENT_ID makes this safe.
            $Result.Outcome = 'NoAck'

            Write-ForwarderDiag -Path $DiagLogPath -Message "Batch sent (Count=$($RawEvents.Count)) but response had no 'accepted' list; leaving queued for retry."
        }
    }
    catch {

        $Result.Outcome = 'Failed'
        $Result.Error   = $_.Exception.Message

        $FailedResponse = Get-JsonPropertyOrNull $_.Exception "Response"

        if ($null -ne $FailedResponse) {

            try {
                $Result.StatusCode = [int]$FailedResponse.StatusCode
            }
            catch {
                $Result.StatusCode = $null
            }
        }

        if ($null -ne $Result.StatusCode) {
            Write-ForwarderDiag -Path $DiagLogPath -Message "Batch send failed (HTTP $($Result.StatusCode)): $($_.Exception.Message)"
        }
        else {
            Write-ForwarderDiag -Path $DiagLogPath -Message "Batch send failed: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$Result
}

function Invoke-ForwarderLoop {
    # Runs until $Control.Stop is set. Wakes on whichever comes first:
    # the interval elapsing, or $WakeSignal (raised when the outbox fills a
    # batch). That is what keeps the forwarder from being a high-frequency
    # polling loop while still reacting promptly to bursts.
    param(
        [string]$OutboxPath,
        [string]$DiagLogPath,
        [string]$ServerUrl,
        [string]$Token,
        [int]$BatchSize,
        [int]$IntervalSeconds,
        [int]$MaxBackoffSeconds,
        [string]$Hostname,
        $WakeSignal,
        $Control
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
        Write-ForwarderDiag -Path $DiagLogPath -Message "Forwarder exiting: no server configured."
        return
    }

    Write-ForwarderDiag -Path $DiagLogPath -Message "Forwarder started. Server=$ServerUrl BatchSize=$BatchSize IntervalSeconds=$IntervalSeconds"

    $EndpointUri     = $ServerUrl.TrimEnd('/') + "/api/v1/events/batch"
    $CurrentInterval = $IntervalSeconds
    $Random          = [System.Random]::new()

    while (-not $Control.Stop) {

        $Outcome = 'Error'

        try {

            $Cycle = Invoke-ForwarderCycle `
                -OutboxPath $OutboxPath `
                -EndpointUri $EndpointUri `
                -Token $Token `
                -BatchSize $BatchSize `
                -Hostname $Hostname `
                -DiagLogPath $DiagLogPath

            $Outcome = $Cycle.Outcome
        }
        catch {
            Write-ForwarderDiag -Path $DiagLogPath -Message "Forwarder iteration error: $($_.Exception.Message)"
        }

        $CurrentInterval = Get-NextForwarderInterval `
            -Current $CurrentInterval `
            -Base $IntervalSeconds `
            -Max $MaxBackoffSeconds `
            -Outcome $Outcome

        if ($Control.Stop) {
            break
        }

        # Jitter avoids every host in a fleet retrying in lockstep
        # after a shared outage.
        $WaitMilliseconds = ([long]$CurrentInterval * 1000) + $Random.Next(0, 1000)

        [void]$WakeSignal.WaitOne([int][Math]::Min($WaitMilliseconds, [int]::MaxValue))
    }

    Write-ForwarderDiag -Path $DiagLogPath -Message "Forwarder stopped."
}

function Get-ForwarderRunspaceScript {
    # The runspace shares no state with the main thread, so the forwarder
    # functions are sent across as source text. Single-sourcing them this
    # way means the code that runs in production is the same code the
    # Pester suite calls directly.
    $Names = @(
        'Get-JsonPropertyOrNull'
        'Write-ForwarderDiag'
        'Get-NextForwarderInterval'
        'Invoke-ForwarderCycle'
        'Invoke-ForwarderLoop'
    )

    $Parts = foreach ($Name in $Names) {

        $Command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop

        "function $Name {`n$($Command.ScriptBlock.ToString())`n}"
    }

    return ($Parts -join "`n`n")
}

function Start-EventForwarder {

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.Open()

    $PS = [powershell]::Create()
    $PS.Runspace = $Runspace

    [void]$PS.AddScript((Get-ForwarderRunspaceScript))
    [void]$PS.AddStatement()
    [void]$PS.AddCommand('Invoke-ForwarderLoop').AddParameters(@{
        OutboxPath        = $OutboxPath
        DiagLogPath       = $ForwarderLogPath
        ServerUrl         = $Script:ForwarderConfig.ServerUrl
        Token             = $Script:ForwarderConfig.Token
        BatchSize         = $Script:ForwarderConfig.BatchSize
        IntervalSeconds   = $Script:ForwarderConfig.IntervalSeconds
        MaxBackoffSeconds = $Script:ForwarderConfig.MaxBackoffSeconds
        Hostname          = $Hostname
        WakeSignal        = $Script:ForwarderWakeSignal
        Control           = $Script:ForwarderControl
    })

    $Script:ForwarderPowerShell = $PS
    $Script:ForwarderRunspace   = $Runspace
    $Script:ForwarderHandle     = $PS.BeginInvoke()
}

function Stop-EventForwarder {

    if ($null -eq $Script:ForwarderPowerShell) {
        return
    }

    try {

        $Script:ForwarderControl.Stop = $true

        if ($null -ne $Script:ForwarderWakeSignal) {
            $Script:ForwarderWakeSignal.Set() | Out-Null
        }

        if ($null -ne $Script:ForwarderHandle) {
            # Bounded wait: the forwarder never blocks longer than
            # its own HTTP timeout, so this cannot hang shutdown.
            [void]$Script:ForwarderHandle.AsyncWaitHandle.WaitOne(3000)
        }

        $Script:ForwarderPowerShell.Stop()
        $Script:ForwarderPowerShell.Dispose()

        if ($null -ne $Script:ForwarderRunspace) {
            $Script:ForwarderRunspace.Close()
            $Script:ForwarderRunspace.Dispose()
        }
    }
    catch {
        # Best-effort shutdown; the process is exiting anyway.
    }
}

# ============================================================
# State
# ============================================================

function Read-PreviousState {

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-State {

    $State = [ordered]@{
        LastHeartbeat = [DateTimeOffset]::Now.ToString("o", $Script:Invariant)
        BootTime      = if ($null -ne $Script:CurrentBootTime) {
            $Script:CurrentBootTime.ToString("o", $Script:Invariant)
        }
        else {
            ""
        }
        Hostname      = $Hostname
        Docker        = $Script:DockerAvailable
    }

    # Write-then-rename so a crash or power loss mid-write can never leave
    # a truncated state.json behind (which would be read back as "first
    # run" and log a spurious BOOT).
    $TempPath = "$StatePath.tmp"

    $State |
        ConvertTo-Json |
        Set-Content `
            -LiteralPath $TempPath `
            -Encoding UTF8

    Move-Item -LiteralPath $TempPath -Destination $StatePath -Force
}

# ============================================================
# Boot time detection
# ============================================================

function ConvertFrom-SysctlBootTime {
    # Parses `sysctl -n kern.boottime` output, e.g.
    #   { sec = 1700000000, usec = 123456 } Tue Nov 14 22:13:20 2023
    param([string]$Text)

    if ($Text -match 'sec\s*=\s*(\d+)') {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1])
    }

    return $null
}

function Get-BootTimeWindows {
    $OS = Get-CimInstance Win32_OperatingSystem

    return [DateTimeOffset]$OS.LastBootUpTime
}

function Get-BootTimeLinux {

    $Line = Get-Content /proc/stat |
        Where-Object { $_ -match '^btime\s+' } |
        Select-Object -First 1

    if ($Line -match '^btime\s+(\d+)$') {

        return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1])
    }

    return $null
}

function Get-BootTimeMacOS {

    $Result = & sysctl -n kern.boottime 2>$null

    return (ConvertFrom-SysctlBootTime -Text ([string]$Result))
}

function Get-SystemBootTime {

    try {

        if ($detectedWindows) {
            return (Get-BootTimeWindows)
        }

        if ($detectedLinux) {

            $Linux = Get-BootTimeLinux

            if ($null -ne $Linux) {
                return $Linux
            }
        }

        if ($detectedMacOS) {
            return (Get-BootTimeMacOS)
        }
    }
    catch {
        # Boot time is supplemental information.
    }

    return $null
}

# ============================================================
# Startup / reboot detection
# ============================================================

function Invoke-StartupDetection {
    param(
        $PreviousState,
        $CurrentBootTime
    )

    if ($null -ne $PreviousState) {

        try {

            $PreviousHeartbeat = ConvertTo-DateTimeOffsetOrNull (
                Get-JsonPropertyOrNull $PreviousState "LastHeartbeat"
            )

            if ($null -eq $PreviousHeartbeat) {
                throw "state has no usable LastHeartbeat"
            }

            $GapSeconds = (
                [DateTimeOffset]::Now - $PreviousHeartbeat
            ).TotalSeconds

            $PreviousBootTime = ConvertTo-DateTimeOffsetOrNull (
                Get-JsonPropertyOrNull $PreviousState "BootTime"
            )

            # ----------------------------------------------------
            # Actual boot-time change
            # ----------------------------------------------------

            if (
                $null -ne $CurrentBootTime -and
                $null -ne $PreviousBootTime -and
                $CurrentBootTime -ne $PreviousBootTime
            ) {

                Write-EventLog -Event "BOOT" -Data @{
                    BOOT_TIME = $CurrentBootTime.ToString("o", $Script:Invariant)
                }

                Write-EventLog -Event "REBOOT" -Data @{
                    PREVIOUS_BOOT = $PreviousBootTime.ToString("o", $Script:Invariant)
                    CURRENT_BOOT  = $CurrentBootTime.ToString("o", $Script:Invariant)
                }
            }

            # ----------------------------------------------------
            # Long interruption
            # ----------------------------------------------------

            elseif ($GapSeconds -ge $RestartGapSeconds) {

                Write-EventLog -Event "START_AFTER_GAP" -Data @{
                    GAP_SECONDS = [math]::Round($GapSeconds)
                }
            }
        }
        catch {

            Write-EventLog -Event "SERVICE_ERROR" -Data @{
                MESSAGE = "Failed to process previous state: $($_.Exception.Message)"
            }
        }
    }
    else {

        Write-EventLog -Event "BOOT" -Data @{
            BOOT_TIME = if ($null -ne $CurrentBootTime) {
                $CurrentBootTime.ToString("o", $Script:Invariant)
            }
            else {
                "unknown"
            }
        }
    }
}

function Write-ServiceStartEvent {

    Write-EventLog -Event "SERVICE_START" -Data @{
        VERSION    = $Script:GrongoMonitorVersion
        POWERSHELL = $PSVersionTable.PSVersion.ToString()
        OS         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        PLATFORM   = if ($detectedWindows) {
            "Windows"
        }
        elseif ($detectedLinux) {
            "Linux"
        }
        elseif ($detectedMacOS) {
            "macOS"
        }
        else {
            "Unknown"
        }
    }
}

# ============================================================
# Docker
# ============================================================

function Get-DockerServerVersion {
    # Returns the Docker server version string, or $null when the CLI is
    # missing or the daemon is unreachable.
    try {

        if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
            return $null
        }

        $Version = & docker version --format '{{.Server.Version}}' 2>$null

        if ($LASTEXITCODE -eq 0 -and $Version) {
            return [string]$Version
        }
    }
    catch {
        # Docker being unusable just means "no docker monitoring".
    }

    return $null
}

function Test-DockerAvailability {

    if ($NoDocker) {
        return $false
    }

    $Version = Get-DockerServerVersion

    if ($null -eq $Version) {
        return $false
    }

    Write-EventLog -Event "DOCKER_BOOTED" -Data @{
        VERSION = $Version
    }

    return $true
}

function Start-DockerMonitor {

    if (-not $Script:DockerAvailable) {
        return
    }

    try {

        $Process = New-Object System.Diagnostics.Process

        $Process.StartInfo = New-Object `
            System.Diagnostics.ProcessStartInfo

        $Process.StartInfo.FileName = "docker"

        # ProcessStartInfo.Arguments is a single command-line string.
        # Do not assign a PowerShell array here: the JSON format argument
        # contains a space and would be split into multiple argv values,
        # causing Docker to report:
        #   "docker: 'docker events' accepts no arguments"
        #
        # ArgumentList passes each value as one exact argument and avoids
        # shell/quoting behavior entirely.
        [void]$Process.StartInfo.ArgumentList.Add("events")
        [void]$Process.StartInfo.ArgumentList.Add("--format")
        [void]$Process.StartInfo.ArgumentList.Add("{{json .}}")

        $Process.StartInfo.UseShellExecute = $false
        $Process.StartInfo.RedirectStandardOutput = $true
        $Process.StartInfo.RedirectStandardError  = $true
        $Process.StartInfo.CreateNoWindow = $true

        $Process.Start() | Out-Null

        return $Process
    }
    catch {

        Write-EventLog -Event "SERVICE_ERROR" -Data @{
            COMPONENT = "DockerMonitor"
            MESSAGE   = $_.Exception.Message
        }

        return $null
    }
}

function Process-DockerEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    try {

        $Event = $Line | ConvertFrom-Json

        # `docker events` only includes the keys that apply to a given
        # event (exitCode exists on "die" and nowhere else, for example),
        # so nothing here may assume a property is present.
        $Type       = [string](Get-JsonPropertyOrNull $Event "Type")
        $Action     = [string](Get-JsonPropertyOrNull $Event "Action")
        $Actor      = Get-JsonPropertyOrNull $Event "Actor"
        $Attributes = Get-JsonPropertyOrNull $Actor "Attributes"

        $Container = [string](Get-JsonPropertyOrNull $Attributes "name")
        $Image     = [string](Get-JsonPropertyOrNull $Attributes "image")
        $ExitCode  = [string](Get-JsonPropertyOrNull $Attributes "exitCode")

        if ([string]::IsNullOrWhiteSpace($Container)) {
            $Container = [string](Get-JsonPropertyOrNull $Actor "ID")
        }

        # Networks, volumes, images, plugins and swarm objects share
        # action names like "create" with containers. Only containers
        # are reported. (An event with no Type at all is still handled,
        # for older engines.)
        if (-not [string]::IsNullOrWhiteSpace($Type) -and $Type -ne "container") {
            return
        }

        # ----------------------------------------------------
        # Container creation
        # ----------------------------------------------------

        if ($Action -eq "create") {

            Write-EventLog -Event "DOCKER_CREATED" -Data @{
                CONTAINER = $Container
                IMAGE     = $Image
            }

            return
        }

        # ----------------------------------------------------
        # Container started
        # ----------------------------------------------------

        if (
            $Action -eq "start" -or
            $Action -eq "restart"
        ) {

            if ($Action -eq "restart") {

                Write-EventLog -Event "DOCKER_RESTARTED" -Data @{
                    CONTAINER = $Container
                    IMAGE     = $Image
                }
            }
            else {

                Write-EventLog -Event "DOCKER_BOOTED" -Data @{
                    CONTAINER = $Container
                    IMAGE     = $Image
                }
            }

            return
        }

        # ----------------------------------------------------
        # Container stopped
        # ----------------------------------------------------

        if (
            $Action -eq "stop" -or
            $Action -eq "kill"
        ) {

            Write-EventLog -Event "DOCKER_SHUTDOWN" -Data @{
                CONTAINER = $Container
                IMAGE     = $Image
                EXIT_CODE = $ExitCode
            }

            return
        }

        # ----------------------------------------------------
        # Container died
        # ----------------------------------------------------

        if ($Action -eq "die") {

            # Docker exit 137 is commonly associated with SIGKILL.
            # It is frequently caused by an OOM kill, but we don't
            # automatically call it an OS-level OOM event.
            Write-EventLog -Event "DOCKER_CRASHED" -Data @{
                CONTAINER = $Container
                IMAGE     = $Image
                EXIT_CODE = $ExitCode
            }

            return
        }
    }
    catch {

        Write-EventLog -Event "SERVICE_ERROR" -Data @{
            COMPONENT = "DockerEventParser"
            MESSAGE   = $_.Exception.Message
        }
    }
}

function Read-DockerStream {
    # Drains every line that is *already available* from `docker events`
    # without ever blocking. (StreamReader.EndOfStream blocks until data
    # arrives, which used to freeze the whole loop - heartbeats included -
    # on any host whose Docker daemon was quiet.)
    #
    # $Loop.PendingRead holds the in-flight ReadLineAsync task between
    # ticks; $Loop.StreamEnded is set on EOF or a faulted read.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Loop
    )

    $Process = $Loop.DockerProcess

    while ($true) {

        if ($null -eq $Loop.PendingRead) {
            $Loop.PendingRead = $Process.StandardOutput.ReadLineAsync()
        }

        $Task = $Loop.PendingRead

        if (-not $Task.IsCompleted) {
            return
        }

        $Loop.PendingRead = $null

        if ($Task.IsFaulted -or $Task.IsCanceled) {
            $Loop.StreamEnded = $true
            return
        }

        $Line = $Task.Result

        if ($null -eq $Line) {
            $Loop.StreamEnded = $true
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($Line)) {
            Process-DockerEvent -Line $Line
        }
    }
}

function Restart-DockerMonitor {
    # The `docker events` collector (not a Docker container) died. Keep
    # the event distinct so dashboards do not mistake a collector
    # failure for a container crash.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Loop
    )

    $Process = $Loop.DockerProcess

    if (-not $Process.HasExited) {
        try {
            $Process.Kill()
            [void]$Process.WaitForExit(2000)
        }
        catch {
            # Already gone.
        }
    }

    $DockerExitCode = $null

    try {
        $DockerExitCode = $Process.ExitCode
    }
    catch {
        $DockerExitCode = -1
    }

    $DockerError = ""

    try {
        $DockerError = $Process.StandardError.ReadToEnd().Trim()
    }
    catch {
        $DockerError = $_.Exception.Message
    }

    $MonitorData = @{
        COMPONENT = "DockerEventMonitor"
        EXIT_CODE = $DockerExitCode
    }

    if (-not [string]::IsNullOrWhiteSpace($DockerError)) {
        $MonitorData.MESSAGE = $DockerError
    }

    Write-EventLog -Event "DOCKER_MONITOR_FAILED" -Data $MonitorData

    $Process.Dispose()

    $Loop.PendingRead = $null
    $Loop.StreamEnded = $false

    Start-Sleep -Seconds 2

    $Loop.DockerProcess = Start-DockerMonitor

    if ($null -ne $Loop.DockerProcess) {
        Write-EventLog -Event "DOCKER_MONITOR_RESTARTED" -Data @{
            COMPONENT = "DockerEventMonitor"
        }
    }
}

# ============================================================
# Main loop
# ============================================================

function Invoke-MonitorTick {
    # One iteration of the main loop. Never blocks.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Loop
    )

    $Now = [DateTimeOffset]::Now

    # ----------------------------------------------------
    # Heartbeat
    # ----------------------------------------------------

    if (
        ($Now - $Loop.LastHeartbeat).TotalSeconds -ge
        $HeartbeatSeconds
    ) {

        Write-EventLog -Event "HEARTBEAT"

        Save-State

        $Loop.LastHeartbeat = $Now
    }

    # ----------------------------------------------------
    # Docker event stream
    # ----------------------------------------------------

    if ($null -ne $Loop.DockerProcess) {

        Read-DockerStream -Loop $Loop

        if ($Loop.DockerProcess.HasExited -and -not $Loop.StreamEnded) {

            # Give the final buffered lines (written just before the
            # process exited) a moment to arrive before tearing down.
            if ($null -ne $Loop.PendingRead) {
                try { [void]$Loop.PendingRead.Wait(100) } catch { }
            }

            Read-DockerStream -Loop $Loop
        }

        if ($Loop.StreamEnded -or $Loop.DockerProcess.HasExited) {
            Restart-DockerMonitor -Loop $Loop
        }
    }
}

function Test-StopRequested {
    $Type = ([System.Management.Automation.PSTypeName]'GrongoMonitor.StopSignal').Type

    if ($null -eq $Type) {
        return $false
    }

    return [bool]$Type::Requested
}

function Register-StopSignalHandler {
    # `systemctl stop` / `launchctl bootout` send SIGTERM. PowerShell
    # does not run `finally` blocks on SIGTERM, so without this the
    # monitor would vanish without logging SERVICE_STOP or stopping the
    # forwarder. A scriptblock cannot serve as the handler (it runs on a
    # thread with no runspace and crashes the process), hence a tiny
    # compiled helper that only flips a flag the main loop polls.
    #
    # Best effort: on PowerShell < 7.2 (no PosixSignalRegistration) this
    # simply returns $false and behaviour is unchanged.
    try {

        if (-not ([System.Management.Automation.PSTypeName]'GrongoMonitor.StopSignal').Type) {

            Add-Type -IgnoreWarnings -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace GrongoMonitor
{
    public static class StopSignal
    {
        private static volatile bool _requested;
        private static PosixSignalRegistration _term;

        public static bool Requested { get { return _requested; } }

        public static void Reset() { _requested = false; }

        public static void Register()
        {
            if (_term != null) { return; }

            _term = PosixSignalRegistration.Create(
                PosixSignal.SIGTERM,
                ctx => { ctx.Cancel = true; _requested = true; });
        }
    }
}
'@
        }

        [GrongoMonitor.StopSignal]::Register()

        return $true
    }
    catch {
        return $false
    }
}

function Invoke-GrongoMonitor {

    Initialize-MonitorEnvironment

    Initialize-Forwarder

    [void](Register-StopSignalHandler)

    $PreviousState = Read-PreviousState

    $Script:CurrentBootTime = Get-SystemBootTime

    Invoke-StartupDetection `
        -PreviousState $PreviousState `
        -CurrentBootTime $Script:CurrentBootTime

    Write-ServiceStartEvent

    $Script:DockerAvailable = Test-DockerAvailability

    $Loop = @{
        LastHeartbeat = [DateTimeOffset]::MinValue
        DockerProcess = $null
        PendingRead   = $null
        StreamEnded   = $false
    }

    $Loop.DockerProcess = Start-DockerMonitor

    if ($Script:ForwardingEnabled) {

        try {
            Start-EventForwarder
        }
        catch {

            # Forwarding is an enhancement. If it fails to start, log
            # it once and keep monitoring locally - never let this
            # prevent the core monitor from running.
            $Script:ForwardingEnabled = $false

            Write-EventLog -Event "SERVICE_ERROR" -Data @{
                COMPONENT = "EventForwarder"
                MESSAGE   = "Failed to start forwarder: $($_.Exception.Message)"
            }
        }
    }

    try {

        while (-not (Test-StopRequested)) {

            Invoke-MonitorTick -Loop $Loop

            Start-Sleep -Milliseconds 250
        }
    }
    catch {

        Write-EventLog -Event "SERVICE_ERROR" -Data @{
            MESSAGE = $_.Exception.Message
            TYPE    = $_.Exception.GetType().FullName
        }

        Write-EventLog -Event "CRASH"

        throw
    }
    finally {

        # --------------------------------------------------------
        # Normal service termination
        # --------------------------------------------------------

        try {

            if ($null -ne $Loop.DockerProcess) {

                if (-not $Loop.DockerProcess.HasExited) {
                    $Loop.DockerProcess.Kill()
                }

                $Loop.DockerProcess.Dispose()
            }
        }
        catch {
            # Nothing else to do during shutdown.
        }

        if ($Script:ForwardingEnabled) {

            try {
                Stop-EventForwarder
            }
            catch {
                # Nothing else to do during shutdown.
            }
        }

        try {
            Write-EventLog -Event "SERVICE_STOP"
        }
        catch {
            # Logging may be unavailable during system shutdown.
        }
    }
}

# ============================================================
# Entry point
#
# Dot-sourcing (. ./grongoMonitor.ps1) loads the definitions above
# and stops here. That is what lets tests, and anyone poking at the
# script interactively, use the functions without starting the loop.
# ============================================================

if ($MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-GrongoMonitor
