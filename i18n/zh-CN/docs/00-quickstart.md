# 00 — Quick Start(全平台)

> 这是 Outpost 的**唯一入口文档**。读完它你能从零跑起整套基础设施。
> 其他 docs/ 是参考资料,不是教程。
> 适用 macOS / Linux 原生 / Windows WSL2 三平台。

## 先决定:你要哪个模式

| 模式 | 你能拿到什么 | 必填项 | 适用 |
|------|--------------|--------|------|
| **`local`** *(默认)* | Compose 数据服务跑在 `localhost`(PG / Redis / RabbitMQ / Manticore Search) | 无 | 个人本机开发后端,不需要公网 / CI/CD |
| **`full`** | k3s 数据层 + Cloudflare Tunnel + GitHub Actions self-hosted runner + `manifest-sync` 部署 | `ROOT_DOMAIN`、`CF_TUNNEL_TOKEN`、`GIT_USER`、`GIT_TOKEN`、`MANIFEST_REPO_URL`、`GITHUB_RUNNER_URL`、`GITHUB_RUNNER_PAT`、`OUTPOST_REPOS` | 想挂自己域名 + push 即部署 |

> 两种模式可随时切换。先 `local`,熟悉后改 `.env` 的 `OUTPOST_MODE=full` 重跑 `bootstrap.sh`,数据卷与已生成的密码会被复用。

> ℹ️ **Git provider(v0.3.0 变了)**:**任何地方都不再有入站 webhook** ——
> CI 是 GitHub Actions 工作流,由本机的 self-hosted runner **纯出站长轮询**拉取。
> 所以 `GIT_PROVIDER_PLUGIN` 不再是"webhook 接收方"的选择器,而是
> **凭据校验 + host 归属判定**的契约:bootstrap 时每个启用的 provider 会对它
> 管辖的 `OUTPOST_REPOS` 条目做一次带认证的 `git ls-remote`,token 有问题当场
> 报错,而不是以后悄悄不出构建。它接受逗号列表,而且双 provider 才是常态:
>
> ```env
> GIT_PROVIDER_PLUGIN=gitee,github   # gitee = 主推送目标 + manifest 仓库
>                                    # github = 只作为 CI 触发面
> ```
>
> 见 [ADR-0003](../../../docs/decisions/0003-github-actions-engine-swap.md)。

---

## 术语

- **Outpost 主机**:跑 `bootstrap.sh` 的那台机器(macOS / Linux / WSL2),
  GitHub Actions runner 也跑在它上面
- **开发机**:你写代码、用 DBeaver / Redis Insight 连 PG/Redis 的机器(可能就是 Outpost 主机本身,也可能是另一台笔记本)
- **manifest 仓库**:部署的事实来源,每个应用的 K8s YAML 放在 `apps/<app>/` 下;
  `manifest-sync` CronJob 定时拉取并 apply。**不是**应用代码仓库
- **应用仓库**:你的业务代码。主仓在 gitee,github 上有一份副本,存在的唯一目的
  是让 GitHub Actions 能触发构建

---

## local 模式 — 最短路径(~2 分钟)

适用所有平台。如果不需要公网域名 / CI-CD,做完 1–4 就能用。

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
- [ ] **A4** 进入这个 Tunnel 的 **Public Hostname** 标签,添加 **4 条 HTTP 记录**,URL 全部填 `host.docker.internal:30080`(详见 `01-cloudflare-setup.md` §3 表格):
  - `search` / `mq` / `registry` / `*`(兜底通配,覆盖所有 `<x>-apps.<root>` 应用)
  - **没有 `hooks` / `argocd` / `tekton` / `rollouts` 行** —— v0.3.0 删掉了整条入站 webhook 路径和所有集群内 CI/CD 面板
  - **不要填 `*.apps`** — 那是二级通配,免费 Universal SSL 不覆盖(要付费 ACM ~$10/月)。应用走 `<name>-apps.<root>` 命名约定,单条 `*.<root>` 兜底就够
  - **`registry` 那条额外**:展开 *Additional application settings → HTTP Settings → HTTP Host Header*,填 `registry.<你的根域名>`(Docker Registry 对 Host 头敏感,不写会拉镜像 401)
