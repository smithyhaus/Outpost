# 00 — Quick Start(全平台)

> 这是 Outpost 的**唯一入口文档**。读完它你能从零跑起整套基础设施。
> 其他 docs/ 是参考资料,不是教程。
> 适用 macOS / Linux 原生 / Windows WSL2 三平台。

## 先决定:你要哪个模式

| 模式 | 你能拿到什么 | 必填项 | 适用 |
|------|--------------|--------|------|
| **`local`** *(默认)* | Compose 数据服务跑在 `localhost`(PG / Redis / RabbitMQ / Manticore Search) | 无 | 个人本机开发后端,不需要公网 / GitOps |
| **`full`** | `local` + Cloudflare Tunnel + k3s + ArgoCD + Tekton GitOps | `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`, `MANIFEST_REPO_URL` | 想挂自己域名 + push 即部署 |

> 两种模式可随时切换。先 `local`,熟悉后改 `.env` 的 `OUTPOST_MODE=full` 重跑 `bootstrap.sh`,数据卷与已生成的密码会被复用。

> ℹ️ **Git providers**：从 v0.3 起，三个 git-provider plugin 都已端到端打通。bootstrap 会用"通用 EventListener 外壳（`core/k8s/05-tekton/eventlistener-base.yaml`）+ 当前选中 plugin 的 sibling `trigger.yaml`"装配 EventListener。在 `.env` 选其一即可：
>
> ```env
> GIT_PROVIDER_PLUGIN=gitee     # 默认 —— 明文 X-Gitee-Token 比对
> # GIT_PROVIDER_PLUGIN=github  # Tekton 内置 github interceptor 走 HMAC-SHA256
> # GIT_PROVIDER_PLUGIN=gitlab  # 明文 X-Gitlab-Token 比对
> ```
>
> 三者共用同一个 webhook 地址：`https://hooks.<ROOT_DOMAIN>`。

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
- [ ] **A4** 进入这个 Tunnel 的 **Public Hostname** 标签,逐条添加 11 条记录(详见 `01-cloudflare-setup.md` §3 表格):
  - 8 条 HTTP:`search` / `mq` / `argocd` / `tekton` / `rollouts` / `hooks` / `registry` / `*`(兜底通配,覆盖所有 `<x>-apps.<root>` 应用)
  - 3 条 TCP:`pg` / `redis` / `rabbitmq`
  - **不要填 `*.apps`** — 那是二级通配,免费 Universal SSL 不覆盖(要付费 ACM ~$10/月)。应用走 `<name>-apps.<root>` 命名约定,单条 `*.<root>` 兜底就够。
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
- [ ] **F4** 浏览器开 `https://argocd.<你的域名>`(ArgoCD)和 `https://tekton.<你的域名>`(Tekton Dashboard)各自能打开;凭据见 `INFRA.zh-CN.md`
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

HTTP 服务(ArgoCD UI / RabbitMQ UI / Manticore HTTP / Registry)直接浏览器开 `https://...`,**不需要本节**。注意:Manticore 的 HTTP 端点是 JSON API,不是 UI——浏览器打开返回的是 API 响应,不是控制面板。

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
4. push → Tekton 自动构建 → ArgoCD 自动部署 → `https://<app>-apps.<root>` 可访问

应用密钥(连接串、token 等)用 SealedSecret 加密后入库,见 `08-seal-secret.md`。

### Phase J — 测试网关、自动回滚、多通道告警(可选,推荐)

> 完整设计见 `proposals/cicd-test-gate.md`。这一阶段补齐:
>
> - **Gate A** — Tekton 流水线里的预部署测试(Testkube)。**测试不过,manifest 不会更新,集群完全看不到坏镜像**。
> - **Gate B** — 部署后金丝雀 + 自动回滚(Argo Rollouts)。分析失败 → 自动撤回流量到上一稳定版。
> - **多通道告警** — 钉钉 / 飞书 / 企微 / 通用 webhook,plugin 化。一份归一化 payload,每家 plugin 贡献自己的渲染模板。
>
> **整个 Phase J 都是可选的**。跳过它,流水线照样跑;只是没有测试、没有金丝雀、没有告警。

#### J-1. 选通道(浏览器,~5 min)

每个想要的通道,从厂商那拿 webhook URL:

| 通道 | 在哪里建 bot | 可选 |
|---|---|---|
| 钉钉 | 群设置 → 智能群助手 → 添加 → 自定义机器人(建议加签) | 加签 secret |
| 飞书 | 群设置 → 群机器人 → 添加自定义机器人 | 加签 secret |
| 企业微信 | 群设置 → 添加群机器人 → 新创建 | — |
| 通用 webhook | 你自己接的 HTTPS endpoint(JSON POST) | Bearer token |

