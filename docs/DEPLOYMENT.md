# Deployment guide

## Supported environments

| OS | Service manager | Runs as | Code | Data |
|---|---|---|---|---|
| Linux (systemd) | systemd unit `grongoMonitor.service` | root | `/opt/grongoMonitor` | `/root/.grongoMonitor` |
| macOS | launchd daemon `com.grongodev.grongoMonitor` | root | `/usr/local/lib/grongoMonitor` | `/var/root/.grongoMonitor` |
| Windows | Task Scheduler task `grongoMonitor` (at startup) | SYSTEM | `%ProgramFiles%\grongoMonitor` | `C:\Windows\System32\config\systemprofile\.grongoMonitor` |

Not supported by the installer: Linux without systemd (containers, WSL1, Alpine/OpenRC). The
installer detects this and stops with a message; run
`pwsh -NoLogo -NoProfile -File grongoMonitor.ps1` under your own supervisor instead. Set
`HOME` (or pass `-LogPath`, `-StatePath`, `-OutboxPath`, ...) to control where data goes.

The monitor also runs happily unprivileged for a try-out:
`pwsh ./grongoMonitor.ps1 -NoForward` writes to `~/.grongoMonitor`.

## Security model

- The service runs as **root/SYSTEM**, so it must never execute code that ordinary users can
  modify. The installer therefore *copies* the script into a root/admin-owned directory
  (mode 755 dir / 644 file; ACL: SYSTEM+Administrators full, Users read on Windows). A git
  checkout in `/home/you/...` is never executed by the service, and `git pull` or switching
  branches cannot change what a running host is doing. `-InPlace` opts out (development only).
- The bearer token is never a command-line value (no `ps`, shell history, or task-definition
  exposure). It lives in a `600` file in a `700` directory (SYSTEM/Administrators on Windows).
- Use HTTPS to the collector. The installer warns for `http://`; the monitor does not enforce it.
- `-Uninstall` only deletes an install directory that carries the installer's marker file, and
  refuses filesystem roots, top-level system directories and home directories.

## Rolling out to many hosts

Everything is non-interactive when the token comes from a file:

```yaml
# Ansible sketch
- name: Fetch grongoMonitor
  ansible.builtin.git: { repo: https://github.com/<you>/grongoMonitor.git, dest: /opt/src/grongoMonitor, version: v1.0.0 }
- name: Install token
  ansible.builtin.copy: { content: "{{ grongo_token }}", dest: /run/grongo-token, mode: "0600" }
  no_log: true
- name: Install / update
  ansible.builtin.command: >
    pwsh /opt/src/grongoMonitor/Install-GrongoMonitor.ps1 -Reinstall
    -EventServer https://events.example.com -EventTokenFile /run/grongo-token
- name: Remove token
  ansible.builtin.file: { path: /run/grongo-token, state: absent }
```

Pin `version:` to a release tag, not a branch. Each `SERVICE_START` reports `VERSION=`, so
`grep SERVICE_START events.log | tail -1` (or the collector) tells you what a host runs.

## Updating

```bash
cd grongoMonitor && git pull && sudo pwsh ./Install-GrongoMonitor.ps1 -Reinstall
```

The new script is syntax-checked **before** the running service is touched; if the check fails
the old service keeps running. The restart itself is a normal service restart (a `START_AFTER_GAP`
is only logged if the outage exceeded `-RestartGapSeconds`, default 300 s).

## Log rotation

`events.log` and the outbox are not size-capped by the monitor (`grongoMonitor.log` rolls at 5 MB).
The monitor opens `events.log` for every write, so plain rotation without `copytruncate` is safe:

```
# /etc/logrotate.d/grongoMonitor
/root/.grongoMonitor/events.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

If the collector is unreachable for a long time the outbox grows by one small file per event
(about 1,440 heartbeats/day plus Docker events per host). Monitor its size on hosts with long outages.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Nothing in `events.log` | `journalctl -u grongoMonitor -n 50`, then `systemctl status grongoMonitor` |
| `SERVICE_ERROR ... not an absolute http(s) URL` | `server` in `config.json` / `GRONGO_EVENT_SERVER` |
| `SERVICE_ERROR ... no token` | token file present in the *service* home (`/root/.grongoMonitor/token`), not your own |
| Events stay in `outbox/` | `grongoMonitor.log` (in the data directory): `HTTP 401/403` = token, `HTTP 5xx`/timeouts = server or network |
| `DOCKER_MONITOR_FAILED` repeating | Docker daemon stopped or the service user cannot reach the socket |
| `START_AFTER_GAP` on every restart | heartbeat interval much longer than `-RestartGapSeconds` |

## Known limitations

See the end of [CHANGELOG.md](../CHANGELOG.md) for behaviours that are documented and tested as
they are today but that you may want to change.
