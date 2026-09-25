#!/usr/bin/env bash

set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------

NEXTCLOUD_DIR="/home/stephen/homelab/nextcloud"
BACKUP_ROOT="/home/stephen/backups/nextcloud"
LOG_FILE="/var/log/nextcloud-backup.log"

DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP="$BACKUP_ROOT/$DATE"

MAINTENANCE_ENABLED=0


# -----------------------------
# Logging function
# -----------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}


# -----------------------------
# Cleanup function
# -----------------------------

cleanup() {
    if [ "$MAINTENANCE_ENABLED" -eq 1 ]; then
        log "Disabling Nextcloud maintenance mode..."

        cd "$NEXTCLOUD_DIR"

        docker compose exec -T -u www-data app \
            php occ maintenance:mode --off || true
    fi
}


# Run cleanup whenever the script exits,
# including when a command fails.
trap cleanup EXIT


# -----------------------------
# Start backup
# -----------------------------

log "Starting Nextcloud backup."

mkdir -p "$BACKUP"

cd "$NEXTCLOUD_DIR"


# -----------------------------
# Enable maintenance mode
# -----------------------------

log "Enabling maintenance mode."

docker compose exec -T -u www-data app \
    php occ maintenance:mode --on

MAINTENANCE_ENABLED=1


# -----------------------------
# Find Nextcloud data directory
# -----------------------------

DATADIR=$(docker compose exec -T -u www-data app \
    php occ config:system:get datadirectory | tr -d '\r')

log "Nextcloud data directory: $DATADIR"


# -----------------------------
# Database backup
# -----------------------------

log "Backing up MariaDB database."

docker compose exec -T db sh -c \
    'mariadb-dump \
    --single-transaction \
    --default-character-set=utf8mb4 \
    -u"$MYSQL_USER" \
    -p"$MYSQL_PASSWORD" \
    "$MYSQL_DATABASE"' \
    > "$BACKUP/nextcloud.sql"


# -----------------------------
# Nextcloud configuration
# -----------------------------

log "Backing up Nextcloud configuration."

docker compose cp \
    app:/var/www/html/config \
    "$BACKUP/config"


# -----------------------------
# Nextcloud data
# -----------------------------

log "Backing up Nextcloud data."

docker compose cp \
    "app:$DATADIR" \
    "$BACKUP/data"


# -----------------------------
# Custom apps
# -----------------------------

log "Backing up custom apps."

docker compose cp \
    app:/var/www/html/custom_apps \
    "$BACKUP/custom_apps"


# -----------------------------
# Themes
# -----------------------------

log "Backing up themes."

docker compose cp \
    app:/var/www/html/themes \
    "$BACKUP/themes"


# -----------------------------
# Compose and environment files
# -----------------------------

log "Backing up deployment files."

cp "$NEXTCLOUD_DIR/compose.yaml" "$BACKUP/"
cp "$NEXTCLOUD_DIR/.env" "$BACKUP/"


# -----------------------------
# Nginx configuration
# -----------------------------

log "Backing up Nginx configuration."

cp /etc/nginx/sites-available/nextcloud \
    "$BACKUP/nginx-nextcloud.conf"


# -----------------------------
# Docker image information
# -----------------------------

log "Recording Docker image information."

docker compose images \
    > "$BACKUP/docker-images.txt"

docker inspect nextcloud-app \
    --format '{{.Config.Image}} {{.Image}}' \
    > "$BACKUP/nextcloud-image.txt"


# -----------------------------
# Disable maintenance mode
# -----------------------------

log "Disabling maintenance mode."

docker compose exec -T -u www-data app \
    php occ maintenance:mode --off

MAINTENANCE_ENABLED=0


# -----------------------------
# Verify backup
# -----------------------------

log "Verifying backup."

test -s "$BACKUP/nextcloud.sql"
test -f "$BACKUP/config/config.php"
test -d "$BACKUP/data"
test -f "$BACKUP/compose.yaml"
test -f "$BACKUP/.env"
test -f "$BACKUP/nginx-nextcloud.conf"

log "Backup verification successful."


# -----------------------------
# Protect backup permissions
# -----------------------------

chmod -R go-rwx "$BACKUP"


# -----------------------------
# Retention policy
# Keep backups for 7 days
# -----------------------------

log "Applying retention policy."

#find "$BACKUP_ROOT" \
#    -mindepth 1 \
#    -maxdepth 1 \
#    -type d \
#    -mtime +7 \
#    -exec rm -rf {} \;

# -----------------------------
# Retention policy
# Keep newest 7 backups
# -----------------------------

log "Applying retention policy."

mapfile -t OLD_BACKUPS < <(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%T@ %p\n' \
    | sort -nr \
    | tail -n +8 \
    | cut -d' ' -f2-
)

for OLD_BACKUP in "${OLD_BACKUPS[@]}"; do
    log "Deleting old backup: $OLD_BACKUP"
    rm -rf -- "$OLD_BACKUP"
done


# -----------------------------
# Finished
# -----------------------------

BACKUP_SIZE=$(du -sh "$BACKUP" | cut -f1)

log "Backup completed successfully: $BACKUP ($BACKUP_SIZE)"
