# 07 — AI 验证指南

> 这份文档写给 AI（大模型）看。AI 进入 ~/outpost 目录时读 `SKILL.md` 了解项目，
> 读本文档掌握"如何主动验证基础设施健康"。
>
> 所有命令在 WSL2 Ubuntu 内执行。

标准上手顺序:

1. 读 `SKILL.md`(项目定位、不变量、文件索引)
2. 读本文(验证操作 + 诊断手册)
3. 跑 `bash verify.sh --json`,基于结构化输出推理

## 0. 一键全栈验证（首选）

```bash
bash verify.sh           # 人类视角（带颜色）
bash verify.sh --json    # 机器解析（推荐 AI 用这个）
bash verify.sh --quiet   # 仅汇总（systemd 定时器跑的就是这个）
```

**退出码语义**：
- `0` 全部 PASS
- `1` 存在 FAIL（需立即处理）
- `2` 仅有 WARN（可观察）

**JSON 输出格式**（AI 解析示例）：
```json
{
  "schema_version": "1",
  "summary": {"pass": 28, "warn": 2, "fail": 0, "os": "linux", "mode": "full"},
  "checks": [
    {"status": "PASS", "id": "tool.docker", "detail": "found at /usr/bin/docker"},
    {"status": "WARN", "id": "edge.skipped", "detail": "ROOT_DOMAIN unset"}
  ]
}
```

schema 锁定在 `tests/schema/verify-output.schema.json`。字段形状跨版本稳定,
破坏性变更会提升 `schema_version`。

**verify.sh 输出的小节顺序**:工具 → Compose → K8s 核心 → CI 触发 → CD →
对账 → 数据层 → 公网入口 → 凭据卫生。第 3–8 节在 `local` 模式下整体跳过。

**推荐的 AI 工作流**:

1. `bash verify.sh --json`
2. 解析 JSON
3. `summary.fail > 0` → 逐个 FAIL 按 §1 定位
4. `summary.warn > 0` → 列出 WARN 的 id 并简述影响
5. 都没有 → "基础设施健康"
6. 输出简短的结构化报告,不要把 PASS 细节全倒给用户

> **多项同时报红时,先看 `reconcile.*`。** 它是唯一从链条外部审判整条
> push→build→deploy 的检查,所以那里的 FAIL 往往是其他红项的**解释**,
> 而不是另一个独立问题。

## 1. 逐项诊断

每个 id 对应一条诊断路径。id 形如 `<area>.<subject>`。

### `tool.<name>`

探测集合:`local` 模式是 `docker openssl envsubst curl`;
`full` 模式再加 `kubectl helm git`。

| id | 恢复办法 |
|----|----------|
| `tool.docker` | 装 Docker(macOS 用 Desktop;Linux 用官方便捷脚本) |
| `tool.kubectl` | `sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl` |
| `tool.helm` | `curl get-helm-3 \| bash` |
| `tool.envsubst` | 装 `gettext` / `gettext-base` —— 否则模板渲染不了 |
| `tool.git` | 装 git —— 没有它对账根本跑不起来 |

> `yq`(mikefarah v4+)和 `buildctl` **不在**这个探测集合里,但 runner 主机
> 必须有 —— `scripts/ci/build-image.sh`、`run-tests.sh`、`outpost rollback`
> 缺了都会失败。`tool.*` 全绿**不能**证明构建主机是完整的。

### `docker.daemon`
```bash
sudo service docker start    # Linux/WSL2
open -a Docker               # macOS
```

