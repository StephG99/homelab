# Homelab

A self-hosted Linux homelab built on Ubuntu for learning Linux
administration, networking, Docker, observability, reverse proxies, DNS,
TLS, infrastructure security, stateful application hosting, backups,
disaster recovery, and centralized logging.

## Architecture

``` mermaid
flowchart TD
    Internet["Internet"]
    DNS["Public DNS<br/>stephen-homelab.com"]
    Router["Home Router<br/>NAT / Port Forwarding<br/>TCP 80 / 443"]
    UFW["UFW Firewall"]
    Mac["MacBook Air<br/>LAN Administration"]

    Nginx["Native Nginx<br/>Reverse Proxy + TLS<br/>Ports 80 / 443"]
    App["Docker Nginx Test App<br/>127.0.0.1:8080"]
    Nextcloud["Nextcloud App<br/>127.0.0.1:8082"]
    MariaDB["MariaDB"]
    Redis["Redis"]
    Cron["Nextcloud Cron"]
    NCData["Nextcloud Persistent Data"]
    DBData["MariaDB Persistent Data"]

    Grafana["Grafana<br/>127.0.0.1:3000"]
    Prometheus["Prometheus"]
    Cadvisor["cAdvisor"]
    NodeExporter["Node Exporter<br/>Host Network :9100"]

    NginxLogs["/var/log/nginx/*.log"]
    DockerAPI["Docker daemon<br/>/var/run/docker.sock"]
    Journal["systemd journal"]
    Alloy["Grafana Alloy<br/>Log Collector"]
    Loki["Grafana Loki<br/>Log Store + LogQL"]

    BackupTimer["systemd Timer"]
    BackupService["nextcloud-backup.service"]
    BackupScript["nextcloud-backup.sh"]
    LocalBackup["Local Timestamped Backups"]
    DR["Isolated DR Restore<br/>nextcloud-dr<br/>127.0.0.1:18082"]

    Internet --> DNS --> Router --> UFW --> Nginx
    Mac -->|"SSH"| UFW
    Mac -->|"grafana.homelab"| Nginx

    Nginx -->|"app.stephen-homelab.com<br/>127.0.0.1:8080"| App
    Nginx -->|"cloud.stephen-homelab.com<br/>127.0.0.1:8082"| Nextcloud
    Nginx -->|"grafana.homelab<br/>127.0.0.1:3000"| Grafana

    Nextcloud --> MariaDB
    Nextcloud --> Redis
    Cron --> NCData
    Nextcloud --> NCData
    MariaDB --> DBData

    Grafana -->|"PromQL"| Prometheus
    Prometheus -->|"cadvisor:8080"| Cadvisor
    Prometheus -->|"192.168.1.98:9100"| NodeExporter

    Nginx --> NginxLogs
    NginxLogs -->|"loki.source.file"| Alloy
    DockerAPI -->|"loki.source.docker"| Alloy
    Journal -->|"loki.source.journal"| Alloy
    Alloy -->|"push logs"| Loki
    Grafana -->|"LogQL"| Loki

    BackupTimer --> BackupService --> BackupScript
    NCData --> BackupScript
    MariaDB -->|"mariadb-dump"| BackupScript
    BackupScript --> LocalBackup
    LocalBackup -.->|"restore test"| DR
```

### Architecture Overview

The ThinkPad acts as the Ubuntu homelab server and has the reserved LAN
address `192.168.1.98`.

Public traffic for `app.stephen-homelab.com` and
`cloud.stephen-homelab.com` resolves through public DNS to the home
router. The router forwards TCP ports 80 and 443 to the ThinkPad, where
UFW controls inbound traffic and native Nginx acts as the reverse proxy
and TLS termination point.

Native Nginx routes requests based on hostname:

-   `app.stephen-homelab.com` → `127.0.0.1:8080` → Docker Nginx test
    application
-   `cloud.stephen-homelab.com` → `127.0.0.1:8082` → Nextcloud
-   `grafana.homelab` → `127.0.0.1:3000` → Grafana

Nextcloud runs as a multi-container application using:

-   **Nextcloud** --- web application and file service
-   **MariaDB** --- database and application metadata
-   **Redis** --- caching and file locking
-   **Nextcloud Cron** --- scheduled background processing
-   **Persistent Docker volumes** --- production Nextcloud and MariaDB
    state

MariaDB and Redis are not published to the host and are only reachable
through the private Docker network.

The backup and recovery layer adds:

