# 00 — Quick Start(全平台)

> 这是 Outpost 的**唯一入口文档**。读完它你能从零跑起整套基础设施。
> 其他 docs/ 是参考资料,不是教程。
> 适用 macOS / Linux 原生 / Windows WSL2 三平台。

## 先决定:你要哪个模式

| 模式 | 你能拿到什么 | 必填项 | 适用 |
|------|--------------|--------|------|
| **`local`** *(默认)* | Compose 数据服务跑在 `localhost`(PG / Redis / RabbitMQ / Meilisearch) | 无 | 个人本机开发后端,不需要公网 / GitOps |
| **`full`** | `local` + Cloudflare Tunnel + k3s + ArgoCD + Tekton GitOps | `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`, `MANIFEST_REPO_URL` | 想挂自己域名 + push 即部署 |

> 两种模式可随时切换。先 `local`,熟悉后改 `.env` 的 `OUTPOST_MODE=full` 重跑 `bootstrap.sh`,数据卷与已生成的密码会被复用。

> ⚠️ **v0.1 限制**:full 模式当前**只完整支持 Gitee**(默认)。`GIT_PROVIDER_PLUGIN=github` / `gitlab` 的插件框架已就位,但 `core/k8s/05-tekton/eventlistener.yaml` 没合并 plugin 的 trigger fragment(详见 `TODOS.md` 的"Multi-provider EventListener wiring")。短期想用 GitHub / GitLab 的话,你需要手工改 EventListener 的 CEL filter 和 binding,或等 v0.2。

---

## 术语

- **Outpost 主机**:跑 `bootstrap.sh` 的那台机器(macOS / Linux / WSL2)
- **开发机**:你写代码、用 DBeaver / Redis Insight 连 PG/Redis 的机器(可能就是 Outpost 主机本身,也可能是另一台笔记本)
- **manifest 仓库**:ArgoCD 的"事实来源",存放每个应用的 K8s YAML;**不是**应用代码仓库

---

## local 模式 — 最短路径(~2 分钟)

适用所有平台。如果不需要公网域名/GitOps,做完 1–4 就能用。

1. **Phase B(系统准备)** —— 见下面对应平台的小节,只需把 Docker 装起来
2. `git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost`
3. `bash bootstrap.sh`(默认就是 local 模式,无需改 `.env`)
4. 看 `INFRA.zh-CN.md` 拿连接串;`bash verify.sh` 验证

跳过本文档其余所有 Phase。

---

## full 模式 — 完整流程

按 A → I 的顺序做,中途任何一步失败请先排查再往下走。

### Phase A — Cloudflare 侧准备(浏览器,~10 min)— **三平台相同**

- [ ] **A1** 域名 NS 切到 Cloudflare(Free 计划够用),等 NS 生效
- [ ] **A2** Zero Trust → Networks → Tunnels → **Create a tunnel** → 选 `Cloudflared` → 命名(随便,如 `outpost`)→ Save
- [ ] **A3** 看到 install command 时**只复制 token**(`eyJhIjoi…` 长串),先放一边,**不要**执行那条 install 命令(我们用 Compose 跑 cloudflared,不是直接在主机)
- [ ] **A4** 进入这个 Tunnel 的 **Public Hostname** 标签,逐条添加 9 条记录(详见 `01-cloudflare-setup.md` §3 表格):
  - 6 条 HTTP:`search` / `mq` / `argocd` / `hooks` / `registry` / `*.apps`
  - 3 条 TCP:`pg` / `redis` / `rabbitmq`
  - **`registry` 那条额外**:展开 *Additional application settings → HTTP Settings → HTTP Host Header*,填 `registry.<你的根域名>`(Docker Registry 对 Host 头敏感,不写会拉镜像 401)
- [ ] **A5** 此时 Cloudflare Dashboard 里 Tunnel 状态应该是 *Inactive / Down* —— **正常**,因为本地 cloudflared 还没起。**不要在这里跑任何验证命令**;真正的连通性验证在 Phase F

### Phase B — 系统准备 — **按 Outpost 主机的平台分支**

#### B-mac(macOS)~5 min

- [ ] **B1** 装 Docker Desktop:`brew install --cask docker` → `open -a Docker`,等到状态栏小鲸鱼变绿
- [ ] **B2** 装基础工具:`brew install git jq gettext`(Apple Silicon 自带 bash/curl/openssl)
- [ ] **B3**(国内可选)Docker Desktop → Settings → Docker Engine,加镜像加速:
  ```json
  { "registry-mirrors": ["https://docker.m.daocloud.io"] }
  ```