### `kubectl.cluster`
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200
```

### `compose.<service>`

`full` 模式只应有 `cloudflared` + `caddy`;`local` 模式是四个数据服务。

```bash
docker compose -f core/compose/docker-compose.yml ps
docker logs <service> --tail 100
docker inspect --format '{{json .State.Health}}' <service>
```

### `cloudflared.tunnel`
```bash
docker logs cloudflared --tail 100
```
应至少有一行含 `Registered tunnel connection`。没有的话:`.env` 里 token
错了/过期、到 api.cloudflare.com 的 DNS 断了,或 QUIC(UDP/7844)被封 ——
试试 `CF_TUNNEL_PROTOCOL=http2`。

### `k8s.nodes`
```bash
kubectl get nodes
kubectl describe node $(kubectl get node -o jsonpath='{.items[0].metadata.name}')
```

### `k8s.<ns>.<deploy>` / `k8s.<ns>.<name>` / `k8s.no_crashloop`
```bash
kubectl describe deploy -n <ns> <deploy>
kubectl get pods -n <ns> -l app=<deploy>
kubectl logs -n <ns> -l app=<deploy> --tail 200
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> -p          # 上一次运行
```
`k8s.<ns>.<name>` WARN 表示某个 plugin 提供的对象不见了 —— 如果你确实启用了
那个 plugin,重跑 bootstrap。

### `buildkit.daemon` —— FAIL 意味着所有构建都会失败
```bash
kubectl -n buildkit get pods
kubectl -n buildkit logs deploy/buildkitd --tail 200
```
startupProbe 在脏缓存恢复时容忍约 6 分钟,所以刚重启后的 FAIL 应当按
"等一会儿再查一次"处理。

### `ci.runner` / `ci.runner.unit` / `ci.runner.online`
```bash
systemctl status 'actions.runner.*'
journalctl -u 'actions.runner.*' -n 200
cd ~/actions-runner && sudo ./svc.sh status
```
- `ci.runner` WARN → `GITHUB_RUNNER_PAT` 为空,runner 从未安装。
  **任何构建都不会触发。** 只有跑本仓库自己的 CI/e2e 时才算合法
- `ci.runner.unit` FAIL → systemd 服务没在跑。push 会在 GitHub 排队而不是
  报错,所以别处看起来一切正常
- `ci.runner.online` FAIL → GitHub 说没有在线 runner,或 api.github.com
  连不上(代理/出网,或 PAT 权限被收回)

### `ci.workflow.<app>`
通过 GitHub API 查该应用仓库最近一次工作流运行。
- WARN `no workflow runs yet` → 仓库里没有
  `.github/workflows/outpost-build.yml`
- FAIL `last run: failure` → 去 GitHub Actions UI 看那次运行

### `sync.cronjob` / `sync.heartbeat` / `sync.result`
```bash
kubectl -n outpost-ci get cronjob manifest-sync
kubectl -n outpost-ci get cm sync-heartbeat -o yaml
kubectl -n outpost-ci get jobs
bash scripts/outpost logs sync
```
- `sync.cronjob` FAIL → 什么都不会部署;重跑 bootstrap
- `sync.heartbeat` FAIL → 心跳超过 3× `MANIFEST_SYNC_INTERVAL`,sync 停了。
  卡住的 job 会挡掉后续 tick(`concurrencyPolicy: Forbid`)—— 删掉它
- `sync.result` FAIL → 上一次运行出错;`last_result` 自带说明
  (`error:git-clone`、`error:git-fetch`、`error:unexpected-rc=<n>` 等)

### `reconcile.<app>` —— 最终裁判
该仓库的 live 分支头在 `OUTPOST_STALENESS_THRESHOLD`(默认 1800 秒)内没有
变成已部署的镜像 tag。这一条检查同时覆盖:gitee→github 镜像死了、GitHub
连不上、runner 离线、工作流红了、buildkitd 挂了、sync 停摆 —— 因为它们
表现出来都是同一个症状。按链条顺序诊断:

```bash
git ls-remote <github-url> refs/heads/main   # 1. push 镜像过去了吗?
systemctl status 'actions.runner.*'          # 2. runner 活着吗?
# 3. GitHub Actions UI → 工作流红了吗?
# 4. manifest 仓库 → 有 `chore(<app>): bump image to <sha>` 这条提交吗?
bash scripts/outpost status                  # 5. sync 新鲜且 ok 吗?
```

相关 id:`reconcile.git`(没装 git)、`reconcile.manifest`
(`MANIFEST_REPO_URL` 未设)、`reconcile.repos`(`OUTPOST_REPOS` 为空 ——
反静默层是瞎的,把应用接进来)。

### `data.<service>`
```bash
kubectl -n infra-bridges get pods
kubectl -n infra-bridges logs sts/<service> --tail 200
kubectl -n infra-bridges exec sts/postgres -- sh -c 'pg_isready -U "$POSTGRES_USER"'
```
这些是在 pod 内部执行的真实带认证探测,所以 FAIL 意味着服务真的挂了或在拒绝
凭据 —— 不是网络层面的猜测。

### `edge.<sub>`
v0.3 只有 `edge.search` / `edge.mq` / `edge.registry`
(ArgoCD / Tekton / hooks 那几条路由已经没了)。
- `000` —— DNS 没解析到 Cloudflare,或完全没响应
- `502/503/504` —— origin(你的栈)挂了
- `4xx` —— 探测场景下通常仍算 PASS(裸 GET 返回 401/403 恰恰证明链路是通的)

```bash
dig <sub>.<root>
curl -v https://<sub>.<root>
```

### `creds.env_perm` / `creds.env` / `creds.infra_md`
重跑 bootstrap 即可恢复;`.env` 权限会被自动设成 600。

## 2. 决策树

```
verify.sh --json
   │
   ├── 有 FAIL? ──────────────────────────────────────────┐
   │                                                       │
   │  先看 reconcile.* —— 它能解释大多数整条链的红          │
   │  然后按 area 逐个处理:                                │
   │  · tool.* / docker.* / kubectl.*  → 安装/启动         │
   │  · compose.* / cloudflared.*      → §1                │
   │  · k8s.* / buildkit.*             → §1                │
   │  · ci.*    (构建那半边)           → §1                │
   │  · sync.*  (部署那半边)           → §1                │
   │  · data.* / edge.*                → §1                │
   │                                                       │
   │  解决后重跑 verify.sh --json                          │
   │                                                       │
   └── 只有 WARN? → 列出并继续                             │
                                                           │
   全 PASS? ───────────────────────────────────────────────┘
       └── 报告"基础设施健康"
