# Swarm Backup Docker Container

This repository contains a minimal Docker image to automate **Docker Swarm service backups** using a shell-based backup system. The container supports environment-based configuration, Swarm service scaling, snapshot retention policies, secrets, email notifications, and optional root execution.

The design follows a **wrapper + application script** model, making it easy to reuse common backup logic across multiple platforms.

---

## Features

- Snapshot-style incremental backups using `rsync --link-dest`
- Creates a **single timestamped snapshot directory per run**
- Hard-link deduplication from previous backups (`latest`)
- Optional Docker Swarm service scale-down/up during backup
- Pluggable backup retention policies: **GFS**, **FIFO**, **Calendar**
- Automatic creation of daily, weekly, and monthly snapshots (for GFS)
- Runs as non-root user with configurable UID/GID or optionally as root (`RUN_AS_ROOT`)
- Lightweight Alpine base image
- Email notifications on success and/or failure
- **DRY-RUN mode** for safe testing without modifying data

---

## Retention Policies

- **GFS (Grandfather-Father-Son)**: Retain daily, weekly, and monthly snapshots.
- **FIFO (First-In-First-Out)**: Keep a fixed number of most recent snapshots.
- **Calendar**: Keep snapshots for a fixed number of days.

Retention behavior is controlled via environment variables and operates on **snapshot directories**, not individual files.

---

## Directory Layout

```
/backup/
└── daily/
    └── 2025-12-13_00-00-00/
        └── snapshot/
    └── 2025-12-14_00-00-00/
        └── snapshot/
└── weekly/
    └── 2025-12-07_00-00-00/
        └── snapshot/
└── monthly/
    └── 2025-12-01_00-00-00/
        └── snapshot/
└── latest -> daily/2025-12-14_00-00-00

```

## Environment Variables

| Variable            | Default                                | Description |
|---------------------|----------------------------------------|-------------|
| APP_NAME            | `Swarm`                                | Application name in status notifications |
| BACKUP_SRC          | `/data`                                | Source directory to back up |
| BACKUP_DEST         | `/backup`                              | Directory where backups are stored |
| SCALE_LABEL         | `com.example.autobackup.enable`        | Label to identify services for scaling |
| SCALE_VALUE         | `true`                                 | Value of label required for scaling |
| EMAIL_ON_SUCCESS    | `false`                                | Send email when backup succeeds |
| EMAIL_ON_FAILURE    | `true`                                 | Send email when backup fails |
| EMAIL_TO            | `admin@example.com`                    | Recipient of email notifications |
| EMAIL_FROM          | `backup@example.com`                   | Sender address for emails |
| SMTP_SERVER         | `smtp.example.com`                     | SMTP server hostname or IP |
| SMTP_PORT           | `25`                                   | SMTP server port |
| SMTP_TLS            | `off`                                  | Enable TLS (`off` / `on`) |
| SMTP_USER           | *(empty)*                              | SMTP username |
| SMTP_USER_FILE      | *(empty)*                              | File or secret containing SMTP username |
| SMTP_PASS           | *(empty)*                              | SMTP password |
| SMTP_PASS_FILE      | *(empty)*                              | File or secret containing SMTP password |
| RETENTION_POLICY    | `gfs`                                  | Retention strategy: `gfs`, `fifo`, or `calendar` |
| GFS_DAILY           | `7`                                    | Number of daily snapshots to keep (GFS) |
| GFS_WEEKLY          | `4`                                    | Number of weekly snapshots to keep (GFS) |
| GFS_MONTHLY         | `6`                                    | Number of monthly snapshots to keep (GFS) |
| FIFO_COUNT          | `14`                                   | Number of snapshots to retain (FIFO) |
| CALENDAR_DAYS       | `30`                                   | Number of days to retain snapshots (Calendar) |
| TZ                  | `America/Chicago`                      | Timezone used for timestamps |
| USER_UID            | `3000`                                 | UID of backup user (non-root) |
| USER_GID            | `3000`                                 | GID of backup user (non-root) |
| DEBUG               | `false`                                | Keep container running after backup |
| DRY_RUN             | `false`                                | Simulate backup without writing or scaling |
| RUN_AS_ROOT         | `false`                                | Run backup as root instead of non-root user |

