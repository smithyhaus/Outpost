# 01 — Cloudflare Tunnel 配置

> 这一步在浏览器里做,**不依赖** Outpost 主机有没有跑起来。完成后再回到 `00-quickstart.md` 的 Phase D / E。

## 步骤一:把域名 NS 切到 Cloudflare

1. 登录 https://dash.cloudflare.com
2. Add a Site → 输入根域名 → Free 计划
3. 把域名注册商的 NS 改成 Cloudflare 给的 2 条 NS(如 `xxx.ns.cloudflare.com`)
4. 等几分钟到几小时生效

## 步骤二:创建 Tunnel

1. 左侧 → **Zero Trust** → **Networks** → **Tunnels**
2. **Create a tunnel** → 选 `Cloudflared` → 命名(随便,如 `outpost`)→ Save
3. 看到 install command 时**只复制 token**(形如 `eyJhIjoi...` 长串)
4. 这个 token 之后写入 `.env` 的 `CF_TUNNEL_TOKEN=`(见 `00-quickstart.md` Phase D)
5. **不要**在主机上执行 install 命令 —— Outpost 用 Compose 跑 cloudflared,不需要主机直跑

## 步骤三:配置 Public Hostname

进入 tunnel 详情页 → **Public Hostname** tab → 逐条添加(**Type 列注意区分 HTTP / TCP**):

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

**为什么 URL 看起来重复**:cloudflared 自己不路由,只是把流量交给下一跳;再由 Caddy(`caddy:80`,按 Host 头分流给 meilisearch / rabbitmq UI)和 k3s Traefik(`host.docker.internal:30080`,按 Ingress 分流给 ArgoCD / Tekton EL / Registry / 用户应用)做二次路由。

**HTTPS 怎么没有**:TLS 在 Cloudflare 边缘终结,隧道内部全是明文 HTTP。Public Hostname 的 `Type` 没有 HTTPS 选项是有意的;用户访问的 `https://argocd.<域名>` 由 CF 自动签发证书。

### 重要细节

- HTTP 行用容器名(`caddy:80`):cloudflared 容器在 Compose 网络里能解析
- 走 k3s 的 4 行用 `host.docker.internal:30080`:cloudflared 容器已配置 `extra_hosts: host-gateway`(见 `core/compose/docker-compose.yml`)
- TCP 行的 URL 字段填 `service:port`,Cloudflare 会建 L4 通道
- `*.apps.<domain>` 是通配符,Free 计划支持
- **`registry` 行额外配置**:展开 *Additional application settings → HTTP Settings → HTTP Host Header*,填 `registry.<你的根域名>`。Docker Registry 对 Host 头敏感,不写会拉镜像 401

每条添加完点 Save。

## 步骤四:Cloudflare 侧自检

此时主机还没跑 cloudflared,这里**只做 Cloudflare 仪表盘端的检查**:

- [ ] Tunnel 详情页能看到刚才创建的 9 条 Public Hostname
- [ ] Tunnel 状态显示 *Inactive* 或 *Down* —— **正常**,因为本地 cloudflared 还没起
- [ ] DNS 检查:`dig argocd.<root>` 返回 Cloudflare 的 IP 段(说明 NS 已生效 + Public Hostname 已自动写 DNS 记录)。如返回 NXDOMAIN → NS 未生效或 Public Hostname 没保存

> 真正的"打开浏览器看到 ArgoCD 登录页"属于**连通性验证**,需要先在 Outpost 主机跑完 `bash bootstrap.sh`。流程见 `00-quickstart.md` Phase F。

## 进阶:给 UI 加 Cloudflare Access(推荐)

ArgoCD UI 默认密码强 + HTTPS 已经不错,但暴露公网仍建议加一层 Zero Trust:

1. Zero Trust → **Access** → **Applications** → Add
2. Type:Self-hosted
3. Application name:`ArgoCD`
4. Application domain:`argocd.<root>`
5. Identity providers:默认 One-time PIN(邮箱 OTP)够用,也可加 GitHub OAuth
6. Policy → Allow → 邮箱白名单写你的邮箱

之后访问 `argocd.<root>` 会先弹邮箱验证页,验证通过才能见到 ArgoCD 登录。同样建议给 `mq.<root>` 和 `registry.<root>` 加。

`hooks.<root>`(webhook 端点)**不要加 Access**,否则 Git 提供商调不通。Webhook 的安全靠 `X-Gitee-Token` / `X-Hub-Signature-256` / `X-Gitlab-Token` 校验。
