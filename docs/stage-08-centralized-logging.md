# Stage 8 --- Centralized Logging

## Objective

Extend the homelab observability stack with centralized logging so
native host logs, Docker container logs, and systemd journal events can
be collected through Grafana Alloy, stored and queried in Grafana Loki,
and investigated from Grafana.

## Architecture

``` text
Native Nginx logs ─────┐
                       │
Docker container logs ─┼──> Grafana Alloy ──> Grafana Loki ──> Grafana
                       │
systemd journal ───────┘
```

This complements the existing metrics pipeline:

``` text
Node Exporter / cAdvisor ──> Prometheus ──> Grafana
Alloy                     ──> Loki       ──> Grafana
```

Prometheus stores numerical time-series metrics. Loki stores logs.
Grafana provides the common query and visualization interface.

## Components

### Grafana Alloy

Alloy is the telemetry collector. In this stage it:

-   discovers and reads native Nginx log files
-   discovers Docker containers through the Docker daemon socket
-   reads Docker container stdout/stderr
-   reads the host systemd journal
-   attaches useful labels
-   forwards logs to Loki

### Grafana Loki

Loki is the centralized log backend. It:

-   receives logs from Alloy
-   persists log data
-   indexes labels
-   executes LogQL queries
-   returns matching log streams to Grafana

Loki is not published to the ThinkPad host or Internet. Alloy and
Grafana reach it over the Docker Compose network using:

``` text
http://loki:3100
```

### Grafana

Grafana uses Loki as a data source for log exploration. Historical logs
are queried in Explore with LogQL. Live mode is used only when watching
new entries as they arrive.

## Nginx File Collection

Native Nginx writes logs on the Ubuntu host:

``` text
/var/log/nginx/access.log
/var/log/nginx/error.log
```

The host directory is mounted read-only into Alloy:

``` yaml
- "/var/log/nginx:/var/log/nginx:ro"
```

Alloy uses file discovery and file collection:

``` alloy
local.file_match "nginx" {
  path_targets = [
    {
      __path__ = "/var/log/nginx/*.log",
      job      = "nginx",
      host     = "thinkpad",
    },
  ]

  sync_period = "10s"
}

loki.source.file "nginx" {
  targets    = local.file_match.nginx.targets
  forward_to = [loki.write.local.receiver]
}
```

The collection path is:

``` text
/var/log/nginx/*.log
        ↓
local.file_match
        ↓
loki.source.file
        ↓
loki.write
        ↓
Loki
```

Example queries:

``` logql
{job="nginx"}
```

``` logql
{job="nginx"} |= "GET"
```

``` logql
{job="nginx"} |= "404"
```

``` logql
{job="nginx", filename="/var/log/nginx/access.log"}
```

## Docker Log Collection

Alloy accesses the Docker daemon through:

``` yaml
- "/var/run/docker.sock:/var/run/docker.sock:ro"
```

The Docker logging pipeline is:

``` text
Docker daemon
      ↓
discovery.docker
      ↓
discovery.relabel
      ↓
loki.source.docker
      ↓
loki.write
      ↓
Loki
```

Docker discovery exposes metadata that can be converted into useful Loki
labels, including:

``` text
job="docker"
container="nextcloud-app"
service_name="app"
compose_project="nextcloud"
```

This allows container logs to be queried centrally instead of inspecting
each container separately with `docker logs`.

Examples:

``` logql
{job="docker"}
```

``` logql
{job="docker", service_name="grafana"}
```

``` logql
{job="docker", container="nextcloud-app"}
```

``` logql
{job="docker", compose_project="nextcloud", service_name="app"}
```

The Nextcloud container name and Compose service name are different
concepts. For example:

``` text
container name: nextcloud-app
Compose project: nextcloud
Compose service: app
```

## systemd Journal Collection

Alloy also collects host service events from journald using
`loki.source.journal`.

The relevant host journal paths are mounted read-only into Alloy:

``` yaml
- "/var/log/journal:/var/log/journal:ro"
- "/run/log/journal:/run/log/journal:ro"
```

The collection path is:

``` text
systemd / journald
        ↓
loki.source.journal
        ↓
loki.write
        ↓
Loki
```

Useful journal metadata can be relabeled into queryable labels such as:

``` text
source="journal"
unit="docker.service"
host="thinkpad"
level="error"
```

Example queries:

``` logql
{source="journal"}
```

``` logql
{source="journal", unit="docker.service"}
```

``` logql
{source="journal", unit="ssh.service"}
```

