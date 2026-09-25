# Stage 7 — Backups and Disaster Recovery

## Goal

Stage 7 adds operational recovery to the homelab. The objective is not only to create backup files, but to prove that the stateful Nextcloud service can be rebuilt from those backups after a simulated server loss.

This stage covers:

- Consistent Nextcloud backups
- MariaDB logical database dumps
- Backup of Nextcloud configuration, user data, custom apps, themes, deployment files, and Nginx configuration
- Automated execution with `systemd`
- Backup validation and retention
- Failure-safe maintenance-mode handling with shell `trap`
- Disaster-recovery testing using an isolated Docker Compose project
- Recovery verification using a known test file

Off-host replication to a second physical machine is planned separately and is not yet implemented.

---

## Backup Architecture

```text
Nextcloud production stack
        |
        +--> Nextcloud data
        +--> MariaDB database
        +--> Nextcloud config
        +--> custom apps / themes
        +--> compose.yaml / .env
        +--> Nginx config
        +--> Docker image metadata
        |
        v
/usr/local/sbin/nextcloud-backup.sh
        |
        +--> enable maintenance mode
        +--> create MariaDB dump
        +--> copy application data/config
        +--> verify backup contents
        +--> disable maintenance mode
        +--> apply retention
        |
        v
/home/stephen/backups/nextcloud/<timestamp>/
```

The backups are currently stored on the same ThinkPad. This protects against application corruption, accidental deletion, failed upgrades, or destroyed Docker volumes, but not against complete physical loss of the ThinkPad or its disk. Off-host backup storage remains a future improvement.

---

## Backup Contents

Each timestamped backup contains the state required to rebuild the Nextcloud deployment:

```text
YYYY-MM-DD_HH-MM-SS/
├── compose.yaml
├── .env
├── config/
│   └── config.php
├── custom_apps/
├── data/
├── docker-images.txt
├── nextcloud-image.txt
├── nextcloud.sql
├── nginx-nextcloud.conf
└── themes/
```

### What each component protects

| Component | Purpose |
|---|---|
| `nextcloud.sql` | MariaDB logical backup containing users, shares, metadata, application state, and database configuration |
| `data/` | Nextcloud user files |
| `config/` | Nextcloud instance configuration |
| `custom_apps/` | Installed custom applications |
| `themes/` | Nextcloud themes |
| `compose.yaml` | Docker Compose deployment definition |
| `.env` | Database/application environment variables and secrets |
| `nginx-nextcloud.conf` | Host Nginx reverse-proxy configuration |
| `docker-images.txt` | Image/version information for recovery |
| `nextcloud-image.txt` | Exact Nextcloud image metadata |

Sensitive backup files are restricted with filesystem permissions and are not committed to Git.

---

## Manual Backup Process

The backup procedure was first validated manually before automation.

### 1. Enable maintenance mode

```bash
docker compose exec -T -u www-data app \
  php occ maintenance:mode --on
```

Maintenance mode prevents users from changing application state during the backup window.

### 2. Determine the Nextcloud data directory

```bash
DATADIR=$(docker compose exec -T -u www-data app \
  php occ config:system:get datadirectory | tr -d '\r')
```

The current deployment uses:

```text
/var/www/html/data
```

### 3. Dump MariaDB

```bash
docker compose exec -T db sh -c \
'mariadb-dump \
--single-transaction \
--default-character-set=utf8mb4 \
-u"$MYSQL_USER" \
-p"$MYSQL_PASSWORD" \
"$MYSQL_DATABASE"' \
> "$BACKUP/nextcloud.sql"
```

A logical dump is used instead of copying the live MariaDB volume directly.

### 4. Copy Nextcloud state

The backup copies:

```text
/var/www/html/config
/var/www/html/data
/var/www/html/custom_apps
/var/www/html/themes
```

as well as `compose.yaml`, `.env`, Nginx configuration, and Docker image metadata.

### 5. Disable maintenance mode

```bash
docker compose exec -T -u www-data app \
  php occ maintenance:mode --off
```

### 6. Verify the backup

Example validation:

```bash
test -s "$BACKUP/nextcloud.sql" && echo "SQL backup exists"
test -f "$BACKUP/config/config.php" && echo "Config backup exists"
test -d "$BACKUP/data" && echo "Data backup exists"
```