- [ ] **A5** 此时 Cloudflare Dashboard 里 Tunnel 状态应该是 *Inactive / Down* —— **正常**,因为本地 cloudflared 还没起。**不要在这里跑任何验证命令**;真正的连通性验证在 Phase F

### Phase B — 系统准备 — **按 Outpost 主机的平台分支**

#### B-mac(macOS)~5 min

- [ ] **B1** 装 Docker Desktop:`brew install --cask docker` → `open -a Docker`,等到状态栏小鲸鱼变绿
- [ ] **B2** 装基础工具:`brew install git jq gettext yq`(Apple Silicon 自带 bash/curl/openssl)
- [ ] **B3**(国内可选)Docker Desktop → Settings → Docker Engine,加镜像加速:
  ```json
  { "registry-mirrors": ["https://docker.m.daocloud.io"] }
  ```
- [ ] **B4** 自检:`docker run --rm hello-world` 应正常输出
- [ ] 跳过 `.wslconfig` 与 Windows 任务计划(不适用)
- [ ] ⚠️ macOS 没有 systemd。runner 本身照样会装(bootstrap 用 runner 自带的
      `svc.sh`,注册成 launchd 任务),但 `outpost-verify.timer` 守卫会被
      **跳过** —— `verify.sh` 只在你手动跑时才跑。想要自动巡检,请用
      LaunchAgent 调度 `platform/systemd/outpost-verify-run.sh`。
      另外 macOS 上 `verify.sh` 的 `ci.runner.unit` 会报 WARN(查不了
      systemd),请用 `~/actions-runner/svc.sh status` 自行确认

#### B-linux(Linux 原生)~5 min

- [ ] **B1** 基础工具:`sudo apt update && sudo apt install -y curl git openssl gettext-base ca-certificates jq`(Debian/Ubuntu 系;其他发行版用对应包管理器)
- [ ] **B2** Docker:可让 bootstrap 自动装(用官方 `get.docker.com` 脚本),也可手动提前装
- [ ] **B3** 把当前用户加进 docker 组(避免 sudo):`sudo usermod -aG docker $USER`,**退出重登**
- [ ] **B4** 装 `yq`(mikefarah v4+)和 `buildctl` —— runner 构建时要在 PATH 里找它们。runner 主机完整工具清单见 `templates/github/README.md` §3
- [ ] **B5** 自检:`docker run --rm hello-world`
- [ ] 跳过 `.wslconfig` 与 Windows 任务计划(不适用)

#### B-wsl(Windows + WSL2)~15 min

> 完整细节见 `02-wsl-config.md`(仅 WSL 用户需要读)

- [ ] **B1** 确认 Win11 22H2+。PowerShell 管理员:`wsl --install -d Ubuntu`
- [ ] **B2** 写 `C:\Users\<你>\.wslconfig`(参见 `02-wsl-config.md` §1)→ PowerShell `wsl --shutdown`
- [ ] **B3** 进 WSL → 写 `/etc/wsl.conf` 启用 systemd(`02-wsl-config.md` §2.1)→ Windows 端再 `wsl --shutdown` → 重进
- [ ] **B4** 配 Docker 镜像加速(`02-wsl-config.md` §2.2)+ `sudo systemctl restart docker`
- [ ] **B5** `sudo apt install -y curl git openssl gettext-base ca-certificates jq`,再装 `yq` 和 `buildctl`
- [ ] **B6** 自检:`docker run --rm hello-world` + `systemctl status` 能正常返回

### Phase C — manifest 仓库(浏览器 + 任意机器,~3 min)— **三平台相同**

- [ ] **C1** 在 Gitee / GitHub / GitLab 建一个**空私有**仓库,如 `<user>/manifests`。推荐放 gitee —— 这样部署链路全程国内
- [ ] **C2** 本地 clone → 建 `apps/` 目录 → push:
  ```bash
  git clone <仓库 HTTPS URL> manifests && cd manifests
  mkdir -p apps
  touch apps/.gitkeep
  git add . && git commit -m "init" && git push
  ```
  `manifest-sync` **只读 `apps/` 这一个目录**。历史遗留的 `argocd-apps/`
  会被直接忽略(说明见 `05-onboard-project.md` §3)
