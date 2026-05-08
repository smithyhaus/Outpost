# 04 — Dev workstation access (cloudflared TCP)

> ⚠️ **This doc operates on the *dev workstation*** — the laptop where
> you write code and run DBeaver / Redis Insight / RabbitMQ clients. It
> is **independent of the Outpost host**. If the Outpost host *is* your
> dev workstation, just connect to `localhost:5432` and **skip this
> entire doc**.

HTTP services (ArgoCD UI / RabbitMQ UI / Meilisearch / Registry) work
directly in the browser via `https://...` and do NOT need this doc.
**TCP services** (PostgreSQL / Redis / RabbitMQ AMQP) need a different
path because IDE clients can't speak Cloudflare's tunnel protocol — you
install `cloudflared` on the dev workstation and have it map the remote
service to `localhost:<port>`.

## 1. Install cloudflared

### macOS
```bash
brew install cloudflared
```

### Windows
```
winget install --id Cloudflare.cloudflared
```

### Linux
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
```

## 2. First-time login

```bash
cloudflared login
```

A browser opens; pick your Cloudflare account → Authorize.

## 3. Open a TCP tunnel manually

```bash
# PostgreSQL
cloudflared access tcp --hostname pg.example.com --url localhost:5432

# Redis
cloudflared access tcp --hostname redis.example.com --url localhost:6379

# RabbitMQ AMQP
cloudflared access tcp --hostname rabbitmq.example.com --url localhost:5672
```

Connect any client to `localhost:<port>`. Credentials come from `INFRA.md`.

## 4. Run as a background service (recommended)

### macOS — launchd

`~/Library/LaunchAgents/com.user.cloudflared-pg.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.cloudflared-pg</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/cloudflared</string>
    <string>access</string><string>tcp</string>
    <string>--hostname</string><string>pg.example.com</string>
    <string>--url</string><string>localhost:5432</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/cf-pg.log</string>
  <key>StandardErrorPath</key><string>/tmp/cf-pg.err</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.user.cloudflared-pg.plist
```

### Linux — systemd user unit

`~/.config/systemd/user/cloudflared-pg.service`:

```ini
[Unit]
Description=cloudflared TCP tunnel pg
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared access tcp --hostname pg.example.com --url localhost:5432
Restart=always

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now cloudflared-pg
```

### Windows — Task Scheduler / NSSM

Create a task that runs `cloudflared.exe access tcp ...` at logon.
Configure restart on failure.

## 5. IDE configuration

| Tool         | Host      | Port  | Auth                    |
|--------------|-----------|-------|--------------------------|
| DBeaver / DataGrip | `localhost` | 5432 | from INFRA.md §2 |
| Redis Insight | `localhost` | 6379 | from INFRA.md §3 |
| RabbitMQ (app) | `localhost` | 5672 | from INFRA.md §4 |
| RabbitMQ (UI)  | browser → `https://mq.<root>` | — | INFRA.md §4 |

## 6. Common questions

- **`cloudflared access tcp` returns 401:** run `cloudflared login` first
- **Local 5432 already in use:** map to another port, e.g. `--url localhost:15432`, and connect there
- **Slow connection:** try `--region us` / `--region asia` to vary the edge POP
- **Want IP allowlisting:** use Cloudflare Access (Zero Trust) policies on the hostname
