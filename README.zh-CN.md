# Outpost

> **一行命令，把一整套自托管开发后端跑在你自己的设备上。**
> Postgres / Redis / RabbitMQ / Manticore Search + 完整 GitOps CI/CD 流水线，
> 通过 Cloudflare Tunnel 暴露在你自己的域名上。
> 支持 macOS / Linux / Windows (WSL2)。Plugin 化设计。AI 友好开箱即用。

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL2-green.svg)]()
[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)

---

## 一行 `bash bootstrap.sh` 你能拿到什么

```
            Cloudflare 边缘 (HTTPS, 不需要公网 IP)
                            │
                            ▼
                   cloudflared 隧道 (出站连接)
                    ┌────────┴────────┐
                    ▼                 ▼
            ┌──────────────┐    ┌────────────────────┐
            │  Compose     │    │  k3s 集群            │
            │  (edge+data) │    │                     │
            │  cloudflared │    │  Registry + buildkitd │
            │  caddy       │    │  manifest-sync (CD)  │
            │  Postgres    │    │  你的应用            │
            │  Redis       │    │                     │
            │  RabbitMQ    │    │  (infra-bridges 桥   │
            │  Manticore   │    │   → Compose 数据服务) │
            └──────────────┘    └────────────────────┘
                                        ▲
                                        │ (宿主机，仅出站)
                            GitHub Actions 自托管 runner
```

- **数据层** —— Postgres/Redis/RabbitMQ/Manticore 两种模式下都以宿主
  Compose 容器运行 —— 几乎每个项目都需要的有状态服务。`full` 模式的
  k3s pod 经 `infra-bridges` ExternalName 桥（CoreDNS hosts 自愈）访问,
  见 [ADR-0005](docs/decisions/0005-data-layer-back-to-host.md)。
- **CI/CD** —— push 代码 → GitHub Actions 自托管 runner（宿主机 systemd
  服务，纯出站长轮询，全程无任何入站 webhook）构建并推送镜像 →
  `manifest-sync` CronJob 部署。详见 [`ARCHITECTURE.md`](ARCHITECTURE.md)
  和 [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)。
- **一个 Cloudflare Tunnel** 把所有东西暴露在你自己域名的子域上。
  不需要路由器配置、不需要公网 IP，双层 NAT 也能用。

## 两种模式

Outpost 提供两种模式，按当前需求挑一个。

| 模式 | 跑什么 | 必填项 | 适用场景 |
|------|--------|--------|----------|
| **`local`** *(默认)* | Compose 数据服务跑在 `localhost`：PG、Redis、RabbitMQ、Manticore Search | 无 —— 全部默认值或自动生成 | 本机当个人开发后端，不需要公网，不需要 CI/CD |
| **`full`** | `local` 的全部内容（Compose 数据层原样不变）+ Cloudflare Tunnel + k3s 应用层 + GitHub Actions 自托管 runner + manifest-sync CD | `ROOT_DOMAIN`、`CF_TUNNEL_TOKEN`、`GIT_USER`、`GIT_TOKEN`、`MANIFEST_REPO_URL`、`GITHUB_RUNNER_URL`、`GITHUB_RUNNER_PAT` | 需要把服务挂到自己域名上 + push 即部署的 CI/CD |

通过修改 `.env` 里的 `OUTPOST_MODE` 切换。重跑 `bash bootstrap.sh` 是幂等的；`.env` 里已有的密码会被复用。

## 快速开始

> 完整 step-by-step 走查（含 macOS / Linux / WSL2 三平台分支、Cloudflare 侧准备、manifest 仓库初始化、验证步骤）见
> **[`i18n/zh-CN/docs/00-quickstart.md`](i18n/zh-CN/docs/00-quickstart.md)**。
> 下方是极简版，适合"已经做过一次"快速回忆。

### local 模式（~2 分钟，零必填）

```bash
git clone https://github.com/smithyhaus/outpost.git ~/outpost
cd ~/outpost
bash bootstrap.sh          # 默认就是 local 模式，无需改 .env
```

完成后：

- `INFRA.zh-CN.md` 列出所有连接串和密码（自动生成）
- 应用直连：`postgresql://postgres:<pw>@localhost:5432/postgres` 等等

### full 模式（~30 分钟首次，含 Cloudflare + 仓库准备）

需要先准备：
1. 一个 Cloudflare 账号 + 域名（NS 已切到 Cloudflare）+ 一个 Tunnel token（[`docs/01`](i18n/zh-CN/docs/01-cloudflare-setup.md)）
2. 一个 Gitee / GitHub / GitLab **空 manifest 仓库**（含 `apps/` 空目录）+ 一个 PAT
3. 一个 GitHub org（或个人账号）用来注册自托管 runner，以及一个能签发
   runner 注册 token 的 PAT