- [ ] **C3** 在 Git 平台 → 个人设置 → **Personal Access Token**,生成一个 token:
  - Gitee:勾 `projects` 读写
  - GitHub:勾 `repo`(全集)
  - GitLab:勾 `api`
  - 记下来,Phase D 要用

### Phase C2 — GitHub runner 前置准备(浏览器,~5 min)— **三平台相同**

CI 跑在 GitHub Actions 上,但 runner 在**你自己的主机**,所以 GitHub 那边需要一个落脚点:

- [ ] **C2-1** 选注册目标:推荐 GitHub **组织**(`https://github.com/<org>` ——
      一个 runner 服务组织下所有私有仓库)。填单仓库地址也行,但那样 runner
      只服务那一个仓库
- [ ] **C2-2** 建一个能换取 runner 注册令牌的 PAT:组织地址要 `admin:org` 权限,
      单仓库地址要仓库 admin 权限。Outpost **只**用它换取短期注册令牌 ——
      不会写进 runner,也不会打进任何日志
- [ ] **C2-3** 每个要构建的应用仓库,**确认 github 上有一份副本**。gitee 仍是主推送
      目标,github 只是 CI 触发面。二选一:双推(dual-push),或 gitee 的**单向**
      push-mirror(别用双向的 —— 它 30 分钟的窗口可能丢 commit)。具体命令
      Phase I 里 `outpost onboard` 会直接打印出来

### Phase D — Outpost 配置(Outpost 主机,~5 min)— **三平台相同**

- [ ] **D1** `git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost`
- [ ] **D2** `cp .env.example .env`,编辑这些字段:
  ```env
  OUTPOST_MODE=full
  ROOT_DOMAIN=<你的根域名>
  CF_TUNNEL_TOKEN=<A3 的 token>
  GIT_USER=<Git 用户名>
  GIT_TOKEN=<C3 的 token>
  MANIFEST_REPO_URL=<C1 的仓库 HTTPS URL,以 .git 结尾>
  GIT_PROVIDER_PLUGIN=gitee,github        # 逗号列表;双 provider 是常态

  GITHUB_RUNNER_URL=https://github.com/<org>
  GITHUB_RUNNER_PAT=<C2-2 的 PAT>
  OUTPOST_REPOS=                          # Phase I 里由 `outpost onboard` 自动写入
  ```
  其余字段(`POSTGRES_PASSWORD` 等密码)留空,bootstrap 会自动生成强密码
- [ ] **D3** *(应用仓库和 manifest 仓库不在同一个 host 时)* 加上
      `GIT_CREDENTIALS_EXTRA=github.com|<user>|<token>`,让 preflight 的
      `ls-remote` 和对账也能在那个 host 上认证

> `GITHUB_RUNNER_PAT` 可以留空 —— 那样 bootstrap 会**跳过 runner 安装并打印醒目
> WARN**,`verify.sh` 的 `ci.runner` 报 WARN。这只在跑本仓库自己的 CI/e2e 时算
> 合法状态;真实安装里它意味着**永远不会有构建被触发**。

### Phase E — Bootstrap(~5 min)— **三平台相同**

- [ ] **E1** `bash bootstrap.sh`(自动检测 OS,走对应 `platform/*.sh`)
- [ ] **E2** 10 个 phase 跑完,看到:
  ```
  ═══════════════════════════════════════════════════════════════
    Outpost bootstrap complete (full mode) — verify: ALL PASS
  ═══════════════════════════════════════════════════════════════
  ```
  (后缀是 `verify.sh` 的判定 —— `PASS with WARNINGS` 也算成功)
- [ ] **E3** Phase 8 会主动触发一次 `manifest-sync` 并**等它写出新鲜心跳**。
      300 秒内等不到,bootstrap 会**故意**非零退出:一次 sync 都跑不完的栈不算
      装好了。报错里会给出排查命令
      (`kubectl -n outpost-ci logs job/manifest-sync-bootstrap`)
- [ ] **E4(仅 WSL2)** 如果 bootstrap 提示要 `wsl --shutdown`(首次启用 systemd 时会),按提示在 PowerShell 执行,重进 WSL 后 systemd 会自动恢复 docker / k3s / Compose / runner

### Phase F — 验证(~2 min)— **三平台相同**

> ⚠️ 这是文档系统里**唯一**该跑连通性验证的位置。bootstrap 之前验证一定失败。

