# Stage 02 — Native Nginx


## Architecture Diagram

```mermaid
flowchart LR
    Mac["MacBook Air"] --> LAN["Home LAN"]
    LAN --> UFW["UFW"]
    UFW --> Nginx["Native Nginx<br/>TCP 80"]
    Nginx --> Files["/var/www/html"]
```

## Objective

Deploy the first network application directly on Ubuntu and learn the relationship between:

- application process
- systemd service
- listening socket
- firewall
- web root
- HTTP requests

---

# Final State

Nginx is installed directly on Ubuntu and managed by systemd.

Important locations:

```text
Configuration:
 /etc/nginx/

Web root:
 /var/www/html
```

The server initially listened on:

```text
TCP 80
```

and served a custom page.

---

# 1. Install Nginx

Nginx was installed using the Ubuntu package manager.

Service state:

```bash
systemctl status nginx
```

Nginx can be controlled using:

```bash
sudo systemctl start nginx
sudo systemctl stop nginx
sudo systemctl restart nginx
sudo systemctl reload nginx
```

---

# 2. Verify the Listening Socket

```bash
sudo ss -tlnp | grep :80
```

A listener similar to:

```text
0.0.0.0:80
```

means Nginx accepts IPv4 connections addressed to any local interface on TCP 80.

A listener such as:

```text
[::]:80
```

is the IPv6 equivalent.

This is different from:

```text
127.0.0.1:80
```

which would only accept connections originating locally.

---

# 3. Allow HTTP Through UFW

Nginx application profiles can be inspected with:

```bash
sudo ufw app list
```

The firewall was configured to allow Nginx HTTP traffic.

Later, once HTTPS was added, `Nginx Full` became the intended rule because it covers both:

```text
TCP 80
TCP 443
```

---

# 4. Serve a Custom Page

The native Nginx web root was:

```text
/var/www/html
```

A custom `index.html` was created.

Example content:

```html
<!DOCTYPE html>
<html>
<head>
    <title>Stephen's Homelab</title>
</head>
<body>
    <h1>Homelab Server</h1>
    <p>Nginx is running on my ThinkPad T550.</p>
</body>
</html>
```

---

# 5. Test Locally

From the ThinkPad:

```bash
curl http://localhost
```

or:

```bash
curl http://127.0.0.1
```

This tests the application without relying on:

- Wi-Fi routing
- another device
- DNS

If local curl works, then Nginx and the local listening socket are functioning.

---

# 6. Test Remotely

From the Mac:

```bash
curl http://192.168.1.98
```

This adds additional layers:

```text
Mac
 |
 | Wi-Fi/LAN
 v
ThinkPad network interface
 |
 v
UFW
 |
 v
Nginx :80
```

A failure here while localhost still works points toward:

- firewall
- network
- interface binding
- routing

rather than the page itself.

---

# 7. Stop-Service Test

Nginx was deliberately stopped to observe the failure mode.

```bash
sudo systemctl stop nginx
```

Then from the Mac:

```bash
nc -vz 192.168.1.98 80
```

The connection was refused because there was no process listening on port 80.

On Ubuntu:

```bash
sudo ss -tlnp | grep :80
```

returned no Nginx listener.

This established an important troubleshooting relationship:

```text
systemd service stopped
        |
        v
no listening socket
        |
        v
TCP connection refused
```

---

# 8. Nginx Configuration Validation

Before reloading configuration:

```bash
sudo nginx -t
```

Only after a successful test should configuration be reloaded:

```bash
sudo systemctl reload nginx
```

This practice became important when multiple reverse-proxy virtual hosts were introduced later.

---

# 9. Logs

Useful logs:

```text
/var/log/nginx/access.log
/var/log/nginx/error.log
```

Useful commands:

```bash
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

Access logs show incoming requests.

Error logs show application/configuration/proxy errors.

---

# Validation Checklist

```bash
systemctl status nginx
sudo nginx -t
sudo ss -tlnp | grep :80
sudo ufw status verbose
curl http://localhost
```

From the Mac:

```bash
curl http://192.168.1.98
nc -vz 192.168.1.98 80
```

---

# Architecture After Stage 2

```text
MacBook
   |
   | HTTP
   | TCP 80
   v
192.168.1.98
   |
   v
UFW
   |
   v
Native Nginx
   |
   v
/var/www/html/index.html
```

---

# Key Lessons

- A running service, open firewall port and listening socket are separate states.
- `curl` tests HTTP.
- `nc` can test TCP connectivity without requiring a valid HTTP response.
- `ss` shows whether the host has a listening socket.
- Nginx configuration should always be tested with `nginx -t` before reload.
- Local and remote testing isolate different parts of the request path.