-   **`nextcloud-backup.sh`** --- performs a consistent backup workflow
    using maintenance mode, a MariaDB logical dump, filesystem copies,
    verification, logging, and retention
-   **`nextcloud-backup.service`** --- `systemd` oneshot service that
    runs the backup script
-   **`nextcloud-backup.timer`** --- triggers the backup service on a
    daily schedule
-   **Local timestamped backup repository** --- stores copied Nextcloud
    data, MariaDB dumps, configuration, deployment files, Nginx
    configuration, and image metadata
-   **Isolated DR restore environment** --- separate Docker Compose
    project used to verify that the saved backup can rebuild the service
    without modifying production

The production Docker volumes and the local backup repository are
logically separate:

``` text
Production Nextcloud volume
        |
        | filesystem copy
        v
nextcloud-backup.sh
        |
        v
/home/stephen/backups/nextcloud/<timestamp>/
```

For the database:

``` text
MariaDB production volume
        |
        v
MariaDB container
        |
        | mariadb-dump
        v
nextcloud-backup.sh
        |
        v
nextcloud.sql
```

The backup repository therefore does **not** use the same Docker volumes
as the production application. If a production Docker volume is deleted
or corrupted, the timestamped backup remains available for restoration.

However, the production volumes and the backup repository currently
reside on the same physical ThinkPad storage. This means the current
design protects against logical failures such as application corruption,
accidental deletion, broken Docker volumes, or failed upgrades, but it
does not protect against complete disk or hardware loss.

A future off-host backup layer will provide physical separation:

``` text
ThinkPad
├── Production Docker volumes
└── Local backup repository
        |
        | rsync / restic / borg
        v
Separate backup machine / NAS / external storage
```

The disaster-recovery test restores from the local backup repository
into a separate Docker Compose project named `nextcloud-dr`. The DR
environment uses independent Docker volumes and a separate loopback port
(`127.0.0.1:18082`), so restore testing does not modify the production
Nextcloud deployment.

The monitoring stack consists of:

-   **Grafana** --- visualization and dashboards
-   **Prometheus** --- metrics collection and storage
-   **cAdvisor** --- Docker container metrics
-   **Node Exporter** --- ThinkPad host metrics

Grafana queries Prometheus over Docker networking using
`prometheus:9090`. Prometheus scrapes cAdvisor over the Docker network
using `cadvisor:8080`.

Node Exporter uses `network_mode: host` so it can observe the ThinkPad's
actual network interfaces and host metrics. Prometheus reaches Node
Exporter through `192.168.1.98:9100`.

The centralized logging stack consists of:

-   **Grafana Alloy** --- collects native Nginx files, Docker container
    logs, and systemd journal events
-   **Grafana Loki** --- stores log streams and serves LogQL queries
-   **Grafana** --- provides a common interface for metrics and log
    investigation

Alloy reads native Nginx logs through a read-only bind mount, discovers
containers through `/var/run/docker.sock`, and reads host service events
from the systemd journal. Alloy forwards all three sources to Loki over
the internal Docker network. Loki is not host-published; Grafana queries
it using `http://loki:3100`.

This creates two complementary observability paths:

``` text
Node Exporter / cAdvisor → Prometheus → Grafana
Nginx / Docker / journald → Alloy → Loki → Grafana
```

Unnecessary monitoring host exposure was reduced:

-   Grafana is bound to `127.0.0.1:3000`
-   Prometheus is not host-published
-   cAdvisor is not host-published
-   Node Exporter remains available on port `9100` through the
    restricted monitoring path

## Repository Structure

``` text
homelab-repo/
├── README.md
├── .gitignore
│
├── etc/
│   └── nginx/
│       └── sites-available/
│           ├── app.stephen-homelab.com
│           ├── grafana
│           └── nextcloud
│
├── homelab/
│   ├── monitoring/
│   │   ├── compose.yaml
│   │   ├── prometheus/
│   │   │   └── prometheus.yml
│   │   ├── loki-config.yaml
│   │   └── alloy/
│   │       └── config.alloy
│   │
│   ├── nginx/
│   │   └── html/
│   │       └── index.html
│   │
│   └── nextcloud/
│       ├── compose.yaml
│       └── .env.example
│
├── systemd/
│   ├── nextcloud-backup.service
│   └── nextcloud-backup.timer
│
├── scripts/
│   └── nextcloud-backup.sh
│
└── docs/
    ├── architecture.md
    ├── stage-01-linux-ssh.md
    ├── stage-02-nginx.md
    ├── stage-03-docker.md
    ├── stage-04-monitoring.md
    ├── stage-05-reverse-proxy-tls.md
    ├── stage-06-nextcloud.md
    ├── stage-07-backups-and-disaster-recovery.md
    └── stage-08-centralized-logging.md
```

