# Changelog

All notable changes to grongoMonitor. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning: [SemVer](https://semver.org/). The version is `$Script:GrongoMonitorVersion` in
`grongoMonitor.ps1` and is reported in every `SERVICE_START` event (`VERSION=`).

## [1.0.0]

First tagged release: the existing monitor, restructured so it can be tested and deployed
from a git checkout.

### Added
- **Pester test suite** (`tests/`): unit, real-HTTP forwarder and end-to-end tests for the
  monitor; unit and flow tests for the installer; repository hygiene tests.
- `SERVICE_START` now carries `VERSION=`.
- Installer: `-EventTokenFile` (or `$env:GRONGO_EVENT_TOKEN`) for unattended installs,
  `-InstallDir` / `-InPlace`, `-Purge`, input validation, systemd availability check.
- Forwarder: the server URL is validated at startup; an invalid URL logs `SERVICE_ERROR` and
  falls back to local-only monitoring instead of failing silently forever.
- CI (GitHub Actions) on Linux, Windows and macOS, plus install smoke tests.

### Changed
- **The installer copies the monitor into a root/admin-owned directory** (`/opt/grongoMonitor`,
  `/usr/local/lib/grongoMonitor`, `%ProgramFiles%\grongoMonitor`) and the service runs that
  copy. Previously it ran directly out of the checkout as root/SYSTEM. Use `-InPlace` for the
  old behaviour (development only). Update with `git pull` + `-Reinstall`.
- Installer no longer defaults the event-server prompt to any particular server.
- Installer validates the script, the arguments and the token *before* removing a running
  service, and does nothing when a service already exists and `-Reinstall` was not given.
- Token file is created empty and locked down before the secret is written.
- systemd unit: paths are quoted/escaped, `After=` is not duplicated, PowerShell telemetry and
  update checks are disabled for the service.
- `state.json` is written atomically (write, then rename).
- Non-container Docker objects (networks, volumes, images, ...) are ignored; previously a
  network/volume `create` was logged as `DOCKER_CREATED`.
- A blank bearer token now omits the `Authorization` header instead of sending `Bearer `.

### Fixed
- Docker `create`, `start`, `restart`, `stop` and `kill` events were logged as `SERVICE_ERROR`
  (only `die` worked): `exitCode` is absent on those events and StrictMode threw.
- **Heartbeats stopped on a quiet Docker host**: the event loop blocked reading `docker events`
  until the next Docker event arrived. Reads are now non-blocking.
- **`SERVICE_STOP` was never logged under `systemctl stop`** (SIGTERM skipped the `finally`
  block); the monitor now shuts down cleanly on SIGTERM (PowerShell 7.2+).
- Outbox delivery rewrote `TIMESTAMP` and date-valued `DATA` fields through a local-time
  `DateTime` round trip; the exact recorded text is now sent.
- Culture bugs: `state.json` read-back threw on en-GB / de-DE / etc. machines, boot times with
  sub-second precision produced a false `REBOOT` on every restart (typical on Windows), and
  log timestamps were malformed under fi-FI, th-TH, ar-SA and similar cultures.
- A server replying `{}` was treated as a failure (triggering backoff) instead of "no ack".
- An outbox file holding a one-element JSON array was sent as a nested array.
- Helpers threw under StrictMode when given a scalar/array (`config.json` containing `5`).
- `-StatePath` in a different directory from `-LogPath` crashed at the first heartbeat.
- A trailing newline in `$env:GRONGO_EVENT_TOKEN` or whitespace around the server URL broke requests.
- Duplicate `EVENT_ID` files were only removed one per cycle.

### Known limitations (unchanged behaviour, tracked for later)
- `docker events` `die` is always `DOCKER_CRASHED`, including a clean `docker stop` (`EXIT_CODE=0`).
- If the Docker daemon is stopped, the collector restarts every ~2 s (`DOCKER_MONITOR_FAILED` /
  `DOCKER_MONITOR_RESTARTED` pairs) until it comes back.
- A backlog drains at one batch per interval; the outbox and `events.log` are not size-capped
  (see `docs/DEPLOYMENT.md` for logrotate).
- Boot-time comparison is exact: an NTP clock step that shifts `/proc/stat` `btime` reads as a reboot.
- `SHUTDOWN`, `OOM`, `DISK_ERROR`, `NETWORK_CHANGE`, `TIME_CHANGE` are reserved names, not emitted.
