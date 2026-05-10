# Outpost

> **一行命令，把一整套自托管开发后端跑在你自己的设备上。**
> Postgres / Redis / RabbitMQ / Meilisearch + 完整 GitOps CI/CD 流水线，
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
            │              │    │                     │
            │  Postgres    │    │  ArgoCD (GitOps CD) │
            │  + pgvector  │    │  Tekton + Webhook   │
            │  Redis       │    │  Docker Registry    │
            │  RabbitMQ    │    │  你的应用            │
            │  Meilisearch │    │                     │
            └──────────────┘    └────────────────────┘
```

- **数据层（Compose）** —— 跑几乎每个项目都需要的有状态服务。
- **应用层（k3s）** —— 跑你的应用 + 完整 GitOps 流水线：
  push 代码 → Tekton 构建 → 推 Registry → ArgoCD 部署。
- **一个 Cloudflare Tunnel** 把所有东西暴露在你自己域名的子域上。
  不需要路由器配置、不需要公网 IP，双层 NAT 也能用。

## 两种模式

Outpost 提供两种模式，按当前需求挑一个。

| 模式 | 跑什么 | 必填项 | 适用场景 |
|------|--------|--------|----------|
| **`local`** *(默认)* | Compose 数据服务跑在 `localhost`：PG、Redis、RabbitMQ、Meilisearch | 无 —— 全部默认值或自动生成 | 本机当个人开发后端，不需要公网，不需要 CI/CD |
| **`full`** | `local` 的全部 + Cloudflare Tunnel + k3s + ArgoCD + Tekton | `ROOT_DOMAIN`、`CF_TUNNEL_TOKEN`、`GIT_USER`、`GIT_TOKEN`、`MANIFEST_REPO_URL` | 需要把服务挂到自己域名上 + push 即部署的 GitOps |

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
2. 一个 Gitee / GitHub / GitLab **空 manifest 仓库**（含 `apps/` 和 `argocd-apps/` 两个空目录）+ 一个 PAT
3. `.env` 里 6 个必填字段：`OUTPOST_MODE=full`、`ROOT_DOMAIN`、`CF_TUNNEL_TOKEN`、`GIT_USER`、`GIT_TOKEN`、`MANIFEST_REPO_URL`

```bash
git clone https://github.com/smithyhaus/outpost.git ~/outpost
cd ~/outpost
cp .env.example .env       # 编辑上面 6 项；密码字段留空会自动生成
bash bootstrap.sh          # ~5 分钟
bash verify.sh             # 应全 PASS
```

完成后：

- 打开 `INFRA.zh-CN.md` 查看所有连接串与密码
- ArgoCD UI: `https://argocd.<你的域名>`
- 给你的 Git 提供商配 webhook 用：`https://hooks.<你的域名>`

## 为什么用 Outpost

| 痛点 | Outpost 解决 |
|------|----------|
| "我开发要 Postgres + Redis + RabbitMQ，但每个都要自己起 + 暴露很烦。" | 一行 `bootstrap.sh`，全部服务起来 + TLS 终止的公网域名。 |
| "我家宽没公网 IP / 运营商封 80/443。" | Cloudflare Tunnel —— 仅出站连接，任何 NAT 后都能用。 |
| "我想 push 即部署，但不想搞 Jenkins。" | Tekton + ArgoCD 已预接好。push 到你的 Git，应用自动滚动发布。 |
| "我用 macOS / Linux / WSL2，大多教程只面向其中一种。" | 一个安装器自动识别 OS，走对应路径。 |
| "我不想被某个 Docker 仓库 / Git 平台绑死。" | Plugin 模型 —— 改一个环境变量就能切（self-hosted ↔ 阿里云 ACR；Gitee / GitHub / GitLab）。 |

## Plugins

| 类别         | 内置 plugin                                                | `.env` 选择器                            |
|--------------|------------------------------------------------------------|------------------------------------------|
| Registry     | `self-hosted` (默认), `aliyun-acr`                         | `REGISTRY_PLUGIN`                        |
| Git 提供商   | `gitee` (默认), `github`, `gitlab`                         | `GIT_PROVIDER_PLUGIN`                    |
| 测试运行器   | `testkube` (默认), `catalog-tasks`                         | `TEST_RUNNER`                            |
| 渐进发布     | `argo-rollouts` (默认 — 金丝雀 + 自动回滚)                  | `ROLLOUT_PLUGIN`                         |
| 通知通道     | `dingtalk`, `feishu`, `wecom`, `webhook-generic`           | `NOTIFICATION_PROVIDERS` *(逗号分隔)*    |

通过 `.env` 切换:

```env
REGISTRY_PLUGIN=aliyun-acr
GIT_PROVIDER_PLUGIN=github
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=argo-rollouts
NOTIFICATION_PROVIDERS=dingtalk,feishu        # 任意组合
```

**CI/CD 测试网关 + 自动回滚 + 多通道告警** — 完整设计见
[`i18n/zh-CN/docs/proposals/cicd-test-gate.md`](i18n/zh-CN/docs/proposals/cicd-test-gate.md)
([English](i18n/en/docs/proposals/cicd-test-gate.md))。
端到端走法见 quickstart 的 "Phase J" 章节。

Plugin 协议与编写指南见 [`plugins/README.md`](plugins/README.md)。

## 日常 CLI

`scripts/outpost` 把每天用的 kubectl / argocd / kubeseal 命令包成单一入口:

```bash
outpost status                       # Compose + k8s 总览
outpost verify [--app <name>]        # 健康检查;--app 只看某个应用
outpost open <argocd|tekton|rollouts|search|mq|registry>
                                     # 打印 URL + 凭据并自动开浏览器
outpost logs <app> [--build]         # tail 容器日志 / 最近一次 PipelineRun 日志
outpost rollback <app>               # argocd app rollback(有确认)
outpost seal <app> KEY=VALUE ...     # 封装 kubeseal,直接出 SealedSecret YAML
outpost new-app <name> --lang go|... # 从 examples/hello-world/<lang> scaffold
outpost decommission <app>           # 引导式清理
```

加到 PATH:

```bash
ln -s "$PWD/scripts/outpost" /usr/local/bin/outpost
```

或直接 `bash scripts/outpost help`。

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

Outpost 当前为 **v0.1.0** —— 首次公开发布。v0.1 范围功能完整，但 macOS /
Linux / WSL2 上的真机端到端验证仍在进行中。路线图（验证后的 MVP → tunnel
plugin、AI 生态、Helm 打包）见 [`TODOS.md`](TODOS.md)。

## 贡献

参见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。新 plugin、文档翻译、平台修复尤其欢迎。

## 许可证

[Apache License 2.0](LICENSE)

---

<sub>Outpost 是 **[smithyhaus](https://github.com/smithyhaus)** 出品的项目 —— 一座专做"小而锋利、以小博大"工具的工坊。</sub>