The repository mirrors selected parts of the live ThinkPad
configuration.

Runtime data, backup contents, credentials, `.env` files, private SSH
keys, TLS private keys, certificates, database contents, Nextcloud user
data, and other sensitive files are intentionally excluded.

## Completed Stages

### Stage 1 --- Linux & SSH

-   Configured Ubuntu host
-   Configured SSH key authentication
-   Enabled UFW firewall
-   Configured DHCP reservation for a stable LAN IP
-   Practiced Linux networking, service management, socket inspection,
    and system diagnostics

### Stage 2 --- Native Nginx

-   Installed Nginx directly on Ubuntu
-   Deployed a basic HTTP service
-   Practiced service management, socket inspection, HTTP testing, and
    logging

### Stage 3 --- Docker

-   Installed Docker CE
-   Deployed a containerized Nginx web service
-   Configured container networking
-   Configured port publishing
-   Used bind mounts for persistent web content
-   Hardened the backend by changing the container binding from
    `0.0.0.0:8080` to `127.0.0.1:8080`

### Stage 4 --- Observability

-   Deployed Prometheus and Grafana
-   Added Node Exporter for host metrics
-   Added cAdvisor for container metrics
-   Built Grafana dashboards for CPU, memory, disk, network, and uptime
-   Configured Node Exporter with host networking to observe the
    ThinkPad's actual interfaces
-   Used PromQL to query host and network metrics
-   Diagnosed a real high-CPU issue involving `systemd-logind`
-   Reduced unnecessary monitoring host exposure

### Stage 5 --- Reverse Proxy, DNS & TLS

-   Configured native Nginx as the reverse proxy
-   Configured local hostname resolution for private services
-   Registered and configured a public domain
-   Configured public DNS
-   Configured router NAT / port forwarding for TCP 80 and 443
-   Configured UFW rules
-   Obtained Let's Encrypt TLS certificates using Certbot
-   Configured HTTPS and HTTP-to-HTTPS redirection
-   Restricted backend Docker services from unnecessary network exposure
-   Verified TLS certificates, certificate chains, and SNI behavior

### Stage 6 --- Nextcloud

-   Deployed Nextcloud as a multi-container Docker Compose application
-   Deployed MariaDB as the Nextcloud database
-   Added Redis for caching and file locking
-   Added a dedicated Nextcloud cron container for background jobs
-   Configured persistent Docker volumes for Nextcloud and MariaDB
-   Restricted Nextcloud to `127.0.0.1:8082`
-   Kept MariaDB and Redis private inside the Docker network
-   Configured `cloud.stephen-homelab.com`
-   Configured native Nginx as the Nextcloud reverse proxy
-   Configured HTTPS using Let's Encrypt and Certbot
-   Configured Nextcloud for reverse-proxy HTTPS awareness
-   Verified Nextcloud access through web and mobile clients
-   Enabled separate user accounts for personal, friends, and family
    access
-   Integrated the new containers into the existing cAdvisor /
    Prometheus / Grafana monitoring architecture

### Stage 7 --- Backups & Disaster Recovery

-   Created consistent Nextcloud backups using maintenance mode
-   Created logical MariaDB backups using `mariadb-dump`
-   Backed up Nextcloud data, configuration, custom apps, themes,
    Compose files, `.env`, Nginx configuration, and Docker image
    metadata
-   Added validation checks for the database dump, configuration, and
    data directory
-   Implemented a reusable backup script with `set -euo pipefail`
-   Added `trap`-based cleanup so failed backups do not leave Nextcloud
    in maintenance mode
-   Automated backups with a `systemd` oneshot service and daily timer
-   Added logging through both the script and `journald`
-   Implemented backup retention for recent successful backups
-   Created an isolated `nextcloud-dr` Docker Compose project for
    restore testing
-   Restored MariaDB, Nextcloud configuration, user data, apps, and
    themes into fresh DR volumes
-   Used a separate loopback port (`127.0.0.1:18082`) and SSH tunnel for
    safe DR access
-   Diagnosed a DR initialization issue caused by starting Nextcloud
    before restoring the application filesystem
-   Diagnosed a restored `503 Service Unavailable` as inherited
    Nextcloud maintenance mode rather than a networking failure
-   Successfully logged into the restored DR instance and verified the
    known `DR-Test.txt` recovery file
