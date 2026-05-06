# 01 — Cloudflare Tunnel 配置

## 步骤一：把域名 NS 切到 Cloudflare

1. 登录 https://dash.cloudflare.com
2. Add a Site → 输入根域名 → Free 计划
3. 把域名注册商的 NS 改成 Cloudflare 给的 2 条 NS（如 `xxx.ns.cloudflare.com`）
4. 等几分钟到几小时生效

## 步骤二：创建 Tunnel

1. 左侧 → **Zero Trust** → **Networks** → **Tunnels**
2. **Create a tunnel** → 选 `Cloudflared` → 命名 `infra` → Save
3. 看到 install command 时**只复制 token**（形如 `eyJhIjoi...` 长串）
4. 这个 token 写入 `.env` 的 `CF_TUNNEL_TOKEN=`

## 步骤三：配置 Public Hostname

进入 tunnel 详情页 → **Public Hostname** tab → 逐条添加（**Type 列注意区分 HTTP / TCP**）：

| Subdomain | Domain | Type | URL |
|-----------|--------|------|-----|
| `search` | `<你的根域名>` | HTTP | `caddy:80` |
| `mq` | `<你的根域名>` | HTTP | `caddy:80` |
| `argocd` | `<你的根域名>` | HTTP | `host.docker.internal:30080` |
| `hooks` | `<你的根域名>` | HTTP | `host.docker.internal:30080` |
| `registry` | `<你的根域名>` | HTTP | `host.docker.internal:30080` |
| `*.apps` | `<你的根域名>` | HTTP | `host.docker.internal:30080` |
| `pg` | `<你的根域名>` | TCP | `postgres:5432` |
| `redis` | `<你的根域名>` | TCP | `redis:6379` |
| `rabbitmq` | `<你的根域名>` | TCP | `rabbitmq:5672` |

**重要细节**：
- HTTP 的 URL 直接用容器名（`caddy:80` 等），cloudflared 容器在 Compose 内能解析
- 走 k3s 的几条用 `host.docker.internal:30080`（cloudflared 容器已配置 host-gateway）
- TCP 类型在 URL 字段填 `service:port`，Cloudflare 会帮你打 TCP 通道
- `*.apps.<domain>` 是通配符，Cloudflare Free 计划支持

每条添加完 Save。

## 步骤四：验证

```bash
# WSL 内
docker logs cloudflared --tail 50

# 应当看到 "Registered tunnel connection" 与各个 hostname 注册成功
```

浏览器访问 `https://argocd.<root>` 应该能看到 ArgoCD 登录页（需先把 Compose + k3s 起来）。

## 进阶：给 UI 加 Cloudflare Access（推荐）

ArgoCD UI 默认密码强 + HTTPS 已经不错，但暴露公网仍建议加一层 Zero Trust：

1. Zero Trust → **Access** → **Applications** → Add
2. Type：Self-hosted
3. Application name：`ArgoCD`
4. Application domain：`argocd.<root>`
5. Identity providers：默认 One-time PIN（邮箱 OTP）够用，也可加 GitHub OAuth
6. Policy → Allow → 邮箱白名单写你的邮箱

之后访问 `argocd.<root>` 会先弹邮箱验证页，验证通过才能见到 ArgoCD 登录。同样建议给 `mq.<root>` 和 `registry.<root>` 加。

`hooks.<root>`（webhook 端点）**不要加 Access**，否则 Gitee 调不通。Webhook 的安全靠 `X-Gitee-Token` 校验。
