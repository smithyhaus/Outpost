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

进入 tunnel 详情页 → **Public Hostname** tab → 逐条添加。内置入口一共就 4 条:

| Subdomain | Domain | Type | URL | 背后是谁 |
|-----------|--------|------|-----|---------|
| `search` | `<你的根域名>` | HTTP | `caddy:80` | Caddy `@search` → `manticore:9308`(Compose 容器) |
| `mq` | `<你的根域名>` | HTTP | `caddy:80` | Caddy `@mq` → `rabbitmq:15672`(Compose 容器) |
| `registry` | `<你的根域名>` | HTTP | `host.docker.internal:30080` | Traefik → 集群内 Docker Registry |
| `*` | `<你的根域名>` | HTTP | `host.docker.internal:30080` | Traefik → `apps` 命名空间里你的应用 |

**没有 `hooks` 行,没有 `argocd` / `tekton` / `rollouts` 行。** v0.3.0 删掉了整条
入站 webhook 路径和所有集群内 CI/CD 面板:GitHub Actions runner 只做出站长轮询,
`manifest-sync` 只做 CronJob 定时拉取,**没有任何东西需要从公网连进来**。构建状态看
GitHub Actions UI,部署状态看 `outpost status`。见
[ADR-0003](../../../docs/decisions/0003-github-actions-engine-swap.md)。

**可选的 raw-TCP 行** —— 仅当你需要远程数据库/队列客户端穿隧道时才加
(客户端用 `cloudflared access tcp`,见 `04-client-access.md`)。需要 QUIC
传输,`CF_TUNNEL_PROTOCOL=http2` 时不可用:

| Subdomain | Domain | Type | URL |
|-----------|--------|------|-----|
| `pg` | `<你的根域名>` | TCP | `postgres:5432` |
| `redis` | `<你的根域名>` | TCP | `redis:6379` |
| `rabbitmq` | `<你的根域名>` | TCP | `rabbitmq:5672` |

> **关于通配符那一行**:Subdomain 填 `*`(不是 `*.apps`)。应用走命名约定
> `<name>-apps.<root>`,被这条 `*.<root>` 兜底通配捕获,转给 k3s Traefik,
> 由 IngressRoute 按 `Host()` 匹配具体的 `<name>-apps`。**别填 `*.apps`** —
> 那是二级通配 `*.apps.<root>`,Cloudflare 免费 Universal SSL 不覆盖(要付费
> Advanced Certificate Manager ~$10/月)。CF Tunnel 也不支持 partial-label
> 通配 `*-apps`,所以 `-apps` 是 k3s 端的命名约定,不是 CF 路由模式。

**为什么 URL 全都一样**:cloudflared 自己不路由,只是把流量交给下一跳;`full` 模式下
这个下一跳永远是 k3s Traefik 的 NodePort,再由 Traefik 按 Host 头做二次路由。
唯一的例外是用 `outpost onboard` 接入的 Compose 层应用(`tier=compose`):它会生成
`Caddyfile.d/<app>.caddy` 片段,对应的 Public Hostname 行填 `caddy:80`。

**HTTPS 怎么没有**:TLS 在 Cloudflare 边缘终结,隧道内部全是明文 HTTP。Public Hostname 的 `Type` 没有 HTTPS 选项是有意的;用户访问的 `https://registry.<域名>` 由 CF 自动签发证书。

### 重要细节

- `registry` 和 `*` 行填 `host.docker.internal:30080`(k3s Traefik);`search`/`mq` 填 `caddy:80`,TCP 行直接填 Compose 容器名——它们和 cloudflared 在同一个 docker 网络里。cloudflared 容器已配置 `extra_hosts: host-gateway`(见 `core/compose/docker-compose.yml`)
- 那条 `*` 兜底通配会接住所有没单独列出的子域。更具体的条目(比如 `registry.<域名>`)
  自动覆盖通配 — CF Tunnel 是 most-specific-wins 匹配,顺序无关
- **`registry` 行额外配置**:展开 *Additional application settings → HTTP Settings → HTTP Host Header*,填 `registry.<你的根域名>`。Docker Registry 对 Host 头敏感,不写会拉镜像 401
- **TCP 行(`pg` / `redis` / `rabbitmq`)是可选的,但不需要任何主机侧准备**:
  数据服务就是 Compose 容器,和 cloudflared 同处一个 docker 网络(ADR-0005),
  所以 TCP 行直接指向容器即可:`tcp://postgres:5432`、`tcp://redis:6379`、
  `tcp://rabbitmq:5672`。唯一的真实约束是传输层——`cloudflared access tcp`
  这条客户端路径要求 QUIC,所以隧道跑在 `CF_TUNNEL_PROTOCOL=http2` 时它不可用。
  开发机侧的用法见 `04-client-access.md`。

每条添加完点 Save。

## 步骤四:Cloudflare 侧自检

此时主机还没跑 cloudflared,这里**只做 Cloudflare 仪表盘端的检查**:

- [ ] Tunnel 详情页能看到刚才创建的 4 条 Public Hostname
- [ ] Tunnel 状态显示 *Inactive* 或 *Down* —— **正常**,因为本地 cloudflared 还没起
- [ ] DNS 检查:`dig registry.<root>` 返回 Cloudflare 的 IP 段(说明 NS 已生效 + Public Hostname 已自动写 DNS 记录)。如返回 NXDOMAIN → NS 未生效或 Public Hostname 没保存

> 真正的"打开浏览器看到页面"属于**连通性验证**,需要先在 Outpost 主机跑完 `bash bootstrap.sh`。流程见 `00-quickstart.md` Phase F。

## 进阶:给 UI 加 Cloudflare Access(推荐)

强密码 + HTTPS 已经不错,但暴露公网仍建议加一层 Zero Trust:

1. Zero Trust → **Access** → **Applications** → Add
2. Type:Self-hosted
3. Application name:`RabbitMQ`
4. Application domain:`mq.<root>`
5. Identity providers:默认 One-time PIN(邮箱 OTP)够用,也可加 GitHub OAuth
6. Policy → Allow → 邮箱白名单写你的邮箱

`search.<root>` 同理。v0.3.0 之后公网已经没有任何入站 webhook 端点,
所以**不再有"某一行必须裸奔"的例外** —— 原来那条"别给 `hooks.<root>` 加 Access"
的告诫随路由一起消失了。

只有 `registry.<root>` 要斟酌:加了 Access,任何完不成浏览器登录的客户端
(`docker pull` / `buildctl`)都会被挡。集群内的构建链路不走公网边缘
(用的是 `127.0.0.1:30500` NodePort),所以这只影响从主机外面拉镜像 ——
按你实际有没有这种用法决定。