```

## 3. 给 AI 的系统提示词片段

可直接放进 system prompt 或 skill 激活消息:

```
你正在一个 Outpost 检出目录中操作。
1. 任何动作之前,先读 SKILL.md 和 i18n/zh-CN/docs/07-ai-verification.md。
2. 评估健康度:bash verify.sh --json,解析 JSON。
3. 回答连接串相关问题一律读 INFRA.zh-CN.md,绝不自己编。
4. 修改状态时:先读现有文件 → 展示 diff → 取得用户同意 → 应用 → 对受影响的部分重跑 verify.sh。
5. 除非用户明确说了"reset"或"清空",否则绝不运行 reset.sh。
6. 绝不删除这些命名空间:infra-bridges、outpost-ci、buildkit、registry、kube-system。
7. 绝不对 `apps` 命名空间执行 kubectl apply —— 它的事实来源是 manifest 仓库。改 manifest 仓库,让 manifest-sync 收敛。
8. 绝不回显任何密钥:.env 的值、token、GITHUB_RUNNER_PAT,或任何 Secret 的内容。
```

## 4. 修改后的验证

Agent 改完配置之后:

```bash
kubectl apply -f <changed.yaml>     # 或 compose、或 platform 脚本
sleep 20                            # 等 reconcile 完成
bash verify.sh --json | jq '.checks[] | select(.status != "PASS")'
```

如果改动是通过 manifest 仓库落地的,要等一个 `MANIFEST_SYNC_INTERVAL`
(默认 2 分钟)—— 或者手动催一次:

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
bash scripts/outpost logs sync
```

若新增的非 PASS 项都在预期内(比如构建还在跑,`reconcile.<app>` 暂时滞后),
可以继续;否则回滚并询问用户。

## 5. `verify.sh` 的已知边界

verify.sh **不**检查:

- 应用层业务逻辑(应用应自己暴露 /healthz)
- sealed-secrets 的密码学正确性(只检查 controller pod)
- 构建结果是否**正确** —— 只看最近一次运行是否绿、live HEAD 最终有没有
  变成已部署的 tag
- TLS 证书有效期(Cloudflare 管)
- 磁盘空间(主机层面的事)

它同样看不见任何**不在 `OUTPOST_REPOS` 里**的仓库。那份清单就是对账的依据;
没注册的应用照样能构建、能部署,但对反静默层是隐形的。

以上情况请跑针对性的命令,或直接升级给用户处理。