- [ ] **B4** 自检:`docker run --rm hello-world` 应正常输出
- [ ] 跳过 `.wslconfig` 与 Windows 任务计划(不适用)

#### B-linux(Linux 原生)~5 min

- [ ] **B1** 基础工具:`sudo apt update && sudo apt install -y curl git openssl gettext-base ca-certificates jq`(Debian/Ubuntu 系;其他发行版用对应包管理器)
- [ ] **B2** Docker:可让 bootstrap 自动装(用官方 `get.docker.com` 脚本),也可手动提前装
- [ ] **B3** 把当前用户加进 docker 组(避免 sudo):`sudo usermod -aG docker $USER`,**退出重登**
- [ ] **B4** 自检:`docker run --rm hello-world`
- [ ] 跳过 `.wslconfig` 与 Windows 任务计划(不适用)

#### B-wsl(Windows + WSL2)~15 min

> 完整细节见 `02-wsl-config.md`(仅 WSL 用户需要读)

- [ ] **B1** 确认 Win11 22H2+。PowerShell 管理员:`wsl --install -d Ubuntu`
- [ ] **B2** 写 `C:\Users\<你>\.wslconfig`(参见 `02-wsl-config.md` §1)→ PowerShell `wsl --shutdown`
- [ ] **B3** 进 WSL → 写 `/etc/wsl.conf` 启用 systemd(`02-wsl-config.md` §2.1)→ Windows 端再 `wsl --shutdown` → 重进
- [ ] **B4** 配 Docker 镜像加速(`02-wsl-config.md` §2.2)+ `sudo systemctl restart docker`
- [ ] **B5** `sudo apt install -y curl git openssl gettext-base ca-certificates jq`
- [ ] **B6** 自检:`docker run --rm hello-world` + `systemctl status` 能正常返回

### Phase C — manifest 仓库(浏览器 + 任意机器,~3 min)— **三平台相同**

- [ ] **C1** 在 Gitee / GitHub / GitLab 建一个**空私有**仓库,如 `<user>/manifests`
- [ ] **C2** 本地 clone → 加两个空目录 → push:
  ```bash
  git clone <仓库 HTTPS URL> manifests && cd manifests
  mkdir -p apps argocd-apps
  touch apps/.gitkeep argocd-apps/.gitkeep
  git add . && git commit -m "init" && git push
  ```
- [ ] **C3** 在 Git 平台 → 个人设置 → **Personal Access Token**,生成一个 token:
  - Gitee:勾 `projects` 读写
  - GitHub:勾 `repo`(全集)
  - GitLab:勾 `api`
  - 记下来,Phase D 要用

### Phase D — Outpost 配置(Outpost 主机,~5 min)— **三平台相同**

- [ ] **D1** `git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost`
- [ ] **D2** `cp .env.example .env`,编辑 6 项:
  ```env
  OUTPOST_MODE=full
  ROOT_DOMAIN=<你的根域名>
  CF_TUNNEL_TOKEN=<A3 的 token>
  GIT_USER=<Git 用户名>
  GIT_TOKEN=<C3 的 token>
  MANIFEST_REPO_URL=<C1 的仓库 HTTPS URL,以 .git 结尾>
  GIT_PROVIDER_PLUGIN=gitee     # 或 github / gitlab
  ```
  其余字段(`POSTGRES_PASSWORD` 等密码)留空,bootstrap 会自动生成强密码

### Phase E — Bootstrap(~5 min)— **三平台相同**

- [ ] **E1** `bash bootstrap.sh`(自动检测 OS,走对应 `platform/*.sh`)
- [ ] **E2** 9 个 phase 跑完,看到:
  ```
  ═══════════════════════════════════════════════════════════════
    Outpost bootstrap complete (full mode)
  ═══════════════════════════════════════════════════════════════
  ```
- [ ] **E3 (仅 WSL2)** 如果 bootstrap 提示要 `wsl --shutdown`(首次启用 systemd 时会),按提示在 PowerShell 执行,重进 WSL 后 systemd 会自动恢复 docker / k3s / Compose

### Phase F — 验证(~2 min)— **三平台相同**

> ⚠️ 这是文档系统里**唯一**该跑连通性验证的位置。bootstrap 之前验证一定失败。

- [ ] **F1** 一键全栈:`bash verify.sh` —— 应全 PASS(WARN 可接受)
- [ ] **F2** cloudflared 隧道注册:
  ```bash
  docker logs cloudflared --tail 50 | grep "Registered tunnel connection"
  ```
  应至少 4 行(对应 CF 的 4 个 region)