4. `OUTPOST_REPOS` —— 要监视的 app 仓库（逗号分隔的 clone URL 列表）；
   `.env` 必填字段：`OUTPOST_MODE=full`、`ROOT_DOMAIN`、`CF_TUNNEL_TOKEN`、
   `GIT_USER`、`GIT_TOKEN`、`MANIFEST_REPO_URL`、`GITHUB_RUNNER_URL`、
   `GITHUB_RUNNER_PAT`、`OUTPOST_REPOS`

```bash
git clone https://github.com/smithyhaus/outpost.git ~/outpost
cd ~/outpost
cp .env.example .env       # 编辑上面必填项；密码字段留空会自动生成
bash bootstrap.sh          # 安装并把 GitHub Actions runner 注册为 systemd 服务
bash verify.sh             # 应全 PASS
```

每个 app 仓库都需要 CI workflow + 一份与 gitee 同步的 github 副本 ——
`outpost onboard <repo-url>` 会完成注册并打印具体步骤（拷贝
`templates/github/outpost-build.yml`、配置双推或 gitee→github 单向镜像）。
全程不需要在任何地方注册 webhook —— runner 纯出站长轮询 github.com。

完成后：

- 打开 `INFRA.zh-CN.md` 查看所有连接串与密码
- 构建状态：app 仓库的 GitHub Actions 页面（或本机
  `journalctl -u actions.runner.*`）
- 部署状态：`outpost status`（manifest-sync 心跳）或 `outpost logs sync`

## 为什么用 Outpost

| 痛点 | Outpost 解决 |
|------|----------|
| "我开发要 Postgres + Redis + RabbitMQ，但每个都要自己起 + 暴露很烦。" | 一行 `bootstrap.sh`，全部服务起来 + TLS 终止的公网域名。 |
| "我家宽没公网 IP / 运营商封 80/443。" | Cloudflare Tunnel —— 仅出站连接，任何 NAT 后都能用。 |
| "我想 push 即部署，但不想搞 Jenkins，也不想跑一个 webhook 接收端。" | GitHub Actions 自托管 runner（纯出站长轮询）+ manifest-sync CronJob 已预接好。push 到你的 Git，应用自动滚动发布 —— 全程无任何入站端点。 |
| "我用 macOS / Linux / WSL2，大多教程只面向其中一种。" | 一个安装器自动识别 OS，走对应路径。 |
| "我不想被某个 Docker 仓库 / Git 平台绑死。" | Plugin 模型 —— 改一个环境变量就能切（self-hosted ↔ 阿里云 ACR；Gitee / GitHub / GitLab）。 |

## Plugins

| 类别         | 内置 plugin                                                | `.env` 选择器                            |
|--------------|------------------------------------------------------------|------------------------------------------|
| Registry     | `self-hosted` (默认), `aliyun-acr`                         | `REGISTRY_PLUGIN`                        |
| Git 提供商   | `gitee` (默认), `github`, `gitlab`                         | `GIT_PROVIDER_PLUGIN`                    |
| 测试运行器   | `testkube` (默认)                                           | `TEST_RUNNER`                            |
| 渐进发布     | `argo-rollouts`（可选，金丝雀 + 自动回滚，仅 controller）    | `ROLLOUT_PLUGIN` *(默认 `none`)*         |
| 通知通道     | `dingtalk`, `feishu`, `wecom`, `webhook-generic`           | `NOTIFICATION_PROVIDERS` *(逗号分隔)*    |

**v0.3.0：不再有 webhook。** `git-provider` plugin 现在是"凭据 +
`git ls-remote` 预检"契约，不再是 webhook 接线契约 —— CI 由 GitHub
Actions 自托管 runner（纯出站长轮询）承担，没有入站端点需要按 provider
分流。`GIT_PROVIDER_PLUGIN` 在 v0.3.0 是逗号列表（如 `gitee,github`），
因为"gitee 主推 + github 作为 CI 触发面"是双 provider 的常态配置，而非
边缘情况。详见 [`plugins/README.md`](plugins/README.md) 与
[ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)。

通过 `.env` 切换:

```env
REGISTRY_PLUGIN=aliyun-acr
GIT_PROVIDER_PLUGIN=gitee,github
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=argo-rollouts          # 默认: none
NOTIFICATION_PROVIDERS=dingtalk,feishu        # 任意组合
```

**CI/CD 测试网关 + 自动回滚 + 多通道告警** — 完整设计见
[`i18n/zh-CN/docs/proposals/cicd-test-gate.md`](i18n/zh-CN/docs/proposals/cicd-test-gate.md)
([English](i18n/en/docs/proposals/cicd-test-gate.md))。
端到端走法见 quickstart 的 "Phase J" 章节。

Plugin 协议与编写指南见 [`plugins/README.md`](plugins/README.md)。

## 日常 CLI

`scripts/outpost` 把每天用的 kubectl / registry / kubeseal 命令包成单一入口:

