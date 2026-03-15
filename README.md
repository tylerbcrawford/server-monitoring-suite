# Server Monitoring Suite

I got tired of waking up to find a container had been in a restart loop for 8 hours with nobody noticing. These scripts monitor Docker containers, system resources, and SSL certificates, and send Discord alerts when something needs attention.

The cooldown system is the part I'm most happy with — each alert type has its own per-resource cooldown (1 hour for container issues, 4 hours for resource alerts, 1 day for cert warnings), so you get notified about problems without getting spammed about the same issue over and over.

## Features

| Script | What it monitors | Notifications | Cooldown |
|--------|-----------------|---------------|----------|
| `container-health-monitor.sh` | Unhealthy containers, restart loops, high restart counts | Discord | 1 hour per container |
| `resource-alert.sh` | Swap usage (>80%), disk usage (>85%), Docker reclaimable space (>50GB) | Discord | 4 hours per issue |
| `cert-expiry-check.sh` | SSL certificates expiring within 30 days | Discord | 1 day per cert |
| `log-health-check.sh` | Docker logs, journald, app logs, script logs, stray logs | Terminal only | N/A |

## Prerequisites

- **bash** 4.0+
- **docker** (for container monitoring and log checks)
- **curl** (for Discord webhook notifications)
- **certbot** (only for `cert-expiry-check.sh`)
- Standard Linux utilities: `free`, `df`, `du`, `awk`, `journalctl`

## Quick Start

```bash
# Clone the repo
git clone https://github.com/tylerbcrawford/server-monitoring-suite.git
cd server-monitoring-suite

# Create your config
cp .env.example .env
# Edit .env and add your Discord webhook URL

# Make scripts executable
chmod +x *.sh

# Test a script
./container-health-monitor.sh
```

## Cron Setup

Add to your crontab (`crontab -e`):

```cron
# Container health — every 5 minutes
*/5 * * * * /path/to/server-monitoring-suite/container-health-monitor.sh

# Resource alerts — every 15 minutes
*/15 * * * * /path/to/server-monitoring-suite/resource-alert.sh

# SSL cert expiry — daily at 8am
0 8 * * * /path/to/server-monitoring-suite/cert-expiry-check.sh

# Log health audit — weekly on Sunday at 9am
0 9 * * 0 /path/to/server-monitoring-suite/log-health-check.sh >> /var/log/log-health-check.log 2>&1
```

## Script Details

### container-health-monitor.sh

Monitors all running Docker containers for:
- **Unhealthy status** — containers with failing health checks
- **Restarting status** — containers stuck in restart loops
- **High restart counts** — containers that have restarted more than 3 times in their lifetime

Each alert type has an independent 1-hour cooldown per container, so you won't get spammed for the same issue.

### resource-alert.sh

Monitors system-level resource usage:
- **Swap usage** — alerts when swap exceeds 80% capacity
- **Root disk usage** — alerts when the root partition exceeds 85%
- **Docker reclaimable space** — alerts when Docker has more than 50GB of reclaimable space (unused images, build cache, etc.)

Each check has a 4-hour cooldown to avoid repeated alerts for persistent conditions.

### cert-expiry-check.sh

Parses `certbot certificates` output and alerts when any certificate will expire within 30 days. Uses a 1-day cooldown per certificate.

Requires `certbot` to be installed. Configure the certbot binary path:
- Default: `/usr/bin/certbot`
- Override via `CERTBOT_BIN` in `.env` (e.g., for venv installs)

### log-health-check.sh

Audits log sizes across the system and outputs a color-coded report to the terminal. No Discord notifications — designed for manual review or weekly cron logging. Checks:

- **Docker JSON logs** — warns if `/var/lib/docker/containers/` exceeds 500MB
- **Journald** — warns if journal logs exceed 500MB
- **Download client log** — warns if the configured download log exceeds 100MB
- **\*arr app logs** — checks log file counts inside Docker containers (Sonarr, Radarr, etc.)
- **Custom script logs** — checks configured log directories for file count bloat
- **Home directory stray logs** — catches `.log` files that don't belong in `$HOME`

## Configuration

### .env Variables

| Variable | Required | Used by | Description |
|----------|----------|---------|-------------|
| `ADMIN_WEBHOOK_URL` | Yes (for Discord scripts) | container-health-monitor, resource-alert, cert-expiry-check | Discord webhook URL |
| `CERTBOT_BIN` | No | cert-expiry-check | Path to certbot binary (default: `/usr/bin/certbot`) |
| `DOWNLOAD_LOG` | No | log-health-check | Path to download client log file |
| `APP_LOG_DIR` | No | log-health-check | Path to application log directory |
| `EXTRA_LOG_DIRS` | No | log-health-check | Space-separated additional log directories |
| `ARR_SERVICES` | No | log-health-check | Space-separated Docker container names (default: `sonarr radarr prowlarr readarr lidarr`) |

### Overriding .env Location

All Discord-enabled scripts source their webhook URL from `.env` in the same directory as the script by default. To use a different location:

```bash
ENV_FILE=/path/to/your/.env ./container-health-monitor.sh
```

### Customizing log-health-check.sh

Export environment variables or edit the configuration block at the top of the script:

```bash
export DOWNLOAD_LOG=/path/to/nzbget.log
export APP_LOG_DIR=/opt/myapp/logs
export EXTRA_LOG_DIRS="/var/log/scripts /var/log/automation"
export ARR_SERVICES="sonarr radarr prowlarr"
./log-health-check.sh
```

## How Cooldowns Work

Each script uses a temporary directory under `/tmp/` to track when alerts were last sent. A file is created per alert key with a Unix timestamp. On the next run, if the cooldown period hasn't elapsed, the alert is suppressed. Cooldown files are automatically cleaned up on reboot since they live in `/tmp/`.

| Script | Cooldown Directory | Period |
|--------|-------------------|--------|
| container-health-monitor | `/tmp/container-health-cooldown/` | 1 hour |
| resource-alert | `/tmp/resource-alert-cooldown/` | 4 hours |
| cert-expiry-check | `/tmp/cert-expiry-cooldown/` | 1 day |

## License

[MIT](LICENSE)
