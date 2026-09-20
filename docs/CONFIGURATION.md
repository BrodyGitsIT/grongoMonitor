# grongoMonitor — Configuration and Central Event Forwarding

This document covers the optional central-forwarding upgrade to grongoMonitor:
configuration, the on-disk queue format, retry/backoff behavior, event IDs and
idempotency, the API contract the (separately-built) central server needs to
implement, a test procedure, and how to upgrade an existing installation.

Everything here is **additive**. With no server configured, grongoMonitor
behaves exactly as it always has: local `events.log`, local `state.json`,
nothing else.

---

## 1. What changed, at a glance

- Every event `Write-EventLog` writes to `events.log` (unchanged format) is
  also enqueued as one small JSON file in a local **outbox** directory.
- An independent background thread (a PowerShell runspace, not a child
  process) periodically batches the outbox and POSTs it to a central server
  over HTTPS.
- Delivered events are removed from the outbox only after the server
  acknowledges them by `EVENT_ID`. Anything not acknowledged stays queued and
  is retried, with exponential backoff, forever (or until the outbox is
  manually cleared).
- The forwarder cannot block, slow down, or crash local monitoring. It shares
  no PowerShell state with the main thread — only the filesystem and a couple
  of thread-safe signaling primitives.

---

## 2. Configuration

Every forwarder setting has this precedence, highest first:

1. Explicit script parameter (`-EventServer`, `-EventBatchSize`, `-EventIntervalSeconds`)
2. Environment variable
3. `~/.grongoMonitor/config.json`
4. Built-in default

The token is resolved separately (see below) and is never a script parameter,
so it can't leak into a process list, Task Scheduler task definition,
systemd unit, or `ps` output.

| Setting | Env var | config.json key | Default |
|---|---|---|---|
| Server base URL | `GRONGO_EVENT_SERVER` | `server` | *(none — forwarder disabled)* |
| Batch size | `GRONGO_EVENT_BATCH_SIZE` | `batchSize` | 50 |
| Send interval | `GRONGO_EVENT_INTERVAL` | `intervalSeconds` | 30 |
| Max backoff | `GRONGO_EVENT_MAX_BACKOFF_SECONDS` | `maxBackoffSeconds` | 900 (15 min) |
| Token | `GRONGO_EVENT_TOKEN` | *(never — use the token file)* | *(none)* |

The server URL must be an absolute `http://` or `https://` URL. Anything else (a bare
hostname, `ftp://`, a typo) is rejected at startup with a `SERVICE_ERROR` and the monitor
continues local-only. A trailing slash and surrounding whitespace are ignored. Tokens are
trimmed, so a trailing newline in the token file or environment variable is harmless.

**Forwarding only activates if a server URL resolves from somewhere.** No
server configured anywhere = no outbox writes, no background thread, zero
added overhead. This is checked once at startup.

### 2.1 `~/.grongoMonitor/config.json` (non-secret)

```json
{
  "server": "https://events.example.com",
  "batchSize": 50,
  "intervalSeconds": 30,
  "maxBackoffSeconds": 900
}
```

Any subset of keys is fine — missing keys fall through to env vars, then
defaults.

### 2.2 `~/.grongoMonitor/token` (secret)

Plain text, single line, the bearer token and nothing else. Restrict its
permissions (`chmod 600` on Linux/macOS — the installer does this
automatically if it writes the file for you).

The token is **never** written to `events.log` and **never** appears in
`grongoMonitor.log` diagnostics.

### 2.3 Command line

```bash
pwsh ./grongoMonitor.ps1 `
    -EventServer "https://events.example.com" `
    -EventBatchSize 75 `
    -EventIntervalSeconds 45
```

(Token intentionally has no equivalent parameter — use the env var or the
token file.)

### 2.4 Disabling forwarding explicitly

```bash
pwsh ./grongoMonitor.ps1 -NoForward
```

### 2.5 Installer shortcut

```bash
sudo pwsh ./Install-GrongoMonitor.ps1 -EventServer "https://events.example.com"
# prompts for the bearer token with hidden input