-   Confirmed that the backup set is sufficient to rebuild the stateful
    Nextcloud service

### Stage 8 --- Centralized Logging

-   Deployed Grafana Loki as the centralized log storage and LogQL query
    backend
-   Deployed Grafana Alloy as the log collector and forwarder
-   Collected native Nginx access and error logs using file discovery
    and `loki.source.file`
-   Collected Docker container stdout/stderr using Docker discovery and
    `loki.source.docker`
-   Added Docker metadata labels including container, Compose service,
    and Compose project
-   Collected host and service events from the systemd journal using
    `loki.source.journal`
-   Added Loki as a Grafana data source over the internal Docker network
-   Queried and filtered logs using LogQL
-   Validated the Nginx logging path end-to-end from a client HTTP
    request through Nginx, Alloy, Loki, and Grafana
-   Used disposable diagnostic containers to test Loki without exposing
    port 3100 to the host
-   Kept Loki internal to the Docker network with no public or
    host-published port
-   Learned the distinction between native file logs, container
    stdout/stderr, and systemd service events

## Current Public Request Flow

``` text
Internet
   ↓
Public DNS
   ↓
Home public IPv4
   ↓
Router
   ↓
TCP 80 / 443
   ↓
ThinkPad 192.168.1.98
   ↓
UFW
   ↓
Native Nginx
   ├── app.stephen-homelab.com
   │      ↓
   │   127.0.0.1:8080
   │      ↓
   │   Docker Nginx
   │
   └── cloud.stephen-homelab.com
          ↓
       127.0.0.1:8082
          ↓
       Nextcloud
          ├── MariaDB
          ├── Redis
          ├── Cron
          └── Persistent Storage
```

## Backup and Recovery Flow

``` text
Daily systemd timer
        ↓
nextcloud-backup.service
        ↓
nextcloud-backup.sh
        ↓
maintenance mode ON
        ↓
MariaDB dump + Nextcloud data/config backup
        ↓
backup verification
        ↓
maintenance mode OFF
        ↓
retention
        ↓
/home/stephen/backups/nextcloud/<timestamp>
        ↓
manual DR restore test
        ↓
nextcloud-dr isolated Compose project
        ↓
recovered Nextcloud instance
```

## Security Model

The homelab currently follows these principles:

-   Public web traffic enters only through native Nginx
-   Only TCP ports 80 and 443 are forwarded from the router
-   SSH is not publicly forwarded
-   Backend applications are bound to loopback where possible
-   MariaDB and Redis are not host-published
-   Grafana is bound to loopback
-   Prometheus, cAdvisor, and Loki communicate over Docker networking
    rather than unnecessary host-published ports
-   Node Exporter access is restricted to the required monitoring path
-   Nginx log and systemd journal mounts into Alloy are read-only
-   Loki is not publicly exposed
-   Docker socket access is limited to the trusted Alloy collector and
    treated as a privileged host integration
-   TLS terminates at native Nginx
-   Secrets and `.env` files are excluded from Git
-   TLS private keys are never committed or shared
-   Backup contents are excluded from Git and protected with restrictive
    filesystem permissions
-   Disaster-recovery testing uses separate Docker project names,
    volumes, and loopback ports to avoid modifying production

## Current Learning Progression

``` text
Stage 1
Linux + SSH + Networking
        ↓
Stage 2
Native Nginx
        ↓
Stage 3
Docker
        ↓
Stage 4
Prometheus + Grafana + Observability
        ↓
Stage 5
Reverse Proxy + DNS + NAT + TLS
        ↓
Stage 6
Nextcloud + MariaDB + Redis + Persistent Storage
        ↓
Stage 7
Backups + systemd Automation + Restore Testing + Disaster Recovery
        ↓
Stage 8
Centralized Logging + Alloy + Loki + LogQL
```

Stage 7 moved the homelab from simply hosting a stateful service to
operating and recovering it. The Nextcloud workload now has a tested
backup-and-restore path, including MariaDB recovery, filesystem
restoration, application-state troubleshooting, and isolated DR
validation.

Stage 8 extended observability beyond Prometheus metrics by centralizing
native Nginx logs, Docker container logs, and systemd journal events
through Alloy and Loki. Grafana now provides a common investigation
interface for both PromQL metrics and LogQL logs.

The remaining resilience gap is off-host backup storage. A future stage
can replicate backups to a second Linux machine or dedicated storage
system so recovery is still possible after complete loss of the ThinkPad
or its disk.