- [ ] **F1** 一键全栈:`bash verify.sh` —— 应全 PASS(WARN 可接受)
- [ ] **F2** cloudflared 隧道注册:
  ```bash
  docker logs cloudflared --tail 50 | grep "Registered tunnel connection"
  ```
  应至少 4 行(对应 CF 的 4 个 region)
- [ ] **F3** Cloudflare Dashboard 里 Tunnel 状态变 *Healthy*
- [ ] **F4** 浏览器开 `https://mq.<你的域名>`(RabbitMQ 管理界面)和
      `https://registry.<你的域名>/v2/`(registry API,返回 `{}`),凭据见
      `INFRA.zh-CN.md`。v0.3 里**没有任何 CI/CD 面板可开**
- [ ] **F5** CI/CD 存活性 —— 这几项正是过去会静默失效的地方:
  ```bash
  systemctl status 'actions.runner.*'          # runner 服务在跑
  outpost status                               # sync 心跳:last_sync_ts / applied_head / last_result
  systemctl status outpost-verify.timer        # 守卫定时器已启用
  ```
- [ ] **F6** 任何 FAIL 查 `06-troubleshooting.md` 或 `07-ai-verification.md` §1 对应小节

### Phase G — 关机后保活 — **按 Outpost 主机的平台分支**

#### G-mac

bootstrap 已自动注册 launchd LaunchAgent(`platform/macos.sh`)。

- [ ] **G1** 验证已注册:`launchctl list | grep io.smithyhaus.outpost`
- [ ] **G2** Docker Desktop 设为登录启动(Docker Desktop → Settings → General → Start Docker Desktop when you sign in)
- [ ] k3d cluster 由 Docker Desktop 拉起;Compose 由 LaunchAgent 拉起;无需任何手工步骤

#### G-linux

bootstrap 已 `systemctl enable docker k3s`,Compose 容器都是 `restart: unless-stopped`。

- [ ] **G1** 验证:`sudo systemctl is-enabled docker k3s` 都应输出 `enabled`
- [ ] **G2** CI/CD 那两个单元也要确认:`systemctl is-enabled outpost-verify.timer` 和 `systemctl status 'actions.runner.*'`
- [ ] 重启机器后无需任何手工操作

#### G-wsl(**只有 WSL2 需要这一步**)

WSL2 内的 systemd 已由 bootstrap 启用,但 **distro 自身不会随 Win 启动**。需要 Windows 任务计划触发。

- [ ] **G1** 按 `03-windows-autostart.md` 在 Windows 任务计划新建一项任务,登录时运行 `wsl.exe -d Ubuntu -u <user> -- bash -lc "cd ~/outpost && ./status.sh"`
- [ ] **G2** 可选:`.wslconfig` 加 `[experimental]\nautoMemoryReclaim=gradual`,让 WSL 不轻易完全停
- [ ] **G3** 记住:distro 停了 = runner 停了,push 会在 GitHub 那边**排队**而不是报错。
      能告诉你这件事的是 `outpost-verify.timer` —— 它 `Persistent=true`,
      distro 回来后会补跑

### Phase H — 开发机访问 TCP 服务(可选)— **按你的开发机平台分支**

⚠️ **注意**:这一步装的 cloudflared 是在你的**开发机**上(Mac/Win 笔记本等),用来从远端打 TCP 隧道连 PG/Redis/RabbitMQ。**和 Outpost 主机无关**。如果你的 Outpost 就跑在开发机本机,直接 `localhost:5432` 就行,**跳过本节**。

HTTP 服务(RabbitMQ UI / Manticore HTTP API / Registry)直接浏览器开 `https://...`,**不需要本节**。注意:Manticore 的 HTTP 端点是 JSON API,不是 UI —— 浏览器打开返回的是 API 响应,不是控制面板。

完整步骤见 `04-client-access.md`,**特别注意里面的 v0.3 前置条件**:数据服务现在
是 k3s 里的 ClusterIP Service,CF 的 TCP 行需要你先在主机上把端口暴露出来。简版:

- **macOS 开发机**:`brew install cloudflared` → `cloudflared login` → 写 launchd plist
- **Linux 开发机**:下载二进制 → 写 systemd-user unit
- **Windows 开发机**:`winget install --id Cloudflare.cloudflared` → Win 任务计划