# unattended: the token comes from a file (or $env:GRONGO_EVENT_TOKEN), never from an argument
sudo pwsh ./Install-GrongoMonitor.ps1 -EventServer "https://events.example.com" -EventTokenFile /run/secrets/grongo-token
```

This writes `config.json` and `token` into the **service account's** data directory
(`/root/.grongoMonitor` on Linux, `/var/root/.grongoMonitor` on macOS,
`C:\Windows\System32\config\systemprofile\.grongoMonitor` on Windows). The installer picks
that directory explicitly, so a plain `sudo` works. The data
directory is created `700` and the token `600` (locked to SYSTEM/Administrators on Windows),
and the token file is locked down *before* the secret is written into it.

Existing non-secret settings in `config.json` are preserved unless you pass
`-EventBatchSize` / `-EventIntervalSeconds`. To change forwarding settings on an installed
host, re-run with `-Reinstall`.

If the server URL is not an absolute `http(s)` URL the installer refuses to continue, and the
monitor itself logs one `SERVICE_ERROR` and stays local-only.

---

## 3. The outbox / durable queue

Location: `~/.grongoMonitor/outbox/` (override with `-OutboxPath`).

**Format:** one JSON file per event.

Filename: `<19-digit zero-padded UTC ticks>_<EVENT_ID>.json`

Ticks-based, zero-padded filenames sort lexicographically in exact
chronological order, so the forwarder picks the oldest batch with a plain
`Sort-Object Name` — no index file, no re-parsing every event just to figure
out ordering.

File contents:

```json
{
  "EVENT_ID": "7f7d9d7a-1234-4a5b-9c0d-abcdef123456",
  "TIMESTAMP": "2026-09-13T21:25:23-05:00",
  "HOST": "pop-os",
  "EVENT": "DOCKER_CRASHED",
  "DATA": {
    "CONTAINER": "nginx-proxy",
    "IMAGE": "jc21/nginx-proxy-manager",
    "EXIT_CODE": "1"
  }
}
```

**Write path:** `Add-OutboxEvent` writes to a temp file
(`.tmp-<EVENT_ID>`), then does an atomic rename to the final filename. A
reader (the forwarder thread) can never observe a half-written file. A crash
in the narrow window between the temp write and the rename leaves an orphan
temp file; the forwarder sweeps anything named `.tmp-*` older than 5 minutes
as a safety net.

**Deletion:** only after the server acknowledges the specific `EVENT_ID` in
its response. Never speculatively, never on a bare 2xx with no
acknowledgement body.

**Corrupt files:** if a file in the outbox is not a single JSON object, fails to parse, or is
missing `EVENT_ID`, it's renamed to `<name>.json.corrupt` (so it stops matching the
`*.json` glob and doesn't loop forever) and logged to `grongoMonitor.log`.
It is not silently deleted — you can inspect it.

---

## 4. Batch transmission & retry behavior

- The forwarder wakes on whichever comes first: the configured interval
  elapsing, or an outbox that has just filled a full batch (an in-memory
  counter in `Add-OutboxEvent` signals an `AutoResetEvent` the moment enough
  events have queued — no polling loop, no extra thread).
- Each wake, it takes up to `EventBatchSize` of the oldest queued events and
  POSTs them in a single request.
- **Success (2xx with a usable `accepted` list):** acknowledged files are
  deleted; the interval resets to the configured base.
- **Success (2xx, but no `accepted` list, or an unparseable body):** nothing
  is deleted. This is deliberately conservative — an ambiguous
  acknowledgement is treated as "don't know," and the server's own dedup
  makes a safe retry possible.
- **Failure** (DNS failure, connection refused, timeout, TLS failure, any
  4xx/5xx): nothing is deleted, and the interval doubles, capped at
  `maxBackoffSeconds` (default 15 minutes), with a small random jitter so a
  fleet of hosts doesn't retry in lockstep after a shared outage.
- Diagnostics for all of the above go to `grongoMonitor.log`, **not**
  `events.log` — network status is never mixed into the human-readable
  system event log, and a retry never generates a heartbeat.

---

## 5. Event IDs & idempotency (at-least-once delivery)

Every event gets a GUID `EVENT_ID` the moment it's logged, stable across every
retry of that event. The client's delivery model is **at-least-once**: it is
possible (and expected, under real network conditions) for the server to
receive the same `EVENT_ID` more than once — for example, if the client sent
a batch, the server ingested it, and the acknowledgement was lost before the
client could act on it. The client will retry that batch.

**This means the server must deduplicate on `EVENT_ID`.** The client never
tries to guess whether a prior attempt "probably" succeeded — it only trusts
an explicit `accepted` acknowledgement.

---

## 6. API contract (for the central server)

This client is built against the following contract. The server is a
separate component and is not part of this deliverable, but the client's
behavior above only makes sense against this shape.

### Request

```
POST {GRONGO_EVENT_SERVER}/api/v1/events/batch
Content-Type: application/json
Authorization: Bearer <token>

