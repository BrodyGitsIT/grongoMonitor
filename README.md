# grongoMonitor
Lightweight cross-platform system + Docker event monitor. Built-in Pester Suite testing allows for easy manipulation and stable development.

A lightweight, cross-platform (Windows / Linux / macOS) system and Docker event monitor
written in PowerShell 7. It writes one human- and machine-readable line per event to a local
log, and can optionally forward every event to a central HTTPS collector (see grongoEventServer) 
with a durable on-disk queue, retries and exponential backoff. The collector is never a dependency of
local monitoring. 

I personally use these logs for a fun and insightful activity log on my website's homepage. https://grongo.dev

## Log format:
  ISO_TIMESTAMP | HOST=name | EVENT=TYPE | KEY=value
```
2026-09-13T21:25:23-05:00 | HOST=web01 | EVENT=DOCKER_CRASHED | CONTAINER=nginx-proxy | IMAGE=nginx:1.27 | EXIT_CODE=137
```

Designed for:
  - Scripts
  - Human-readable troubleshooting
  - Hermes / LLM agents
  - Graylog ingestion
  - Monitoring dashboards

## Emitted events (kept in sync with the code by tests/Repo.Tests.ps1):
  BOOT REBOOT START_AFTER_GAP
  SERVICE_START SERVICE_STOP SERVICE_ERROR HEARTBEAT CRASH
  DOCKER_CREATED DOCKER_RESTARTED DOCKER_SHUTDOWN
  DOCKER_CRASHED DOCKER_BOOTED
  DOCKER_MONITOR_FAILED DOCKER_MONITOR_RESTARTED


## Requirements

- PowerShell **7.2+** (`pwsh`). 7.2+ gives a clean `SERVICE_STOP` on `systemctl stop`.
- Root / Administrator to install the service.
- Linux: **systemd**. macOS: launchd. Windows: Task Scheduler.
- Docker is optional; without it the monitor just skips Docker events.

## Install (from a git checkout)

```bash
git clone https://github.com/<you>/grongoMonitor.git
cd grongoMonitor
sudo pwsh ./Install-GrongoMonitor.ps1          # Windows: run PowerShell as Administrator, no sudo
```

That copies `grongoMonitor.ps1` into a root-owned directory and starts a service that runs
it. Check it:

```bash
systemctl status grongoMonitor                 # Linux
sudo tail -f /root/.grongoMonitor/events.log   # Linux; /var/root/... on macOS
```

With central forwarding:

```bash
sudo pwsh ./Install-GrongoMonitor.ps1 -EventServer https://events.example.com
#   prompts for the bearer token (hidden input)

# unattended (Ansible, cloud-init): token from a file, never from the command line
sudo pwsh ./Install-GrongoMonitor.ps1 -EventServer https://events.example.com -EventTokenFile /run/secrets/grongo-token
```

## Update / uninstall

```bash
git pull && sudo pwsh ./Install-GrongoMonitor.ps1 -Reinstall     # config, token and history are kept
sudo pwsh ./Install-GrongoMonitor.ps1 -Uninstall                  # keeps ~/.grongoMonitor data
sudo pwsh ./Install-GrongoMonitor.ps1 -Uninstall -Purge           # removes data too
```

## Installer options

| Parameter | Meaning |
|---|---|
| `-Reinstall` | Replace an existing install (also applies an update or new forwarding settings). Without it, an existing install is left untouched. |
| `-Uninstall` / `-Purge` | Remove the service and staged code; `-Purge` also deletes the data directory. |
| `-EventServer <url>` | Enable forwarding to this `http(s)` collector. No default. |
| `-EventTokenFile <path>` | Read the bearer token from a file (else `$env:GRONGO_EVENT_TOKEN`, else prompt). |
| `-ConfigureEventForwarding` | Enable forwarding and prompt for the server URL. |
| `-EventBatchSize <n>` / `-EventIntervalSeconds <n>` | Forwarding tuning (defaults 50 / 30). |
| `-InstallDir <path>` | Where the service's copy lives (default `/opt/grongoMonitor`, `/usr/local/lib/grongoMonitor`, `%ProgramFiles%\grongoMonitor`). |
| `-InPlace` | Run straight from the checkout. **Development only:** the service runs as root/SYSTEM. |

## Documentation

- [docs/CONFIGURATION.md](docs/CONFIGURATION.md): every setting, the outbox format, the server API contract.
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md): platforms, security model, updates, fleets, log rotation, troubleshooting.
- [CHANGELOG.md](CHANGELOG.md)

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
./tests/Invoke-Tests.ps1                     # everything (~2 min)
./tests/Invoke-Tests.ps1 -SkipIntegration    # faster: no child processes
./tests/Invoke-Tests.ps1 -Path ./tests/Monitor.Docker.Tests.ps1 -Detailed
```

Both scripts are written so that **dot-sourcing them loads the functions and does nothing
else** (`. ./grongoMonitor.ps1`), which is what the tests rely on. Layout:

| Path | Purpose |
|---|---|
| `grongoMonitor.ps1` | The monitor. Everything is a function; `Invoke-GrongoMonitor` is the entry point. |
| `Install-GrongoMonitor.ps1` | Installer: pure builders for unit/plist/task text, thin wrappers around `systemctl`/`launchctl`. |
| `tests/Monitor.*.Tests.ps1` | Unit tests, a real-HTTP stub server for the forwarder, and end-to-end tests that run the script against a fake `docker`. |
| `tests/Installer.*.Tests.ps1` | Definition text and install/uninstall flows with the OS wrappers mocked. |
| `tests/Repo.Tests.ps1` | Docs/code sync (documented events, version vs changelog, no personal defaults). |
| `tests/Helpers/TestHelpers.ps1` | Stub server, fake Docker process, event builders, culture helpers. |

Contributing checklist: add a test with every change; new event names go in the header
comment of `grongoMonitor.ps1`; bump `$Script:GrongoMonitorVersion` **and** add a
`CHANGELOG.md` entry together (a test enforces it).