```bash
outpost status                       # manifest-sync 心跳 + Compose/k8s 总览
outpost verify [--app <name>]        # 健康检查;--app 只看某个应用
outpost open <search|mq|registry>    # 打印 URL + 凭据并自动开浏览器
outpost logs [sync|<app>] [--build]  # sync: 最近一次 manifest-sync Job 日志
                                     # <app>: 'apps' 命名空间下的 pod；--build: 构建日志现在在哪
outpost rollback <app> [sha]         # 列出 registry tag，回写 manifest 仓，等待 sync 收敛
outpost onboard <repo-url>           # 注册 OUTPOST_REPOS + 打印 CI workflow/双推设置
outpost seal <app> KEY=VALUE ...     # 封装 kubeseal,直接出 SealedSecret YAML
outpost new-app <name> --lang go|... # 从 examples/hello-world/<lang> scaffold
outpost decommission <app>           # 引导式清理
```

安装：

```bash
make install                          # symlink 到 /usr/local/bin/outpost（幂等）
make install PREFIX=~/.local/bin      # 换一个 prefix
make uninstall                        # 只移除指向本仓库的 symlink
```

或者不装直接跑：`bash scripts/outpost help`。

## AI 友好

项目内置面向 AI 编程助手的元数据：

- [`SKILL.md`](SKILL.md) —— Claude 风格的操作 skill（架构、不变量、常见任务）
- [`llms.txt`](llms.txt) —— 通用 [llms.txt](https://llmstxt.org) 入口
- [`verify.sh --json`](verify.sh) —— 机器可解析的健康输出（schema 锁定在 `tests/schema/verify-output.schema.json`）
- [`i18n/en/docs/07-ai-verification.md`](i18n/en/docs/07-ai-verification.md) —— AI 可直接执行的验证手册

把 Outpost 丢进 Claude Code 会话里问"基础设施健康吗？"
它会自动跑 `verify.sh --json` 并给你结构化报告。

## 文档

| 主题 | English | 中文 |
|------|---------|------|
| **Quick Start（先看这个）** | [docs/00](i18n/en/docs/00-quickstart.md) | [docs/00](i18n/zh-CN/docs/00-quickstart.md) |
| 架构 | [`ARCHITECTURE.md`](ARCHITECTURE.md) | （仅英文 —— 单一源） |
| Cloudflare 配置 | [docs/01](i18n/en/docs/01-cloudflare-setup.md) | [docs/01](i18n/zh-CN/docs/01-cloudflare-setup.md) |
| WSL2 配置（仅 WSL 用户） | [docs/02](i18n/en/docs/02-wsl-config.md) | [docs/02](i18n/zh-CN/docs/02-wsl-config.md) |
| Windows 自启 | [docs/03](i18n/en/docs/03-windows-autostart.md) | [docs/03](i18n/zh-CN/docs/03-windows-autostart.md) |
| 客户端 TCP 访问 | [docs/04](i18n/en/docs/04-client-access.md) | [docs/04](i18n/zh-CN/docs/04-client-access.md) |
| 接入新项目 | [docs/05](i18n/en/docs/05-onboard-project.md) | [docs/05](i18n/zh-CN/docs/05-onboard-project.md) |
| 故障排查 | [docs/06](i18n/en/docs/06-troubleshooting.md) | [docs/06](i18n/zh-CN/docs/06-troubleshooting.md) |
| AI 验证 | [docs/07](i18n/en/docs/07-ai-verification.md) | [docs/07](i18n/zh-CN/docs/07-ai-verification.md) |
| SealedSecret 工作流 | [docs/08](i18n/en/docs/08-seal-secret.md) | [docs/08](i18n/zh-CN/docs/08-seal-secret.md) |

## 项目状态

Outpost 当前为 **v0.3.1** —— 详见 [`CHANGELOG.md`](CHANGELOG.md)：CI/CD
引擎替换（Tekton + ArgoCD → GitHub Actions 自托管 runner + manifest-sync
CronJob）、入站 webhook 路径整体退役。数据层**两种模式下都留在宿主 Compose**
—— v0.3.0 曾短暂把它迁入 k3s，v0.3.1 在任何环境实际部署之前已回退。
决策依据见 [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md) /
[ADR-0005](docs/decisions/0005-data-layer-back-to-host.md)。

macOS / Linux / WSL2 上的真机端到端验证仍在进行中；路线图见
[`TODOS.md`](TODOS.md)。
当前版本号也可在 [`VERSION`](VERSION) 中查到；`outpost version`
会打印 `v<VERSION> (commit <sha>)`。

## 贡献

参见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。新 plugin、文档翻译、平台修复尤其欢迎。

## 许可证

[Apache License 2.0](LICENSE)

---

<sub>Outpost 是 **[smithyhaus](https://github.com/smithyhaus)** 出品的项目 —— 一座专做"小而锋利、以小博大"工具的工坊。</sub>