### Phase I — 接第一个真实应用(可选)— **三平台相同**

**最快验证 CI/CD 端到端**:用 `examples/hello-world/<lang>/` 里的现成 Hello-World 当应用仓库,~2 分钟跑通整条流水线,无需自己写代码。支持 React / Vue / C# / Python / Java / Go 6 种语言,每个都自带 `Dockerfile` + `manifest/`。详见 `../../../examples/hello-world/README.md`。

正式接入自己的应用流程见 `05-onboard-project.md`。骨架:

1. 在 gitee 建应用代码仓库(根目录有 `Dockerfile`),并在 github 建一份副本
2. `bash scripts/outpost onboard <clone-url>` —— 把仓库写进 `OUTPOST_REPOS`
   (这才是让 `verify.sh` 对账盯住它的开关),并打印 CI 接线步骤
3. 把 `templates/github/outpost-build.yml` 拷进应用仓库的
   `.github/workflows/outpost-build.yml`;部署分支不是 `main` 就改
   `branches: [main]` 那一行
4. 配好双推(或 gitee 单向 push-mirror),让 github 副本跟住 gitee
5. 在 manifest 仓库加 `apps/<app>/`(Deployment + Service + Ingress +
   kustomization)—— `outpost manifest scaffold` 能生成
6. push 代码 → runner 构建并推送 `sha-7` 标签的镜像 →
   `scripts/update-manifest.sh` 改 manifest 仓库 → `manifest-sync` 在
   `MANIFEST_SYNC_INTERVAL` 分钟内 apply → `https://<app>-apps.<root>` 可访问

**两边仓库都不需要配任何 webhook。** 如果你在找那一步,它已经不存在了。

应用密钥(连接串、token 等)用 SealedSecret 加密后入库,见 `08-seal-secret.md`。

### Phase J — 测试网关、自动回滚、多通道告警(可选,推荐)

> 这一阶段补齐:
>
> - **Gate A** —— 预部署测试,由 runner 上的 `scripts/ci/run-tests.sh` 在**改 manifest 之前**执行。**测试不过,manifest 不会更新,集群完全看不到坏镜像**。
> - **Gate B** —— 部署后金丝雀 + 自动回滚(Argo Rollouts,只装 controller)。按应用自愿采用 `Rollout` CRD。
> - **多通道告警** —— 钉钉 / 飞书 / 企微 / 通用 webhook,plugin 化,由 `scripts/notify-fanout.sh` 扇出。
>
> **整个 Phase J 都是可选的**。跳过它,流水线照样跑;只是没有测试、没有金丝雀、没有告警。
>
> 设计史见 `proposals/cicd-test-gate.md`(写于 Tekton/ArgoCD 时代 —— 看**为什么**,别照抄**怎么做**)。

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
TEST_RUNNER=testkube
TESTKUBE_MODE=skip                           # 默认 —— run-tests.sh 直接解析
                                             # outpost.test.yaml;设 oss 才装 agent
ROLLOUT_PLUGIN=none                          # 要金丝雀就设 argo-rollouts
```

#### J-3. 重跑 bootstrap(~3 min)

```bash
bash bootstrap.sh
```

bootstrap 的 Phase 9 会:

1. 处理 test runner(默认 `TESTKUBE_MODE=skip` 时集群内什么都不装 —— Gate A 跑在主机上)。
2. 若 `ROLLOUT_PLUGIN=argo-rollouts`,装 **Argo Rollouts controller**(v0.3 只有 controller,没有 Dashboard)。
3. 把启用的通知 plugin 的 Secret + ConfigMap 应用到 `outpost-ci` 命名空间 —— `manifest-sync` CronJob 从那里读。

**每个启用通道都会收到的事件**:

| 事件 | 从哪来 | 你能用它干什么 |
|---|---|---|
| `build-failed` | GitHub Actions 工作流 | 构建 / Gate A / 改 manifest 任一步红了 |
| `deploy-succeeded` | `manifest-sync` CronJob | 某个 push 真正上线了 |
| `deploy-failed` | `manifest-sync` CronJob | manifest 错 / 镜像拉不到 / rollout 超时 |
| `verify-failed` | 主机的 `outpost-verify.timer` | 链路某处变哑了 —— 这个探测器活在集群和 GitHub 之外 |

#### J-4. 在应用仓库根目录加 `outpost.test.yaml`(每个应用 ~2 min)

```yaml
version: 1
runner:
  image: golang:1.23-alpine     # 可选;默认 alpine:3.20
  command:
    - sh
    - -c
    - "go test ./..."           # 或 pytest / npm test / mvn test / dotnet test
