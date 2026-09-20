# grongoMonitor
Lightweight cross-platform system + Docker event monitor. Built-in Pester Suite testing allows for easy manipulation and stable development.
I personally use these logs for a fun and insightful activity log on my website's homepage. https://grongo.dev

## Log format:
  ISO_TIMESTAMP | HOST=name | EVENT=TYPE | KEY=value

Designed for:
  - Hermes / LLM agents
  - Scripts
  - Graylog ingestion
  - Monitoring dashboards
  - Human-readable troubleshooting

## Optional central forwarding:
  Every event written locally is also enqueued to a durable
  on-disk outbox. An independent background runspace batches
  the outbox and transmits it over HTTPS to a central
  grongo event server, with retries and exponential backoff.
  This is purely additive - with no server configured,
  grongoMonitor behaves exactly as it always has, and the
  central server is never a dependency of local monitoring.
  See docs/CONFIGURATION.md.

## Emitted events (kept in sync with the code by tests/Repo.Tests.ps1):
  BOOT REBOOT START_AFTER_GAP
  SERVICE_START SERVICE_STOP SERVICE_ERROR HEARTBEAT CRASH
  DOCKER_CREATED DOCKER_RESTARTED DOCKER_SHUTDOWN
  DOCKER_CRASHED DOCKER_BOOTED
  DOCKER_MONITOR_FAILED DOCKER_MONITOR_RESTARTED
