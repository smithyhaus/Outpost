# Outpost v0.3.0 — CI/CD 引擎替换方案（Tekton+ArgoCD → GitHub Actions runner + manifest-sync）

> 2026-08-15。多 agent 调研产出（6 子系统审计 + 116 提交事故考古 + 外部证据调研
> + 3 方对抗评审 + 综合裁决 + 用户约束修订）。执行载体：本仓库 v0.3.0；
> 落地时机：WSL2 整机重装。
>
> **修订记录**：初版裁决为自研轮询 dispatcher；用户追加约束
> **「尽量避免自建 CI/CD，优先现成组件（如 Drone 等）」** 后改选
> GitHub Actions self-hosted runner（现成引擎）+ manifest-sync CronJob（胶水级 CD）。
> 诊断结论、拆除清单、防静默设计不变。
>
> **修订记录 2**（同日，v0.3.1）：数据层裁决被用户否决 ——
> **「pg/redis/mq 这个有状态的，肯定要跑在宿主里，不跑在集群内」**。
> 数据四件套回归宿主 Compose（两种模式一致），k3s 侧恢复加固版
> ExternalName 桥（coredns-hosts-reconciler 自愈 + verify.sh 新增
> data.bridge_dns / data.bridge_reconciler 两项 FAIL 级对账）。
> 见 [ADR-0005](../../decisions/0005-data-layer-back-to-host.md)。
> CI/CD 引擎选择（GHA runner + manifest-sync）不受影响。

## 0. 要回答的问题

**「CI/CD 反复出问题，是我配置不对，还是组件选型有问题？」**

## 1. 诊断结论

**主因是组件选型错误，不是配置错误。** 为多团队/多节点平台设计的引擎
（Tekton 16 CRDs + 4 控制器 + 5 admission webhooks；ArgoCD 7 进程）被装进了
1 人 / 1 节点 / CN 出口 / WSL2 的环境。

对 116 个提交中 72 个事故/加固提交的归因统计：

| 归因 | 占比 | 说明 |
|---|---|---|
| 纯配置错误 | ~12% (9/72) | 全部一次性、修复后 bats 锁定、**零复发** —— "配错了"被提交史证伪 |
| 组件选型（直接） | ~50% (36/72) | webhook 静默丢失 ×3 形态（含 9 天全停）、Tekton CRD footgun ×10、DiskPressure ×3+、manifest 推送竞态 |
| 组件选型（含 CN 放大） | ~62% | 14 起 cn-egress 提交中 ~9 起仅因 ephemeral-pod 每次构建重拉镜像/工具而存在 |
| 自有设计债 | ~26% | fake-OK 验证文化（已大体收口）、compose↔k3s 数据桥（全站最大爆炸半径）、manifest 并发写模式 —— **换引擎带不走，借重装一并处理** |

关键校准：ArgoCD 的 reconcile 循环本身出现在 0 个复发事故类里——错的是
CI 半边 + 入站 webhook 触发传输 + 部署侧的"尺寸"。

## 2. 组件选型评审（含"避免自建"约束）

### 现成组件逐一裁决

