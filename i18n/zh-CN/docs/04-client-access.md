# 04 — 开发机访问（cloudflared access TCP）

HTTP 服务直接浏览器访问即可（已经过 Cloudflare 边缘 TLS）。
**TCP 服务**（PostgreSQL / Redis / RabbitMQ AMQP）需要在开发机装 `cloudflared`，开一个本地 TCP 隧道。

## 一、装 cloudflared

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

## 二、首次登录授权

```bash
cloudflared login
```
浏览器会打开 → 选你的 Cloudflare 账号 → Authorize。

## 三、开 TCP 隧道（手动）

```bash
# PostgreSQL
cloudflared access tcp --hostname pg.example.com --url localhost:5432

# Redis
cloudflared access tcp --hostname redis.example.com --url localhost:6379

# RabbitMQ AMQP
cloudflared access tcp --hostname rabbitmq.example.com --url localhost:5672
```

之后用任意客户端连 `localhost:<port>`，凭据见 `INFRA.md` 的速查表。

## 四、常驻服务（推荐）

每次手动开太麻烦，让 cloudflared 在后台常驻。

### macOS（launchd）

`~/Library/LaunchAgents/com.user.cloudflared-pg.plist`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key><string>com.user.cloudflared-pg</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/cloudflared</string>
    <string>access</string>
    <string>tcp</string>
    <string>--hostname</string>
    <string>pg.example.com</string>
    <string>--url</string>
    <string>localhost:5432</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/cf-pg.log</string>
  <key>StandardErrorPath</key><string>/tmp/cf-pg.err</string>
</dict>
</plist>
```

加载：
```bash
launchctl load ~/Library/LaunchAgents/com.user.cloudflared-pg.plist
```

每个 TCP 服务一份 plist。

### Linux（systemd user unit）

`~/.config/systemd/user/cloudflared-pg.service`：
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

启用：
```bash
systemctl --user daemon-reload
systemctl --user enable --now cloudflared-pg
```

### Windows（NSSM 或 任务计划）

任务计划新建任务，登录时运行 `cloudflared.exe access tcp ...`，设置失败重启。

## 五、IDE 集成

### DBeaver / DataGrip
Host: `localhost`
Port: `5432`（cloudflared 已映射）
Username/Password: 见 INFRA.md

### Redis Insight
Host: `localhost`，Port: `6379`，Auth: 见 INFRA.md

### RabbitMQ
应用 connection URL: `amqp://admin:<pass>@localhost:5672/`
管理 UI 直接浏览器开 `https://mq.<root>`（HTTP，不需要 TCP 隧道）

## 六、常见问题

- **`cloudflared access tcp` 报 401**：先 `cloudflared login`
- **本地 5432 端口被占用**：换一个本地端口 `--url localhost:15432`，客户端连 15432
- **连接很慢**：cloudflared 加 `--region us` 等参数试不同 region
- **可以用 Cloudflare Access 加白名单**：只允许特定邮箱建 TCP 隧道
