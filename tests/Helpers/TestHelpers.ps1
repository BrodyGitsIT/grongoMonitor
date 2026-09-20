# ============================================================
# Shared helpers for the grongoMonitor Pester suite.
#
# Dot-source from BeforeAll (and BeforeDiscovery when a helper is
# needed in a -Skip expression):
#
#   BeforeAll { . (Join-Path $PSScriptRoot 'Helpers/TestHelpers.ps1') }
#
# Nothing here touches the real HOME or any real service.
# ============================================================

$Script:RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Script:MonitorScript = Join-Path $Script:RepoRoot 'grongoMonitor.ps1'
$Script:InstallScript = Join-Path $Script:RepoRoot 'Install-GrongoMonitor.ps1'

# ------------------------------------------------------------
# Sandbox
# ------------------------------------------------------------

function New-TestRoot {
    $Path = Join-Path ([System.IO.Path]::GetTempPath()) ("gm-test-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return $Path
}

function Get-MonitorParameters {
    # Parameters that point every path the monitor uses into $Root.
    param([Parameter(Mandatory)][string]$Root)

    return @{
        LogPath          = Join-Path $Root 'events.log'
        StatePath        = Join-Path $Root 'state.json'
        OutboxPath       = Join-Path $Root 'outbox'
        ForwarderLogPath = Join-Path $Root 'grongoMonitor.log'
        EventConfigPath  = Join-Path $Root 'config.json'
        EventTokenPath   = Join-Path $Root 'token'
    }
}

function Reset-TestRoot {
    # Empties the sandbox and recreates the outbox. Called from BeforeEach.
    param([Parameter(Mandatory)][string]$Root)

    Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path (Join-Path $Root 'outbox') -Force | Out-Null
}

function Remove-TestRoot {
    param([string]$Root)

    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# Reading what the monitor wrote
# ------------------------------------------------------------

function Read-EventLogRecords {
    # Parses events.log into objects: Timestamp, Host, Event, Data (hashtable).
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $Records = foreach ($Line in @(Get-Content -LiteralPath $Path)) {

        if ([string]::IsNullOrWhiteSpace($Line)) { continue }

        $Parts = $Line -split ' \| '
        $Data  = @{}

        for ($i = 3; $i -lt $Parts.Count; $i++) {
            $Index = $Parts[$i].IndexOf('=')
            if ($Index -gt 0) {
                $Data[$Parts[$i].Substring(0, $Index)] = $Parts[$i].Substring($Index + 1)
            }
        }

        [pscustomobject]@{
            Line      = $Line
            Timestamp = $Parts[0]
            Host      = ($Parts[1] -replace '^HOST=', '')
            Event     = ($Parts[2] -replace '^EVENT=', '')
            Data      = $Data
        }
    }

    return @($Records)
}

function Get-EventNames {
    param([Parameter(Mandatory)][string]$Path)

    return @(Read-EventLogRecords -Path $Path | ForEach-Object { $_.Event })
}

function Get-OutboxFiles {
    param([Parameter(Mandatory)][string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Write-OutboxEventFile {
    # Drops a well-formed outbox file, as Add-OutboxEvent would.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$EventId = ([guid]::NewGuid().ToString()),
        [string]$Timestamp = '2026-09-13T21:25:23-05:00',
        [string]$EventType = 'HEARTBEAT',
        [hashtable]$Data = @{},
        [long]$Ticks = 0
    )

    if ($Ticks -eq 0) { $Ticks = [DateTimeOffset]::UtcNow.Ticks }

    $Json = [ordered]@{
        EVENT_ID  = $EventId
        TIMESTAMP = $Timestamp
        HOST      = 'test-host'
        EVENT     = $EventType
        DATA      = $Data
    } | ConvertTo-Json -Depth 6 -Compress

    $File = Join-Path $Path ("{0:D19}_{1}.json" -f $Ticks, $EventId)
    Set-Content -LiteralPath $File -Value $Json -Encoding UTF8 -NoNewline

    return $File
}

# ------------------------------------------------------------
# Docker fakes
# ------------------------------------------------------------

function New-DockerEventJson {
    # Builds one line of `docker events --format '{{json .}}'` output.
    # Only the keys real Docker sends for that event are included, which is
    # the whole point: exitCode exists on "die" and nowhere else.
    param(
        [string]$Action = 'start',
        [string]$Type = 'container',
        [string]$Name = 'web',
        [string]$Image = 'nginx:latest',
        [string]$ExitCode,
        [string]$Id = 'a1b2c3d4e5f6',
        [switch]$NoName,
        [switch]$NoAttributes,
        [switch]$NoActor,
        [switch]$NoType
    )

    $Attributes = [ordered]@{ image = $Image }

    if (-not $NoName)          { $Attributes['name'] = $Name }
    if ($PSBoundParameters.ContainsKey('ExitCode')) { $Attributes['exitCode'] = $ExitCode }

    $Actor = [ordered]@{ ID = $Id }
    if (-not $NoAttributes) { $Actor['Attributes'] = $Attributes }

    $EventObject = [ordered]@{ status = $Action }
    if (-not $NoType)  { $EventObject['Type'] = $Type }
    $EventObject['Action'] = $Action
    if (-not $NoActor) { $EventObject['Actor'] = $Actor }
    $EventObject['scope'] = 'local'
    $EventObject['time'] = 1700000000

    return ($EventObject | ConvertTo-Json -Depth 6 -Compress)
}

function New-FakeDockerProcess {
    # A duck-typed stand-in for System.Diagnostics.Process. Lines are handed
    # out through ReadLineAsync exactly like a StreamReader would; when the
    # queue is empty the read stays pending (a quiet daemon) or reports EOF.
    param(
        [string[]]$Lines = @(),
        [ValidateSet('Pending', 'Eof')][string]$After = 'Pending',
        [int]$ExitCode = 0,
        [string]$StdErr = ''
    )

    $Shared = @{
        Queue   = [System.Collections.Queue]::new()
        Pending = $null
        After   = $After
    }

    foreach ($Line in $Lines) { $Shared.Queue.Enqueue($Line) }

    $StdOut = [pscustomobject]@{ Shared = $Shared }

    $StdOut | Add-Member -MemberType ScriptMethod -Name ReadLineAsync -Value {

        if ($this.Shared.Queue.Count -gt 0) {
            return [System.Threading.Tasks.Task]::FromResult([string]$this.Shared.Queue.Dequeue())
        }

        if ($this.Shared.After -eq 'Eof') {
            # A real StreamReader yields a genuine $null at EOF ([string]$null
            # would be "" in PowerShell), so build the task explicitly.
            $Eof = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
            $Eof.SetResult([NullString]::Value)
            return $Eof.Task
        }

        if ($null -eq $this.Shared.Pending) {
            $this.Shared.Pending = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
        }

        return $this.Shared.Pending.Task
    }

    $StdErrReader = [pscustomobject]@{ Text = $StdErr }
    $StdErrReader | Add-Member -MemberType ScriptMethod -Name ReadToEnd -Value { $this.Text }

    $Process = [pscustomobject]@{
        HasExited      = $false
        ExitCode       = $ExitCode
        Killed         = $false
        Disposed       = $false
        StandardOutput = $StdOut
        StandardError  = $StdErrReader
        Shared         = $Shared
    }

    $Process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $this.Killed = $true
        $this.HasExited = $true
    }
    $Process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
    $Process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }

    # Deliver a line "later" (completes an in-flight pending read if there is one).
    $Process | Add-Member -MemberType ScriptMethod -Name Push -Value {
        param([string]$Line)

        if ($null -ne $this.Shared.Pending) {
            $Pending = $this.Shared.Pending
            $this.Shared.Pending = $null
            $Pending.SetResult($Line)
        }
        else {
            $this.Shared.Queue.Enqueue($Line)
        }
    }

    return $Process
}

# ------------------------------------------------------------
# Culture
# ------------------------------------------------------------

function Test-CultureAvailable {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $Culture = [System.Globalization.CultureInfo]::GetCultureInfo($Name)

        # In globalization-invariant mode every name silently maps to invariant.
        return ($Culture.Name -eq $Name)
    }
    catch {
        return $false
    }
}

function Use-Culture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )

    $Thread   = [System.Threading.Thread]::CurrentThread
    $Original = $Thread.CurrentCulture

    try {
        $Thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Name)
        & $Script
    }
    finally {
        $Thread.CurrentCulture = $Original
    }
}