| 候选 | 结论 | 理由 |
|---|---|---|
| **Drone CI** | ❌ | 有原生 gitee driver（go-scm/driver/gitee），**但 server 是 forge 入站 webhook 触发**——gitee webhook 投递不可靠是有文档记载的常见故障类，等于 9 天事故换个接收器复发；且 Drone 被 Harness 收购后本体维护模式，后继 Gitness 不支持 gitee |
| **Woodpecker CI** | ❌ | 极轻（server ~50-100MB）但**无 gitee driver**（仅 addon 路线），且同样是 forge 入站 webhook 触发 |
| **Gitee Go** | ❌ | 免费额度受限（仓 200 分钟/组织 1000 分钟每月，低置信需核实）、云端黑盒、无法本地构建缓存 |
| **Tekton 保留+加固** | ❌ | C3/C4=2/5 永久分：16 CRDs/4 控制器/每构建 5-6 pod 考古，服务 1 个人；~82k vendored LOC 每次升级重跑镜像验证战役 |
| **Gitea + Gitea Actions** | 备选 | 唯一端到端拉取且全内网的方案（act_runner 轮询本地 gitea），但要把 **git 托管本身搬上这台机器**——源码单一真相落到最脆弱的盒子上，迁移面大。留作 Plan-B |
| **GitHub Actions self-hosted runner** | ✅ **选定** | 官方确认**纯出站 50s 长轮询、零入站要求**；HTTP 代理一等支持（适配 v2ray）；常驻 RES <100MB；org 级 runner 私有仓共享（smithyhaus org 已在用）；引擎（队列/调度/重试/日志/UI/并发组）全由 GitHub 提供，**自建面 = 每仓 ~40 行 workflow YAML + 复用本仓已淬火脚本** |

### 部署侧（CD）

ArgoCD 整体移除。部署由 **manifest-sync CronJob** 承担：k3s CronJob 每 2 分钟
`git pull`（gitee 侧 manifest 仓）→ 变更应用 `kubectl apply -k` + rollout
等待 → 通知。单写者、串行、~百行胶水脚本（与 update-manifest.sh 同级别，
**不是自建引擎**——调度靠 k8s CronJob，语义就是定时 pull+apply）。
显式收益：**部署/回滚热路径纯国内**（gitee + 本地集群），github/代理挂掉
不影响已构建版本的部署与回滚。
（若日后想要零胶水，文档记录了 ArgoCD core-install 备选——但它带回 3 CRDs +
3 进程 + 30k vendored LOC，账本显示其独有能力使用量为零。）

## 3. 目标架构（v0.3.0）

### 保留 / 新增 / 移除

| | 组件 |
|---|---|
| **保留** | k3s+Traefik、sealed-secrets（唯一保留的第三方 CRD）、registry+GC（KEEP_N 5→10）、Verdaccio、**buildkitd 原样**、cloudflared+caddy（compose 边缘 profile）、notify-fanout + sign-webhook、update-manifest（**含 6 次抖动重试**，跨仓 workflow 并发仍需要）/ read-build-config 核心逻辑与 goldens |
| **新增** | 宿主 **GitHub Actions runner**（官方 actions/runner，systemd 服务，org 级注册，代理经 ~/.outpost-proxy.env）；**manifest-sync CronJob**（ns `outpost-ci`）；`templates/github/outpost-build.yml`（应用仓 workflow 模板）；`scripts/ci/`（workflow 调用的构建/测试/发包脚本，移植自 tekton task）；buildkitd/registry NodePort（宿主 runner 直连）；`platform/systemd/outpost-verify.timer` 死人开关；数据层四件套 StatefulSet 入 k3s |
| **移除** | Tekton 全家（16 CRDs/4 控制器/5 admission webhooks/dashboard/EL/CEL/pruner）、ArgoCD 全家（7 进程/3 CRDs/notifications）、Rollouts dashboard、webhook 路径整体（register-webhooks、GIT_WEBHOOK_SECRET、hooks.<domain> 路由）、host.docker.internal/CoreDNS 桥、~80k LOC vendored YAML。集群 CRD 23+ → 1（+可选 4） |

### 流程

```
dev: git push（gitee 为主；双推或 gitee→github 单向推送镜像同步到 github）
  → GitHub 触发 workflow → 宿主 runner（出站长轮询领任务，单 runner=天然基本串行）
  → checkout → scripts/ci/build-image.sh（buildctl→127.0.0.1:30750 buildkitd，
    路径穿越防护+ACR-safe push 原样移植；push→registry NodePort，sha-7 tag）
  → Gate A（可选，outpost.test.yaml 语义）→ update-manifest.sh（gitee manifest 仓）
  → [失败任一步] notify-fanout build-failed
manifest-sync CronJob（每 2min，Forbid 并发）：
  → git pull manifest 仓 → 变更应用 apply -k + rollout status（kind:Rollout 感知）
  → 心跳 CM（last_sync_ts/applied_head）→ deploy-succeeded/deploy-failed 通知
```