Journal collection is distinct from Docker container logging.
`loki.source.docker` collects container stdout/stderr, while
`loki.source.journal` can collect service-level events from the Docker
daemon itself.

## Loki Output

All collected streams are forwarded to the same Loki backend:

``` alloy
loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

Because Loki and Alloy share the Compose network, Loki does not need a
host-published port.

## Labels and LogQL

Labels identify log streams before line content is searched.

Examples of labels used in this homelab:

``` text
job
host
filename
container
service_name
compose_project
source
unit
level
```

A label selector:

``` logql
{service_name="grafana"}
```

selects streams based on metadata.

A line filter:

``` logql
{job="nginx"} |= "404"
```

selects Nginx streams and then keeps only log lines containing `404`.

## End-to-End Validation

A controlled Nginx request was used to verify the complete pipeline:

``` text
Mac
 ↓
HTTPS
 ↓
Router / NAT
 ↓
UFW
 ↓
Native Nginx
 ↓
/var/log/nginx/access.log
 ↓
Alloy
 ↓
Loki
 ↓
Grafana
```

Example test:

``` bash
curl -I https://cloud.stephen-homelab.com
curl -I https://cloud.stephen-homelab.com/this-does-not-exist
```

Verify locally:

``` bash
sudo tail /var/log/nginx/access.log
```

Then query Loki:

``` logql
{job="nginx"}
```

or:

``` logql
{job="nginx"} |= "this-does-not-exist"
```

Docker logging was validated by comparing `docker logs` output with Loki
queries for the corresponding container/service.

## Troubleshooting Method

Troubleshoot the pipeline one boundary at a time:

``` text
Log producer
    ↓
Local log source
    ↓
Alloy visibility/read access
    ↓
Alloy collection
    ↓
Loki ingestion
    ↓
Grafana query
```

Useful commands:

``` bash
# Validate Compose
docker compose config -q

# Validate Alloy configuration
docker run --rm \
  -v "$(pwd)/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.11.3 \
  validate /etc/alloy/config.alloy

# Check stack state
docker compose ps

# Check Alloy
docker compose logs alloy

# Check Loki
docker compose logs loki

# Confirm Nginx logs
sudo tail /var/log/nginx/access.log

# Confirm container logs
docker logs nextcloud-app

# Inspect Compose metadata
docker inspect nextcloud-app \
  --format 'service={{ index .Config.Labels "com.docker.compose.service" }} project={{ index .Config.Labels "com.docker.compose.project" }}'
```

When a minimal container lacks troubleshooting utilities, a disposable
diagnostic container can be attached to the same Docker network:

``` bash
docker run --rm \
  --network monitoring_default \
  curlimages/curl:latest \
  -s http://loki:3100/ready
```

## Security Considerations

-   Loki is not host-published or publicly exposed.
-   Native log and journal mounts are read-only.
-   No additional router port forwarding or UFW rules are required for
    Loki or Alloy.
-   `/var/run/docker.sock` is a significant trust boundary. A read-only
    bind mount does not make the Docker API itself inherently read-only.
-   Secrets, runtime log data, Loki storage, Docker volumes, and host
    journal contents are not committed to Git.

## Key Lessons

-   Logs existed before centralized logging; Stage 8 centralized their
    collection, storage, and querying.
-   Prometheus and Loki solve different observability problems: metrics
    versus logs.
-   Alloy is the collector/forwarder; Loki is the log storage/query
    backend; Grafana is the investigation interface.
-   Different sources require different collection mechanisms: files,
    Docker API, and journald.
-   Labels make centralized logs efficiently selectable and LogQL
    filters the selected streams.
-   Docker service names, container names, and Compose project names are
    separate metadata fields.
-   Docker-internal services can communicate using Compose DNS without
    publishing backend ports.
-   Range queries search historical logs; Grafana Live mode watches new
    logs as they arrive.
-   Configuration syntax must match the pinned Alloy/Loki versions.
-   End-to-end validation should test every layer rather than assuming a
    Grafana display problem means ingestion is broken.

## Stage 8 Completion

Stage 8 is complete when the following paths return real logs in
Grafana:

``` text
Native Nginx
  → Alloy
  → Loki
  → Grafana

Docker containers
  → Alloy
  → Loki
  → Grafana

systemd journal
  → Alloy
  → Loki
  → Grafana
```

This stage extends the homelab from metrics-only monitoring into
centralized operational observability with searchable host, service, and
container logs.