# ------------------------------------------------------------
# Stub central event server (real HTTP, no mocks)
#
# Modes (set $Server.State.Mode at any time):
#   Accept     200 {"accepted":[every EVENT_ID received]}      (default)
#   AcceptSome 200 accepting only the first $State.AcceptCount IDs
#   NoAck      200 {}                       (2xx without an accepted list)
#   NullAck    200 {"accepted":null}
#   EmptyAck   200 {"accepted":[]}
#   Text       200 text/plain "ok"          (unparseable body)
#   Status     <State.StatusCode> {"error":"x"}                (401, 500, ...)
#   Hang       never answers within the client timeout
# ------------------------------------------------------------

function Start-StubEventServer {
    param([string]$Mode = 'Accept')

    $Probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $Probe.Start()
    $Port = $Probe.LocalEndpoint.Port
    $Probe.Stop()

    $State = [hashtable]::Synchronized(@{
        Mode        = $Mode
        StatusCode  = 500
        AcceptCount = 0
        Stop        = $false
        Ready       = $false
        Error       = $null
        Requests    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    })

    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.Open()

    $PS = [powershell]::Create()
    $PS.Runspace = $Runspace

    [void]$PS.AddScript({
        param($Port, $State)

        $Listener = [System.Net.HttpListener]::new()
        $Listener.Prefixes.Add("http://127.0.0.1:$Port/")

        try {
            $Listener.Start()
            $State.Ready = $true

            while (-not $State.Stop) {

                $Task = $Listener.GetContextAsync()

                while (-not $Task.Wait(100)) {
                    if ($State.Stop) { return }
                }

                $Context  = $Task.Result
                $Request  = $Context.Request
                $Response = $Context.Response

                $Reader = [System.IO.StreamReader]::new($Request.InputStream, [System.Text.Encoding]::UTF8)
                $Body   = $Reader.ReadToEnd()
                $Reader.Dispose()

                [void]$State.Requests.Add(@{
                    Method        = $Request.HttpMethod
                    Path          = $Request.Url.AbsolutePath
                    Authorization = $Request.Headers['Authorization']
                    ContentType   = $Request.ContentType
                    Body          = $Body
                })

                $Status = 200
                $Type   = 'application/json'
                $Text   = '{}'

                $Ids = @()
                try {
                    $Parsed = $Body | ConvertFrom-Json
                    $Ids = @($Parsed.events | ForEach-Object { [string]$_.EVENT_ID })
                }
                catch { }

                switch ($State.Mode) {
                    'Accept'     { $Text = (@{ accepted = $Ids } | ConvertTo-Json -Compress) }
                    'AcceptSome' { $Text = (@{ accepted = @($Ids | Select-Object -First $State.AcceptCount) } | ConvertTo-Json -Compress) }
                    'NoAck'      { $Text = '{}' }
                    'NullAck'    { $Text = '{"accepted":null}' }
                    'EmptyAck'   { $Text = '{"accepted":[]}' }
                    'Text'       { $Type = 'text/plain'; $Text = 'ok' }
                    'Status'     { $Status = [int]$State.StatusCode; $Text = '{"error":"x"}' }
                    'Hang' {
                        for ($i = 0; $i -lt 100 -and -not $State.Stop; $i++) { Start-Sleep -Milliseconds 100 }
                    }
                }

                try {
                    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
                    $Response.StatusCode = $Status
                    $Response.ContentType = $Type
                    $Response.ContentLength64 = $Bytes.Length
                    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
                    $Response.OutputStream.Close()
                }
                catch { }
            }
        }
        catch {
            $State.Error = $_.Exception.Message
        }
        finally {
            try { $Listener.Stop(); $Listener.Close() } catch { }
        }
    }).AddArgument($Port).AddArgument($State)

    $Handle = $PS.BeginInvoke()

    $Deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $State.Ready -and -not $State.Error -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 25
    }

    if (-not $State.Ready) {
        throw "Stub event server failed to start: $($State.Error)"
    }

    return [pscustomobject]@{
        Url        = "http://127.0.0.1:$Port"
        Port       = $Port
        State      = $State
        PowerShell = $PS
        Runspace   = $Runspace
        Handle     = $Handle
    }
}

function Stop-StubEventServer {
    param($Server)

    if ($null -eq $Server) { return }

    $Server.State.Stop = $true

    try { [void]$Server.Handle.AsyncWaitHandle.WaitOne(3000) } catch { }
    try { $Server.PowerShell.Dispose() } catch { }
    try { $Server.Runspace.Dispose() } catch { }
}

function Wait-Until {
    # Polls a condition; returns $true as soon as it holds, $false on timeout.
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 15,
        [int]$IntervalMilliseconds = 100
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $Deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }

    return [bool](& $Condition)
}