### C1 三层防静默（链条任何一环死掉都必然响亮）

1. **verify.sh 对账（终极裁判，站在整条链外面）**：对 OUTPOST_REPOS 每仓
   认证 ls-remote，live HEAD vs manifest 仓已部署 tag——不一致超阈值
   （默认 30min）→ **FAIL 并点名**。镜像同步断/GitHub 不可达/runner 掉线/
   workflow 红/buildkit 死/sync 停——无论哪环断，这里必报。
2. **活性检查**：runner systemd unit active + gh api runner online（GitHub
   不可达本身 = FAIL"CI 触发路径中断"）；sync 心跳龄 >3×周期 → FAIL；
   数据层四服务真实 TCP/auth 探活 → FAIL。
3. **宿主 systemd timer**（30min，Persistent=true）跑 `verify.sh --quiet`，
   FAIL 直推通知——探测器活在集群与 GitHub 之外。

### gitee 与 github 分工（C8）

- **gitee = 主推送地 + manifest 仓 + 对账基准**（国内、快、习惯不变）。
- **github = CI 触发面**：app 仓需有 github 副本。同步二选一：
  （推荐）**双推**——各仓 `git remote set-url --add --push origin <github-url>`，
  一次 push 双达，失败在终端立刻可见；（备选）gitee 官方**单向**推送镜像
  gitee→github（官方警告：勿用双向镜像，30 分钟窗口互推有丢码风险）。
- 无任何 webhook 需要注册；gitee 明文 token vs github HMAC 的不对称随之消失。

### 回滚

`outpost rollback <app> [sha]`：registry 列 tag（保留 10 个）→ yq 回写
manifest 仓（gitee）→ sync 下周期收敛（≤2min）。**纯国内路径，github 挂了
也能回滚。** 破玻璃 `kubectl rollout undo` 可用，但必须跟 manifest revert
（否则 sync 顶回——真相被强制执行是特性）。

### 数据层裁决（full 模式入 k3s，不变）

WSL IP 漂移 → 4 服务 ×17 应用全站失联是账本上最大爆炸半径；单节点上
"别把数据库放 k8s"论据双向失效（compose 同样无 HA）。StatefulSet +
local-path PVC(Retain)，**Service 名与 infra-bridges 命名空间不变——应用
连接串零改动**。local = 纯 compose；full = k3s 承载一切、compose 只当边缘
（ADR-0004 修订 ADR-0001）。

## 4. 工作域（6 区）

1. **引擎拆除**：05-tekton/、04-argocd/、vendor ×6、cel-helpers/EL 拼接、
   register-webhooks/tekton-prune/vendor-catalog、随体 bats、命名空间收口
2. **CI/CD 引擎**：scripts/ci/（build-image/run-tests/publish-npm，移植
   tekton task 淬火逻辑）+ scripts/sync/manifest-sync.sh + core/k8s/03-ci/
   （sync CronJob/RBAC/PVC/NodePorts）+ templates/github/outpost-build.yml
   + outpost CLI（rollback/logs/status/onboard）+ manifest-map 提取共用 + bats
3. **数据层入簇**：06-bridges 四服务 StatefulSet 化、coredns-reconciler 删除、
   compose profiles(local-data/edge)、Caddyfile.d 审计、mq/search IngressRoute
4. **bootstrap/verify 重接线**：08-ci.sh（buildkitd 原块 + NodePorts + sync
   CronJob + runner 安装注册 + 基础镜像预拉 retag + systemd timer）、verify.sh
   对账化重写、doctor --egress 探 gitee/github/daocloud、reset.sh 数据护栏
   + runner 反注册、install.sh gitee fallback、status.sh