{
  "host": "pop-os",
  "events": [
    {
      "EVENT_ID": "7f7d9d7a-1234-4a5b-9c0d-abcdef123456",
      "TIMESTAMP": "2026-09-13T21:25:23-05:00",
      "HOST": "pop-os",
      "EVENT": "DOCKER_CRASHED",
      "DATA": { "CONTAINER": "nginx-proxy", "EXIT_CODE": "1" }
    }
  ]
}
```

- `TIMESTAMP` is ISO-8601 with the **originating machine's own UTC offset**,
  exactly as recorded locally. The client sends the outbox file's text verbatim (it is parsed
  only to validate it and read `EVENT_ID`), so neither the offset nor date-valued `DATA`
  fields such as `BOOT_TIME` are ever rewritten. The server must preserve them as-is and must
  not convert them to server-local time.
- With no token configured the `Authorization` header is omitted entirely.
- `DATA` is an open object — its keys vary per event type and mirror the
  `KEY=VALUE` pairs in `events.log`.

### Response (success)

```json
{ "accepted": ["7f7d9d7a-1234-4a5b-9c0d-abcdef123456"] }
```

`accepted` lists every `EVENT_ID` from the request the server has durably
ingested (i.e., ingested such that a duplicate resend would be safely
deduplicated). IDs omitted from `accepted` are assumed not-yet-safe and will
be retried by the client — including IDs the server actually did receive
correctly but failed to list, so the server's own dedup is the real safety
net, not this list.

### Expected status handling

| Condition | Client behavior |
|---|---|
| 2xx + valid `accepted` array | Delete acknowledged IDs, reset backoff |
| 2xx, no/invalid `accepted` array | Keep everything queued, reset backoff (connectivity is fine) |
| 401/403 | Keep everything queued, back off (check the token) |
| 408/429/5xx | Keep everything queued, back off |
| DNS/connection/TLS/timeout failure | Keep everything queued, back off |

The server should implement idempotent ingestion keyed on `EVENT_ID` (e.g. a
unique constraint / upsert), since the same batch may arrive more than once
by design.

---

## 7. Performance characteristics

- Enqueuing an event is one small local file write per event (same order of
  magnitude as the existing `events.log` append) — no network I/O on the
  event-detection path, ever.
- The forwarder wakes on an interval measured in tens of seconds (default
  30s), not a tight polling loop, and only lists the outbox directory (not
  the whole tree recursively, not `events.log`) on each wake.
- HTTP calls run on a separate thread with a bounded timeout (15s), so a
  slow/unavailable server cannot stall Docker event processing or delay the
  heartbeat.
- Docker event streaming is untouched — still a long-lived `docker events`
  subprocess, no polling.

---

## 8. Testing

The scenarios below are all covered by the automated suite in `tests/` (see the README); this
list is for verifying a real deployment by hand.

### Normal operation
1. Configure `GRONGO_EVENT_SERVER` (and a token) against a real or stub
   server that returns `{"accepted": [...]}` for every ID it receives.
2. Start grongoMonitor. Trigger a few events (e.g. `docker restart` on some
   container).
3. Confirm: `events.log` has the events; `outbox/` briefly has matching
   files, then they disappear within one interval; `grongoMonitor.log` shows
   "Batch delivered."

### Server offline
1. Point `GRONGO_EVENT_SERVER` at an address that will refuse connections
   (or stop your stub server).
2. Trigger events. Confirm they land in `events.log` and stay in `outbox/`.
3. Confirm `grongoMonitor.log` shows failures with growing backoff intervals,
   and that `events.log` shows no network-status noise and heartbeats
   continue on schedule.

### Server returns
1. With events queued from the previous step, bring the server back.
2. Within `maxBackoffSeconds`, confirm the queued files are picked up,
   delivered, and removed from `outbox/`.

### Reboot / restart
1. Queue events with the server offline (or with `-NoForward` briefly, then
   restart without it to prove persistence isn't tied to a live sender).
2. Restart the machine (or just the grongoMonitor process).
3. Confirm `outbox/` still has the pre-restart events, and that they are
   delivered once the process is back up and the server is reachable.

### Duplicate transmission / dedup
1. Configure a stub server that ingests a batch but **doesn't respond**
   (simulating a lost acknowledgement).
2. Confirm the client retries the same `EVENT_ID`s.
3. Confirm your server-side dedup rejects/no-ops the second copy rather than
   creating duplicate records.

### High event volume
1. Generate a burst of Docker events (start/stop many containers quickly).
2. Confirm the immediate-wake signal fires once a full batch has queued
   (check `grongoMonitor.log` timestamps against the configured interval),
   and that CPU/memory stay flat — no busy loop, no full-log re-reads.

### Long outage
1. Leave the server unreachable for an extended period (hours).
2. Confirm `outbox/` grows but the process stays healthy, `grongoMonitor.log`
   rolls over at 5MB instead of growing unbounded, and backoff has capped at
   `maxBackoffSeconds` rather than continuing to grow or hammering the
   server.

---

## 9. Upgrade / migration from an existing installation

From a git checkout, on each host:

```bash
git pull
sudo pwsh ./Install-GrongoMonitor.ps1 -Reinstall
```

`-Reinstall` validates the new script first, stops the old service, copies the new script into
the root-owned install directory, and starts the new service. `config.json`, the token,
`events.log`, `state.json` and the outbox are all kept.

Upgrading from an early install that ran the script **directly from the checkout**: the same
command moves the service onto the staged copy (`/opt/grongoMonitor` etc.); nothing else changes.

Upgrading from the pre-rebrand "System Event Monitor" (`~/.system-event-monitor/`): back it up,
then `mv ~/.system-event-monitor ~/.grongoMonitor` if you want to keep `events.log` and
`state.json` history, and run the two commands above.

Forwarding is entirely opt-in: with no event-related configuration, the upgraded monitor
behaves as before, with the outbox directory created but unused.