#### J-2. 写到 `.env`(Outpost 主机,~1 min)

```env
# 任意组合,逗号分隔。空字符串 = 不发任何告警。
NOTIFICATION_PROVIDERS=dingtalk,feishu

DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
DINGTALK_SIGN_SECRET=SEC...                  # 可选(推荐)

FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...
FEISHU_SIGN_SECRET=                          # 可选

WECOM_WEBHOOK_URL=
GENERIC_WEBHOOK_URL=
GENERIC_WEBHOOK_BEARER=                       # 可选 Bearer token

# 测试 + 回滚(默认值,通常不用改)
TEST_RUNNER=testkube                         # 或 catalog-tasks
TESTKUBE_MODE=oss                            # bootstrap 自动装 testkube agent
ROLLOUT_PLUGIN=argo-rollouts
ROLLOUTS_DASHBOARD_HOST=                     # 默认 rollouts.<root>
```

#### J-3. 重跑 bootstrap(~3 min)

```bash
bash bootstrap.sh
```

bootstrap 的 Phase 9 会:

1. 在 `testkube` 命名空间装 **Testkube**(没装 helm 会自动下载)。
2. 在 `argo-rollouts` 命名空间装 **Argo Rollouts** controller + Dashboard。
3. 在 `tekton-pipelines` 应用每家通知 plugin 的 Secret + ConfigMap。
4. 把每家 plugin 的 fragment 拼成统一的 `argocd-notifications-cm` + `argocd-notifications-secret`。
5. 应用共享的 `outpost-notify` Tekton Task — Pipeline `finally` 块在失败时调它。

#### J-4. 在应用仓库根目录加 `outpost.test.yaml`(每个应用 ~2 min)

```yaml
version: 1
runner:
  command:
    - sh
    - -c
    - "go test ./..."         # 或 pytest / npm test / mvn test / dotnet test
gates:
  pre-deploy:
    timeout: 5m
  post-deploy-smoke:
    enabled: true
    image: curlimages/curl:8.10.0
    command: ["sh","-c","curl -fsS http://my-app.apps.svc.cluster.local/healthz"]
    timeout: 30s
```

仓库根没有 `outpost.test.yaml` 也没有 `Dockerfile.test` → run-tests Task **干净 skip**(不算失败),pipeline 照常跑。

#### J-5. 让应用接 Argo Rollouts(可选,但这是回滚魔法生效的地方)

把 manifest 仓库 `apps/<app>/deployment.yaml` 的 `Deployment` 换成 `Rollout`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: my-app, namespace: apps }
spec:
  replicas: 3
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 30s }
        - analysis:
            templates: [{ templateName: outpost-default }]   # 或 outpost-smoke (Testkube)
            args: [{ name: service-name, value: my-app }]
        - setWeight: 50
        - pause: { duration: 30s }
        - setWeight: 100
  selector: { matchLabels: { app: my-app } }
  template: { ... }      # 跟 Deployment.spec.template 完全一样
```

某档分析失败(默认阈值:`failureLimit: 2`、`consecutiveErrorLimit: 3`)→ **自动回滚** 到上一稳定 ReplicaSet → ArgoCD notifications 触发(Application 进入 `Degraded`/`Suspended`)→ 所有启用的通道收到告警。

#### J-6. 验证 wiring 通了(~2 min)

```bash
# 看 dashboard
open https://tekton.${ROOT_DOMAIN}             # PipelineRuns / TaskRuns / logs
open https://${ROLLOUTS_DASHBOARD_HOST}        # 金丝雀进度 / 中止 / 提升

# 看 namespace
kubectl get pods -n testkube
kubectl get pods -n argo-rollouts
kubectl get cm,secret -n argocd | grep notifications
```

测一下失败链路:把 `examples/hello-world-go/main.go` 改坏(比如开头加 `os.Exit(1)`)→ git push → Tekton 在 `run-tests` 步骤红 → 钉钉/飞书收到失败消息 → manifest 仓库未变 → 集群应用未受影响。

---

## GitOps 速成 — 日常 5 个最常操作(给没用过的人)

### 一句话理解整套流

```
你 push 代码                                                       ┌── 应用跑起来
      │                                                           │
      └──> Tekton 把代码打成 docker image,推到 registry           │
            │                                                     │
            └──> Tekton 改 manifest 仓库里的 image 标签 (新 SHA)   │
                  │                                               │
                  └──> ArgoCD 看到 manifest 变了,kubectl apply ───┘