- [ ] **F3** Cloudflare Dashboard 里 Tunnel 状态变 *Healthy*
- [ ] **F4** 浏览器开 `https://argocd.<你的域名>`,应见 ArgoCD 登录页;凭据见 `INFRA.zh-CN.md`
- [ ] **F5** 任何 FAIL 查 `06-troubleshooting.md` 或 `07-ai-verification.md` §1 对应小节

### Phase G — 关机后保活 — **按 Outpost 主机的平台分支**

#### G-mac

bootstrap 已自动注册 launchd LaunchAgent(`platform/macos.sh:52`)。

- [ ] **G1** 验证已注册:`launchctl list | grep io.smithyhaus.outpost`
- [ ] **G2** Docker Desktop 设为登录启动(Docker Desktop → Settings → General → Start Docker Desktop when you sign in)
- [ ] k3d cluster 由 Docker Desktop 拉起;Compose 由 LaunchAgent 拉起;无需任何手工步骤

#### G-linux

bootstrap 已 `systemctl enable docker k3s`,Compose 容器都是 `restart: unless-stopped`。

- [ ] **G1** 验证:`sudo systemctl is-enabled docker k3s` 都应输出 `enabled`
- [ ] 重启机器后无需任何手工操作

#### G-wsl(**只有 WSL2 需要这一步**)

WSL2 内的 systemd 已由 bootstrap 启用,但 **distro 自身不会随 Win 启动**。需要 Windows 任务计划触发。

- [ ] **G1** 按 `03-windows-autostart.md` 在 Windows 任务计划新建一项任务,登录时运行 `wsl.exe -d Ubuntu -u <user> -- bash -lc "cd ~/outpost && ./status.sh"`
- [ ] **G2** 可选:`.wslconfig` 加 `[experimental]\nautoMemoryReclaim=gradual`,让 WSL 不轻易完全停

### Phase H — 开发机访问 TCP 服务(可选)— **按你的开发机平台分支**

⚠️ **注意**:这一步装的 cloudflared 是在你的**开发机**上(Mac/Win 笔记本等),用来从远端打 TCP 隧道连 PG/Redis/RabbitMQ。**和 Outpost 主机无关**。如果你的 Outpost 就跑在开发机本机,直接 `localhost:5432` 就行,**跳过本节**。

HTTP 服务(ArgoCD UI / RabbitMQ UI / Meilisearch / Registry)直接浏览器开 `https://...`,**不需要本节**。

完整步骤见 `04-client-access.md`。简版:

- **macOS 开发机**:`brew install cloudflared` → `cloudflared login` → 写 launchd plist
- **Linux 开发机**:下载二进制 → 写 systemd-user unit
- **Windows 开发机**:`winget install --id Cloudflare.cloudflared` → Win 任务计划

### Phase I — 接第一个真实应用(可选)— **三平台相同**

**最快验证 CI/CD 端到端**:用 `examples/hello-world/<lang>/` 里的现成 Hello-World 当应用仓库,~2 分钟跑通整条流水线,无需自己写代码。支持 React / Vue / C# / Python / Java / Go 6 种语言,每个都自带 `Dockerfile` + `manifest/` + `argocd-application.yaml`。详见 `../../../examples/hello-world/README.md`。

正式接入自己的应用流程见 `05-onboard-project.md`。骨架:

1. 在 Git 平台建应用代码仓库,根目录有 `Dockerfile`
2. 在 manifest 仓库的 `apps/<app>/` 写 K8s YAML,在 `argocd-apps/<app>.yaml` 写 ArgoCD Application
3. 在应用仓库配 webhook → `https://hooks.<root>` + secret
4. push → Tekton 自动构建 → ArgoCD 自动部署 → `https://<app>.apps.<root>` 可访问

---

## 完成后该读什么

| 你想… | 读 |
|--------|-----|
| 排查某个组件为什么不工作 | `06-troubleshooting.md` |
| 让 AI(Claude / Cursor / Cline)帮你诊断 | `07-ai-verification.md` + `verify.sh --json` |
| 接入第二个、第三个应用 | `05-onboard-project.md` |
| 切到 Aliyun ACR / GitHub / GitLab | `plugins/README.md` + 改 `.env` 重跑 `bootstrap.sh` |
| 理解架构原理 | `../../ARCHITECTURE.md` |

## 全部重来

```bash
~/outpost/reset.sh        # 输入确认串后会清掉所有数据卷与 K8s 资源
~/outpost/bootstrap.sh    # 重跑
```