```

`.runner.command` 是必填。命令**在容器里执行**(应用仓库的代码相对 runner
主机属于不可信输入),工作区 bind-mount 到 `/workspace`。仓库根既没有
`outpost.test.yaml` 也没有 `Dockerfile.test` → Gate A **干净跳过**(不算失败),
流水线照常跑。

#### J-5. 让应用接 Argo Rollouts(可选,但这是回滚魔法生效的地方)

先把 `ROLLOUT_PLUGIN=argo-rollouts` 写进 `.env` 重跑 bootstrap,再把 manifest
仓库 `apps/<app>/deployment.yaml` 的 `Deployment` 换成 `Rollout`:

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
        - setWeight: 50
        - pause: { duration: 30s }
        - setWeight: 100
  selector: { matchLabels: { app: my-app } }
  template: { ... }      # 跟 Deployment.spec.template 完全一样
```

`manifest-sync` 认得 `Rollout` 这个 kind:它不走 `kubectl rollout status`,
而是轮询 `.status.phase`,读到 `Degraded` 就判定部署失败 —— 于是往你的通道发
`deploy-failed`。

#### J-6. 验证 wiring 通了(~2 min)

```bash
# 部署侧
outpost status                       # sync 心跳
outpost logs sync                    # 最近一次 manifest-sync Job 的日志

# 构建侧(集群内没有 UI —— 构建跑在主机 runner 上)
journalctl -u 'actions.runner.*' -n 200
# …或者看应用仓库的 GitHub Actions 页

# 看 namespace
kubectl get pods -n outpost-ci
kubectl get pods -n argo-rollouts    # 仅当 ROLLOUT_PLUGIN=argo-rollouts
kubectl get cm,secret -n outpost-ci
```

测一下失败链路:把 `examples/hello-world/go/main.go` 改坏(让测试挂掉)→
git push → 工作流在 *Run tests (Gate A)* 步骤红 → 钉钉/飞书收到 `build-failed`
→ manifest 仓库未变 → 集群应用未受影响。

---

## push 即部署速成 — 日常 5 个最常操作(给没用过的人)

### 一句话理解整套流

```
你 git push(同时到 gitee 和 github)                        ┌── 应用跑起来
      │                                                     │
      └─> GitHub 把 outpost-build.yml 派发给你自己的 runner  │
            │                                               │
            ├─> build-image.sh:buildctl → registry,tag=sha7 │
            ├─> run-tests.sh:  Gate A(可选)                │
            └─> update-manifest.sh:改 manifest 仓库(gitee) │
                  │                                         │
                  └─> manifest-sync CronJob(每 2 分钟)拉取, │
                      kubectl apply -k,等 rollout ─────────┘
```

**一切都过 manifest 仓库**:你不会在终端敲 `kubectl apply`。要改部署/副本数/环境变量,都在 manifest 仓库改 YAML 然后 push,下一次 sync 就会 apply。

### 1️⃣ 看"我刚 push 的代码到底走到哪一步了"

看应用仓库的 **GitHub Actions 页** —— 那就是现在的构建界面。
`outpost-build` 工作流有 3 个关键步骤:

| 步骤 | 干嘛的 | 失败常见原因 |
|------|--------|------------|
| `Build image` | `buildctl` → 集群内 buildkitd(`127.0.0.1:30750`)→ 推 `sha-7` 标签 | Dockerfile 有问题 / 拉基础镜像超时 / buildkitd 没 Ready |
| `Run tests (Gate A)` | 在容器里跑 `outpost.test.yaml` 的命令 | 测试真挂了;或 runner 上缺 `yq` / `docker` |
| `Update manifest` | 改 manifest 仓库的 image 标签 | manifest 仓库没有对应 `apps/<app>/` / token 没 push 权 |

一时上不了 GitHub?同一份日志在主机上:
`journalctl -u 'actions.runner.*' -n 200`。