5. **插件契约 v2 + .env**：git-provider=凭据+真实 ls-remote preflight、
   notification=CI/sync/verify 事件、rollout=controller-only 默认关、
   catalog-tasks 删除、.env.example（GITHUB_RUNNER_*、OUTPOST_REPOS 等）
6. **文档与产品面**：VERSION 0.3.0、CHANGELOG breaking、ADR-0003/0004、
   ARCHITECTURE/README/SKILL/INFRA 模板、e2e workflow 改造（runner skip 模式）、
   TODOS 清账、重装 runbook（docs/prp/runbooks/wsl2-redeploy-0.3.md）

**不许动的淬火件**：08-buildkit 整目录（NodePort 以新增文件方式加）、
verdaccio、registry-gc 技巧、notify-fanout+sign-webhook、update-manifest
核心+6 次重试+goldens、portable.sh、sealed-secrets 恢复链、CN vendoring
纪律、sha-7 契约、wsl2-migrate-preflight.sh。

## 5. 风险要点

- **github.com 可达性成为 CI 触发依赖**（构建路径，非部署路径）：runner
  经 v2ray 代理长轮询；代理/GFW 抖动 → 构建排队延迟。缓解：①对账层把
  停滞变 FAIL+通知；②部署/回滚热路径纯国内不受影响；③极端情况
  scripts/ci/ 可在宿主手动执行（workflow 步骤本就是普通脚本，天然逃生门，
  不构成第二引擎）。
- runner 跑仓库代码于宿主（单租户可接受）：runner group 限私有仓（GitHub
  默认）、勿接公开仓 PR；PAT 仅 admin:org 最小面、注册后可撤。
- runner systemd 已知摩擦（svc.sh 203/权限类）：preflight 已断言 systemd；
  runbook 含 `systemctl status` 验收与已知 busy-wait CPU bug 说明（钉版）。
- gitee→github 同步断裂（双推漏配/镜像失效）：对账层点名 FAIL；双推方案
  失败直接在开发终端可见。
- 数据入簇后 reset 爆炸半径：PVC Retain + reset.sh 护栏 + dump-first 纪律。
- 失去 ArgoCD UI/金丝雀自动中止：账本使用量为零；registry 保留 10 tag +
  manifest git log 界定回滚深度；金丝雀以默认关插件保留复活通道。

## 6. WSL2 重装 runbook

完整步骤见 `docs/prp/runbooks/wsl2-redeploy-0.3.md`。新增于旧版的关键项：
github org 下建/确认 15 个 app 仓副本 + 双推或 gitee 推送镜像配置、
runner 注册验收（`systemctl status` + GitHub UI online）、双 provider 空提交
端到端验收、死人开关验收（停 sync CronJob → 等 verify-failed 通知）、
WSL 重启复测（runner/timer/数据层自愈）。

## 附：证据来源（关键判断）

- GHA runner 纯出站长轮询/无入站要求：GitHub 官方社区讨论 26630、GH Docs
  self-hosted runners；代理支持：GH Docs using-a-proxy-server。
- Drone 支持 gitee（go-scm driver/gitee）但 webhook 触发 + 维护模式
  （docs.drone.io/server/overview、drone/go-scm、docs.drone.io/faq/gitness）。
- Woodpecker 无 gitee driver（woodpecker-ci.org forges overview）；
  server 需 forge 入站 webhook。
- gitee webhook 不可靠为已记载故障类（gitee 官方 issue/帮助文档）；
  gitee 镜像功能与双向风险警告（help.gitee.com sync-between-gitee-github）。
- git ls-remote 不受 REST 限流（GH Docs rate-limits + community 44515）。
- org 级 runner 与私有仓共享（GH Docs runner-groups、GH Changelog 2020-04-22）。
