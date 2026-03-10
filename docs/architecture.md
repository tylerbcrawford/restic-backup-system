# Architecture

## Module Flow

```
backup-orchestrator.sh
│
├── lib/config.sh          ← All env vars, paths, thresholds
├── lib/common.sh          ← log(), warn(), err(), acquire_lock(), preflight(), run_module()
├── lib/discord-notify.sh  ← send_discord_summary(), send_discord_warning(), send_discord_error()
│   └── lib/branding.sh   ← BOT_USERNAME, BOT_AVATAR_URL
│
├── [--daily mode]
│   ├── modules/backup-volumes.sh        → restic backup (Docker volumes via container)
│   ├── modules/backup-plex-db.sh        → restic backup (Plex DB only)
│   ├── modules/backup-system-configs.sh → restic backup (staged system configs)
│   ├── modules/backup-home.sh           → restic backup (home dir with exclusions)
│   └── modules/offsite-sync.sh          → rclone sync to Google Drive
│
├── [--weekly mode, adds:]
│   ├── modules/prune-snapshots.sh       → restic forget --prune
│   └── modules/verify-backup.sh         → restic check + freshness + space checks
│
└── Discord summary embed (per-module results, duration, repo size)
```

## Orchestrator Pattern

The orchestrator (`backup-orchestrator.sh`) is the only script you schedule via cron. It:

1. **Parses arguments** to determine mode (`--daily`, `--weekly`, `--dry-run`)
2. **Sources libraries** — config, common functions, Discord notifications
3. **Acquires a lock** — prevents concurrent backup runs via PID file
4. **Runs preflight checks** — restic accessible, password file exists, disk space OK
5. **Executes modules sequentially** using `run_module()`, which:
   - Logs start/stop timestamps
   - Captures exit code
   - Records results in an associative array
   - Does NOT stop on failure (all modules run regardless)
6. **Sends a Discord summary** with per-module pass/fail, total duration, and repo size
7. **Releases the lock** on exit (via trap)

## Configuration Centralization

All configuration lives in `lib/config.sh`. Every module sources this file, so there's a single source of truth for:

- Repository paths and credentials
- Docker paths and volume names
- Retention policy numbers
- Alert thresholds
- Discord webhook URL
- Home directory exclusion patterns

Environment variables override defaults, making it easy to configure via `.env` file.

## Discord Notifications

The notification system uses Discord webhook embeds:

- **`_send_embed()`** — Low-level function that builds a JSON payload with title, description, color, footer, and timestamp, then POSTs to the webhook URL
- **`send_discord_summary()`** — End-of-run summary with per-module results (checkmark/X icons), duration, and repo size
- **`send_discord_warning()`** — Yellow embed for non-fatal alerts (low disk space, stale snapshots)
- **`send_discord_error()`** — Red embed for critical failures

Bot identity (username, avatar) is configured in `lib/branding.sh`.

## Retention Policy

The pruning module (`prune-snapshots.sh`) uses restic's `forget` command with `--group-by "paths,tags"`:

| Tier | Default | Meaning |
|------|---------|---------|
| Daily | 7 | Keep the most recent snapshot from each of the last 7 days |
| Weekly | 4 | Keep the most recent snapshot from each of the last 4 weeks |
| Monthly | 6 | Keep the most recent snapshot from each of the last 6 months |

Each backup module tags its snapshots (`volumes`, `plex-db`, `system-configs`, `home`), so retention is applied per-tag. This means you keep 7 daily volume snapshots AND 7 daily home snapshots independently.

## Docker Volume Backup Strategy

Docker volumes aren't directly accessible from the host filesystem. The backup module solves this by:

1. Mounting all target volumes read-only into a `restic/restic` container
2. Running `restic backup` inside the container, pointing at the mounted data
3. Using the official restic image (statically-linked binary) to avoid glibc/musl incompatibilities

The Plex volume is handled separately because only the database directory (~1GB) matters, not the full volume (~40GB+ of regenerable media cache).

## Extras: System Image Backup

The `extras/system-backup.sh` script provides a different backup tier: full partition-level `dd` images. This complements the restic file-level backups:

- **restic** — granular file recovery, deduplication, incremental
- **dd image** — bare-metal disaster recovery, bootable restore

The system backup stops all Docker containers to ensure filesystem consistency, creates compressed images of the EFI and root partitions, saves the partition table, generates a manifest, then restarts Docker. A background progress monitor polls `/proc/<pid>/fdinfo` to show real-time progress.