```

**一切都过 manifest 仓库**:你不会在终端敲 `kubectl apply`。要改部署/副本数/环境变量,都在 manifest 仓库改 YAML 然后 push。ArgoCD 自动追上。

### 1️⃣ 看"我刚 push 的代码到底走到哪一步了"

打开 **Tekton Dashboard**:`https://tekton.<你的根域名>`(无需登录,首页就是 PipelineRuns 列表)

最上面那条就是你最新的 build。点进去看 3 个 task 的状态:

| Task | 干嘛的 | 失败常见原因 |
|------|--------|------------|
| `fetch-source` | 拉应用代码 | git 凭据不对 / 仓库地址写错 |
| `build-and-push` | kaniko 构建并推 image | Dockerfile 有问题 / 拉基础镜像超时 |
| `update-manifest` | 改 manifest 仓库 image 标签 | manifest 仓库没建对应 `apps/<app>/` 目录 / token 没 push 权 |

每个 task 都能点开看每一步的 logs,跟 GitHub Actions 一样直观。

### 2️⃣ 看"我的应用在 K8s 里到底活没活"

打开 **ArgoCD UI**:`https://argocd.<你的根域名>`(用户名 `admin`,密码见 `INFRA.zh-CN.md` §6 或终端运行 `grep ARGOCD_ADMIN_PASSWORD .env`)

首页是所有 Application 的卡片,每张卡片两个状态:

| 状态 | 含义 | 看到这个该做啥 |
|------|------|---------------|
| **Synced + Healthy**(绿) | 集群里跑的 = git 里写的 + 所有 pod ready | 啥都不用做 |
| **OutOfSync** | git 里有改动,集群还没追上 | 通常 ArgoCD 30s 内会自动 sync。等不及就点卡片右下角 **SYNC** |
| **Degraded** | 部署进去了,但 pod 起不来(CrashLoop / 镜像拉不到 / readiness 失败) | 点进卡片 → 找红色资源 → 点 pod → 看 Events / Logs |
| **Missing** | manifest 写了,但还没创建 | 同上,点 SYNC |

点进任意一张卡片,你看到的是"manifest 仓库里这个 app 声明了什么 → 集群里实际跑成啥",**两边的 diff 高亮显示**。

### 3️⃣ 强制让 ArgoCD 重新同步(改完 manifest 后等不及那 30s)

ArgoCD UI → 点 Application 卡片 → 右上 **SYNC** → 默认参数 → SYNCHRONIZE

或终端:
```bash
kubectl patch application <app> -n argocd --type merge \
  -p '{"operation":{"sync":{}}}'
```

### 4️⃣ 应用挂了,我怎么从 0 摸到 logs

进 ArgoCD 那个 Application → 看到红色的 pod → 点开 pod → **LOGS** 标签。或终端:

```bash
# 看 pod 名字
kubectl get pods -n apps -l app=<app-name>

# 看实时 logs (-f 是 follow)
kubectl logs -n apps -l app=<app-name> -f --all-containers

# 看上一次 crash 的 logs
kubectl logs -n apps <pod-name> --previous
```

### 5️⃣ 我改了配置/代码,要怎么"上线"

**方式 A — 改代码**(最常见):
```
应用仓库改代码 → git push → 等 30s 看 Tekton Dashboard → 等 ArgoCD 同步 → 完成
```
全自动,你只要 `git push`。

**方式 B — 改部署参数**(改副本数、环境变量、限额等):
```
manifest 仓库改 apps/<app>/deployment.yaml → git push → 30s 内 ArgoCD 自动 apply
```

**方式 C — 改密钥**(数据库密码改了之类):
- 不要直接改 git 里的 sealed-secret.yaml(改了密文也解不开)
- 重跑应用自己的 `scripts/onboard.sh` 重新加密 → push
- 完整流程见 `08-seal-secret.md`

> ⚠️ **永远不要直接 `kubectl apply` 到 `apps` namespace**。ArgoCD self-heal 会在 30s 内把你的改动覆盖回 manifest 仓库的版本。要改就走 manifest 仓库。

### 速记表

| 我想… | 去哪 |
|------|------|
| 看 build 跑到哪一步 | Tekton Dashboard `https://tekton.<root>` |
| 看应用部署状态 / 强制同步 | ArgoCD UI `https://argocd.<root>` |
| 看应用运行日志 | ArgoCD → Application → pod → LOGS,或 `kubectl logs -n apps -l app=<X>` |
| 给应用加密钥 | 应用 repo 的 `scripts/onboard.sh`(详见 `08-seal-secret.md`) |
| 改副本数/资源限额/env | manifest 仓库 `apps/<app>/deployment.yaml`,然后 push |

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