---

## Swarm Secret Format

The servers file (typically stored as a Docker Swarm secret) must contain one host per line:

```
/run/secrets/smtp_user -> SMTP_USER
/run/secrets/smtp_pass -> SMTP_PASS
```

> **Security Note**  
> SMTP credentials should be stored as Swarm secrets to prevent plaintext exposure.

---

## Service Scaling Behavior

Before running a backup, services with the label specified in `SCALE_LABEL` matching `SCALE_VALUE` are scaled down:

- **Global services**: Constraints are added to temporarily pause execution.
- **Replicated services**: Scaled down to 0 replicas.
- The original service state is captured to allow safe rollback if the backup fails.

After the backup:

- Services are restored to their original state.
- Waits for each service to reach the desired number of running tasks before continuing.
- Logs all scale-down and restore actions.

**Diagram**:

```
[Backup Start]
|
v
[Capture service state]
|
v
[Scale down matching services] <-- Global & Replicated
|
v
[Run rsync backup]
|
v
[Apply retention policies]
|
v
[Restore original service state]
|
v
[Backup complete]
```

---

## Docker Compose Example (Swarm)

```yaml
version: "3.9"

services:
  backup-swarm:
    image: your-dockerhub-username/backup-swarm:latest

    volumes:
      - /data:/data:ro
      - /backup:/backup
      - /var/run/docker.sock:/var/run/docker.sock:ro

    environment:
      BACKUP_SRC: /data
      BACKUP_DEST: /backup
      SCALE_LABEL: "com.example.autobackup.enable"
      SCALE_VALUE: "true"
      RETENTION_POLICY: gfs
      DAILY_COUNT: "7"
      WEEKLY_COUNT: "4"
      MONTHLY_COUNT: "6"
      EMAIL_ON_SUCCESS: "off"
      EMAIL_ON_FAILURE: "on"
      SMTP_SERVER: "smtp.example.com"
      SMTP_PORT: "587"
      SMTP_TLS: "on"
      EMAIL_FROM: "backup@example.com"
      TZ: "America/Chicago"
      DRY_RUN: "false"
      RUN_AS_ROOT: "false"

    secrets:
      - smtp_user
      - smtp_pass

    deploy:
      mode: replicated
      replicas: 0
      restart_policy:
        condition: none
      placement:
        constraints:
          - node.role == manager

secrets:
  smtp_user:
    external: true
  smtp_pass:
    external: true
```
## Local Testing

To test without Swarm:

```bash
docker run -it --rm \
  -v /backup:/backup \
  -v ./data:/data:ro \
  -e BACKUP_DEST=/backup \
  -e DRY_RUN=true \
  your-dockerhub-username/backup-swarm:latest
```

Change `RETENTION_POLICY` to `fifo` or `calendar` to test other modes.

---

## Failure Semantics

- If **any backup step fails**, the container exits with a non-zero code.
- On failure:
  - The snapshot directory is preserved for inspection.
  - Retention policies are **not applied**.
  - Failure notifications are sent if enabled.

---

## Logging

- Logs are written to /var/log/backup.log and a per-run log in /tmp/backup_run_<pid>.log.
- Email notifications contain only the per-run log.
- Logs pruning actions according to the selected retention policy.
- Swarm service scaling actions are logged.

---

## Notes

- UID/GID customization ensures backup files match host filesystem ownership.
- `RUN_AS_ROOT` allows elevated permissions for certain backup targets.
- Pluggable retention policies allow flexible backup management:
  - **GFS**: Daily/weekly/monthly snapshots with `latest` symlink.
  - **FIFO**: Keeps only the last `FIFO_COUNT` snapshots.
  - **Calendar**: Keeps all snapshots for a specified number of days.
- Use `DRY_RUN=true` to safely test backup and retention behavior without modifying files.