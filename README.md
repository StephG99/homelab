# Homelab

A self-hosted Linux homelab built on Ubuntu for learning Linux
administration, networking, Docker, observability, reverse proxies,
DNS, TLS and infrastructure security.

## Architecture

Internet
→ Public DNS
→ Home Router
→ NAT / Port Forwarding
→ UFW
→ Native Nginx
→ Docker Applications

## Completed Stages

### Stage 1 — Linux & SSH
- Ubuntu host
- SSH key authentication
- UFW firewall
- DHCP reservation

### Stage 2 — Native Nginx
- Nginx installed on Ubuntu
- HTTP service
- Service management and logging

### Stage 3 — Docker
- Docker CE
- Container networking
- Port publishing
- Bind mounts

### Stage 4 — Observability
- Prometheus
- Grafana
- Node Exporter
- cAdvisor

### Stage 5 — Reverse Proxy, DNS & TLS
- Public DNS
- NAT / port forwarding
- Native Nginx reverse proxy
- Let's Encrypt certificates
- HTTPS
- Backend exposure hardening

### Stage 6 — Nextcloud
Planned.