### 2️⃣ 看"我的应用在 K8s 里到底活没活"

```bash
outpost status               # sync 心跳:last_sync_ts / applied_head / last_result
outpost verify --app <app>   # 单个应用的 pod、已部署镜像、近期 events
```

`last_result=ok` 且 `last_sync_ts` 新鲜 = CD 那半边是活的。心跳超过
3× `MANIFEST_SYNC_INTERVAL` 就是 `verify.sh` 的 FAIL —— 不管 CronJob 对象
还在不在,部署都已经停了。

### 3️⃣ 立刻触发一次同步(等不及那 2 分钟)

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

### 4️⃣ 应用挂了,我怎么从 0 摸到 logs

```bash
outpost logs <app>                       # 'apps' 命名空间里的 pod

# 或者手敲
kubectl get pods -n apps -l app=<app-name>
kubectl logs -n apps -l app=<app-name> -f --all-containers
kubectl logs -n apps <pod-name> --previous     # 上一次 crash 的日志
```

### 5️⃣ 我改了配置/代码,要怎么"上线"

**方式 A — 改代码**(最常见):
```
应用仓库改代码 → git push → 看 GitHub Actions 跑完(~1-2 分钟)
                          → manifest-sync apply(≤2 分钟)→ 完成
```
全自动,你只要 `git push`。

**方式 B — 改部署参数**(改副本数、环境变量、限额等):
```
manifest 仓库改 apps/<app>/deployment.yaml → git push → 下一次 sync 生效
```

**方式 C — 回滚一次坏部署**:
```bash
outpost rollback <app>          # 列出 registry 里还留着的 tag
outpost rollback <app> abc1234  # 改写 manifest;sync 约 2 分钟内收敛
```
这条路径**全程国内**(gitee + 本地集群)—— github.com 连不上也照样能用。

**方式 D — 改密钥**(数据库密码改了之类):
- 不要直接改 git 里的 sealed-secret.yaml(改了密文也解不开)
- 重跑应用自己的 `scripts/onboard.sh` 重新加密 → push
- 完整流程见 `08-seal-secret.md`

> ⚠️ **永远不要直接 `kubectl apply` 到 `apps` namespace**。现在**不会**有东西
> 立刻把它覆盖回去(ArgoCD 的 self-heal 循环已经没了)—— 而这恰恰是危险所在:
> 你的改动悄悄偏离 manifest 仓库,等这个应用下次 manifest 变更时被无声抹掉。
> 要改就走 manifest 仓库。

### 速记表

| 我想… | 去哪 |
|------|------|
| 看 build 跑到哪一步 | GitHub Actions 页,或 `journalctl -u 'actions.runner.*'` |
| 看部署状态 | `outpost status` / `outpost logs sync` |
| 看应用运行日志 | `outpost logs <app>`,或 `kubectl logs -n apps -l app=<X>` |
| 回滚坏镜像 | `outpost rollback <app> [sha]` |
| 给应用加密钥 | 应用 repo 的 `scripts/onboard.sh`(详见 `08-seal-secret.md`) |
| 改副本数/资源限额/env | manifest 仓库 `apps/<app>/deployment.yaml`,然后 push |
| 确认整条链路还活着 | `bash verify.sh`(对账是最终裁判) |

---

## 完成后该读什么

| 你想… | 读 |
|--------|-----|
| 排查某个组件为什么不工作 | `06-troubleshooting.md` |
| 让 AI(Claude / Cursor / Cline)帮你诊断 | `07-ai-verification.md` + `verify.sh --json` |
| 接入第二个、第三个应用 | `05-onboard-project.md` |
| 切到 Aliyun ACR / 加一个 Git provider | `plugins/README.md` + 改 `.env` 重跑 `bootstrap.sh` |
| 理解架构原理 | `../../../ARCHITECTURE.md` |
| 为什么换掉 Tekton + ArgoCD | `../../../docs/decisions/0003-github-actions-engine-swap.md` |

## 全部重来

```bash
~/outpost/reset.sh        # 输入确认串后会清掉所有数据卷与 K8s 资源
~/outpost/bootstrap.sh    # 重跑
```

整机重建(换 WSL2 机器、清 distro)请改用 runbook:
`../../../docs/prp/runbooks/wsl2-redeploy-0.3.md`。