The first validated backup was approximately 87 MB, with most of the size coming from the Nextcloud user-data directory.

---

## Automated Backup Script

The backup workflow is implemented in:

```text
/usr/local/sbin/nextcloud-backup.sh
```

The script performs:

```text
1. Create timestamp
2. Create backup directory
3. Enable Nextcloud maintenance mode
4. Determine data directory
5. Dump MariaDB
6. Copy Nextcloud config
7. Copy user data
8. Copy custom apps and themes
9. Copy Compose and environment files
10. Copy Nginx configuration
11. Record Docker image information
12. Disable maintenance mode
13. Verify required backup components
14. Restrict permissions
15. Apply retention policy
16. Log success/failure
```

The script uses defensive shell options:

```bash
set -euo pipefail
```

This causes the script to stop on failed commands, undefined variables, and failures inside pipelines.

### Maintenance-mode cleanup

The script uses a shell trap so that a failed backup does not leave Nextcloud permanently in maintenance mode:

```bash
trap cleanup EXIT INT TERM
```

The cleanup function checks whether the script enabled maintenance mode and disables it when required.

This behavior was tested by deliberately inserting a failing command into the script and verifying that maintenance mode was cleared during cleanup.

---

## systemd Automation

The backup script is executed by a `systemd` oneshot service:

```text
/etc/systemd/system/nextcloud-backup.service
```

Conceptually:

```ini
[Unit]
Description=Nextcloud backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextcloud-backup.sh
User=root
```

A timer schedules the service:

```text
/etc/systemd/system/nextcloud-backup.timer
```

The timer runs the backup daily at 03:00 and uses `Persistent=true`, allowing a missed scheduled run to execute after the host becomes available again.

```text
systemd timer
      |
      v
nextcloud-backup.service
      |
      v
nextcloud-backup.sh
      |
      +--> backup
      +--> verification
      +--> retention
```

### Operational commands

```bash
systemctl status nextcloud-backup.timer
systemctl list-timers | grep nextcloud
sudo systemctl start nextcloud-backup.service
systemctl status nextcloud-backup.service
systemctl show nextcloud-backup.service -p ExecMainStatus
sudo journalctl -u nextcloud-backup.service -n 50
```

A successful oneshot service normally finishes in an inactive state with:

```text
ExecMainStatus=0
```

---

## Retention

The current retention model is designed around keeping a small number of recent successful backups rather than allowing unlimited timestamped backup directories to accumulate.

The intended current policy is:

```text
Daily backup
Keep latest 7 successful backups
```

Retention is applied only after the newly created backup has passed validation. This prevents an old valid backup from being removed before the replacement backup has been confirmed usable.

Longer-term retention such as daily/weekly/monthly tiers can be introduced later with a dedicated backup tool or snapshot strategy.

---

# Disaster Recovery Test

## Recovery Objective

The DR test simulated the following condition:

```text
Production server lost
        ↓
Only backup available
        ↓
Create fresh Docker Compose environment
        ↓
Restore database + application state
        ↓
Verify known file
```

The production Nextcloud stack was not destroyed. Instead, recovery was performed in a separate Docker Compose project on the same ThinkPad.

---

## Known Recovery File

Before creating the recovery-point backup, a known file was created inside production Nextcloud:

```text
DR-Test.txt
```

with identifiable content.

The final recovery test was considered successful only when this file was visible and readable in the restored DR instance.

---

## Isolated DR Environment

A separate recovery directory was created:

```text
~/homelab/nextcloud-dr
```

The backup's `compose.yaml` and `.env` were copied into this directory.

The DR Compose project used the explicit project name:

```bash
docker compose -p nextcloud-dr ...
```

This ensured that DR resources were isolated from production.

### Production vs DR resources

```text
Production
nextcloud_nextcloud_data
nextcloud_nextcloud_db
127.0.0.1:8082

DR
nextcloud-dr_nextcloud_data
nextcloud-dr_nextcloud_db
127.0.0.1:18082
```

Fixed `container_name` entries were removed from the DR Compose file to prevent container-name conflicts with production.

The DR app binding was changed from:

```text
127.0.0.1:8082:80
```

to:

```text
127.0.0.1:18082:80
```

The DR instance used `dr.homelab` and HTTP rather than the production public hostname and TLS path.

---

## Database Restore

Only the fresh DR MariaDB and Redis services were started initially:

```bash
docker compose -p nextcloud-dr up -d db redis
```

The SQL backup was then imported into the fresh DR database:

```bash
sudo cat "$LATEST/nextcloud.sql" | \
docker compose -p nextcloud-dr exec -T db sh -c \
'mariadb \
-u"$MYSQL_USER" \
-p"$MYSQL_PASSWORD" \
"$MYSQL_DATABASE"'
```

Database tables were checked after import to confirm successful restoration.

---

## Application Restore

The DR app container and data volume were created separately from production.

Nextcloud state was restored into the DR volume:

```text
config/
data/
custom_apps/
themes/
```

Ownership was corrected inside the container so Apache/Nextcloud could access the restored files.

---

## DR Initialization Issue

During the first recovery attempt, the DR app container was started before the restored filesystem was in place.

The container logs showed:

```text
Initializing nextcloud ...
New nextcloud instance
```

This indicated that the official Nextcloud container saw an empty `/var/www/html` volume and initialized a fresh installation.

The DR app/container volume was reset, the backup contents were restored first, and only then was the application started.

This established the correct recovery order:

```text
Fresh DR volume
      ↓
Restore backup filesystem
      ↓
Restore database
      ↓
Start application
```

rather than:

```text
Fresh DR volume
      ↓
Start application
      ↓
Fresh Nextcloud initializes
      ↓
Attempt restore afterward
```

---

## Local DR Access

The DR service remained bound to loopback:

```text
127.0.0.1:18082
```

The Mac accessed it through an SSH tunnel:

```bash
ssh -L 18082:127.0.0.1:18082 homelab
```

The Mac `/etc/hosts` file contained:

```text
127.0.0.1 dr.homelab
```

The request path was:

```text
Mac browser
   ↓
dr.homelab -> 127.0.0.1
   ↓
Mac localhost:18082
   ↓
SSH tunnel
   ↓
ThinkPad 127.0.0.1:18082
   ↓
DR Nextcloud container
```

---

## 503 Maintenance-Mode Troubleshooting

The restored instance initially returned:

```text
HTTP/1.1 503 Service Unavailable
X-Nextcloud-Maintenance-Mode: 1
```

Network checks showed that the request path was working:

- The Mac had an SSH listener on `localhost:18082`
- The ThinkPad had Docker listening on `127.0.0.1:18082`
- `curl` reached Apache and Nextcloud successfully

Therefore the failure was at the application layer, not the network layer.

### Root cause

The backup copied `config.php` while production Nextcloud was in maintenance mode. The restored DR instance therefore inherited maintenance mode.

### Fix

```bash
docker compose -p nextcloud-dr exec -u www-data app \
  php occ maintenance:mode --off
```

After maintenance mode was disabled, the DR instance became accessible.

This was an important troubleshooting lesson:

```text
503 from Nextcloud
      ≠
network failure
```

If the TCP path, Docker listener, SSH tunnel, and Apache response are all working, inspect Nextcloud application state before changing networking.

---

## Recovery Verification

The disaster-recovery test succeeded when all of the following were confirmed:

- DR Nextcloud started successfully
- Existing user account could log in
- Restored files were visible
- `DR-Test.txt` was present
- `DR-Test.txt` contained the expected content
- Database state was restored
- The DR service was reachable through the isolated SSH-tunnel path

This demonstrated that the backup set was sufficient to rebuild the stateful Nextcloud service.

---

## Recovery Concepts Learned

### RPO — Recovery Point Objective

The backup schedule determines how much recent data could be lost after a failure.

With one successful backup per day, the worst-case recovery point is approximately one day before the failure.

### RTO — Recovery Time Objective

The restore exercise provides a practical measurement of how long it takes to rebuild the service from backup.

Future DR tests can record the elapsed time from recovery start to successful validation of the restored application.

---

## Stage 7 Result

Stage 7 added operational recovery to the homelab:

```text
Stateful Nextcloud workload
        ↓
consistent backup
        ↓
automated systemd execution
        ↓
verification
        ↓
retention
        ↓
isolated disaster-recovery environment
        ↓
database + filesystem restore
        ↓
validated recovered application
```

The remaining resilience gap is off-host storage. The current backups reside on the same physical ThinkPad as production. A future stage can replicate backups to a second Linux machine or dedicated storage system so that complete ThinkPad or disk loss is also recoverable.

