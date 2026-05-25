# 07 — AI 验证指南

> 这份文档写给 AI（大模型）看。AI 进入 ~/infra 目录时读 `SKILL.md` 了解项目，
> 读本文档掌握"如何主动验证基础设施健康"。
>
> 所有命令在 WSL2 Ubuntu 内执行。

## 0. 一键全栈验证（首选）

```bash
bash verify.sh           # 人类视角（带颜色）
bash verify.sh --json    # 机器解析（推荐 AI 用这个）
bash verify.sh --quiet   # 仅汇总
```

**退出码语义**：
- `0` 全部 PASS
- `1` 存在 FAIL（需立即处理）
- `2` 仅有 WARN（可观察）

**JSON 输出格式**（AI 解析示例）：
```json
{
  "summary": {"pass": 28, "warn": 2, "fail": 0},
  "checks": [
    {"status": "PASS", "id": "tool.docker", "detail": "found at /usr/bin/docker"},
    {"status": "WARN", "id": "edge.skipped", "detail": "ROOT_DOMAIN unset, ..."}
  ]
}
```

**AI 工作流**：
1. 跑 `bash verify.sh --json`
2. 解析 summary，若 FAIL > 0 直接报告失败项
3. 对每个 FAIL，按本文档对应章节诊断
4. 整理简短结论（PASS 不展开，FAIL 给出修复建议）

---

## 1. 单项验证 checklist

每个检查项格式：
- **id**：与 verify.sh 输出对齐
- **命令**：手动复现
- **预期**：通过标准
- **失败时**：诊断步骤

### 1.1 工具链

| id | 命令 | 预期 | 失败时 |
|----|------|------|--------|
| `tool.docker` | `command -v docker` | 路径输出 | `apt install docker.io` 或重装 Docker Desktop |
| `tool.kubectl` | `command -v kubectl` | 路径输出 | `sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl` |
| `tool.helm` | `command -v helm` | 路径输出 | `curl get-helm-3 \| bash` |
| `docker.daemon` | `docker info` | 无错误 | `sudo service docker start` |
| `kubectl.cluster` | `kubectl version --short` | server version 显示 | `sudo systemctl status k3s` |

### 1.2 Compose 服务

```bash
docker compose -f compose/docker-compose.yml ps
```
**预期**：6 个容器全部 `running`，healthy 状态：
- cloudflared
- caddy
- postgres (healthy)
- redis (healthy)
- rabbitmq (healthy)
- manticore (healthy)

**单项失败诊断**：
```bash
docker logs <name> --tail 100
docker inspect --format '{{json .State.Health}}' <name>
```

### 1.3 cloudflared 隧道

```bash
docker logs cloudflared --tail 30 | grep "Registered tunnel connection"
```
**预期**：至少 4 行（CF 一般连 4 个 region）。

**失败时**：
- token 错 → 查 `.env` 的 `CF_TUNNEL_TOKEN`，与 CF Dashboard 对比
- 网络不通 → `docker exec cloudflared cloudflared --version` 看是否能进容器
- DNS → `docker exec cloudflared nslookup api.cloudflare.com`

### 1.4 PostgreSQL pgvector

```bash
source .env
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT extname, extversion FROM pg_extension;"
```
**预期**：含 `vector`、`uuid-ossp`、`pg_trgm`。

**失败时**：扩展未装 → 直接 `CREATE EXTENSION IF NOT EXISTS vector;`。`postgres-init/01-pgvector.sql` 仅在 volume 全新时执行。

### 1.5 k3s 节点

```bash
kubectl get nodes -o wide
```
**预期**：1 个节点，STATUS=Ready，Kubernetes 版本 v1.28+。

**NotReady 诊断**：
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200 --no-pager
kubectl describe node $(hostname)
```
常见原因：cgroup v2 缺失、iptables 模块、内存不足。

### 1.6 关键 namespace 的 pod

```bash
kubectl get pods -n argocd
kubectl get pods -n tekton-pipelines
kubectl get pods -n registry
kubectl get pods -n kube-system
```
**预期所有**：`STATUS=Running`，`READY=1/1`（或对应数量）。

**异常 pod 通用诊断**：
```bash
kubectl describe pod -n <ns> <pod>     # 重点看 Events 段
kubectl logs -n <ns> <pod> --tail 100 --all-containers
kubectl logs -n <ns> <pod> -p          # 上一次 crash 的日志
```

### 1.7 桥接 Service

```bash
kubectl get svc -n infra-bridges
```
**预期**：4 个 ExternalName Service，externalName 都是 `host.docker.internal`。

**连通性测试**：
```bash
kubectl run -it --rm test-bridge --image=alpine --restart=Never -- \
  sh -c "apk add --no-cache busybox-extras >/dev/null && \
         nc -zv postgres.infra-bridges.svc.cluster.local 5432 && \
         nc -zv redis.infra-bridges.svc.cluster.local 6379"
```
**预期**：两条 `open`。

**失败时**：
- DNS 解析失败 → coredns 异常：`kubectl logs -n kube-system -l k8s-app=kube-dns`
- 解析到但连不上 → mirrored networking 没生效或 Compose 端口未绑 0.0.0.0；检查 `compose/docker-compose.yml` 的 `ports` 段

### 1.8 ArgoCD Application

```bash
kubectl get application -n argocd
```
**输出列**：`NAME / SYNC STATUS / HEALTH STATUS`。

**预期**：root 应当 `Synced/Healthy`；其他子 Application 视 manifest 仓库内容而定。

**OutOfSync 诊断**：
```bash
kubectl get application -n argocd <name> -o yaml | yq '.status.conditions'
```
- `ComparisonError`：manifest 仓库 yaml 语法错或不可访问
- 缺凭据：`kubectl get secret -n argocd git-manifest-repo`
- 网络：ArgoCD repo-server pod 内 `curl https://gitee.com`

### 1.9 Tekton EventListener

```bash
kubectl get eventlistener -n tekton-pipelines
kubectl get svc -n tekton-pipelines | grep el-
```
**预期**：`build-listener` Ready=True，对应 service `el-build-listener` 端口 8080（v0.3 起名字与 git provider 解耦）。

**测试 webhook 入口**（不发实际 push）：
```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST https://hooks.${ROOT_DOMAIN}
```
**预期**：返回 `400` 或 `412`（缺 header，正常拒绝）。**绝不**应当 `502/000`。

**EventListener pod 异常**：
```bash
kubectl logs -n tekton-pipelines deploy/el-build-listener --tail 100
```

### 1.10 Tekton 最近 PipelineRun

```bash
kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp | tail -5
```
**字段含义**：
- `SUCCEEDED=True` 成功
- `SUCCEEDED=False` 失败
- `SUCCEEDED=Unknown` 进行中或 pending

**查看失败原因**：
```bash
kubectl describe pipelinerun -n tekton-pipelines <name>
# 找 Status → Conditions → Message
# 然后定位失败的 TaskRun
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<name> --all-containers --tail=200 --prefix
```

### 1.11 Docker Registry

```bash
# 集群内访问
kubectl run -it --rm test-reg --image=alpine --restart=Never -- \
  sh -c "apk add curl >/dev/null && \
         curl -sf http://docker-registry.registry.svc.cluster.local:5000/v2/_catalog"
```
**预期**：返回 `{"repositories":[...]}` JSON。

```bash
# 外网访问
curl -sf https://registry.${ROOT_DOMAIN}/v2/_catalog
```

### 1.12 公网入口（端到端）

```bash
for sub in argocd search mq registry hooks; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 "https://${sub}.${ROOT_DOMAIN}")
  echo "${sub}.${ROOT_DOMAIN}: ${code}"
done
```

**判定**：
- `argocd / mq / registry`：200/302/401/403 都正常（401/403 因为可能有 CF Access 或登录拦截）
- `search`：调 `/health` 应当 200
- `hooks`：直接 GET 应当 405 或 400（不是 200）；POST 缺 header 应当 400/412
- 任何 `502/503/504/000` = FAIL

---

## 2. 故障决策树

```
verify.sh 失败？
├─ 是 →
│   ├─ 失败项在 §1（工具）？ → 装/起对应工具
│   ├─ 失败项在 §2（Compose）？
│   │   ├─ 容器 missing → docker compose -f compose/docker-compose.yml up -d
│   │   ├─ 容器 unhealthy → docker logs <name> 找根因
│   │   └─ cloudflared 未连通 → 见 §1.3
│   ├─ 失败项在 §3（k3s）？
│   │   ├─ 节点 NotReady → 系统级问题（cgroup/iptables/内存）
│   │   └─ pod 异常 → kubectl describe + logs
│   ├─ 失败项在 §4（桥接）？
│   │   ├─ Service 缺失 → kubectl apply -f k8s/06-bridges/
│   │   └─ 连通失败 → mirrored networking 或端口绑定错
│   ├─ 失败项在 §5（ArgoCD）？
│   │   ├─ ComparisonError → manifest 仓库内容或访问
│   │   └─ Degraded → 应用层问题，看子 Application 详情
│   ├─ 失败项在 §6（Tekton）？
│   │   ├─ EventListener Down → kubectl logs
│   │   └─ webhook 入口 502 → cloudflared 路由 / Traefik NodePort
│   └─ 失败项在 §7（公网入口）？
│       ├─ DNS 解析不到 → CF Dashboard 没配 Public Hostname
│       ├─ 502 → 后端服务死了
│       └─ 521/522/524 → cloudflared 没起或不可达
└─ 否（全 PASS）→ 报告"基础设施健康"
```

---

## 3. AI 自检脚本（推荐使用模式）

AI 验证基础设施的标准模式：

```
1. cd ~/infra
2. cat SKILL.md  （了解项目）
3. bash verify.sh --json
4. 解析 JSON：
   - 若 fail = 0 且 warn = 0 → 报告"全部健康"
   - 若 warn > 0 → 列出 WARN 项 + 简短解释
   - 若 fail > 0 → 对每项查 docs/07-ai-verification.md §1 对应章节
5. 必要时跑 §1.X 的具体诊断命令
6. 输出结构化报告：
   - 健康度（绿/黄/红）
   - 失败项 + 根因 + 建议修复
   - 用户可执行的下一步
```

---

## 4. AI 在此项目修改东西时的验证

任何修改应该跟一次 verify：

```bash
# 修改 → apply → 等待 → 验证
kubectl apply -f <changed.yaml>
sleep 20  # 等 reconcile
bash verify.sh --json | jq '.checks[] | select(.status != "PASS")'
```

如果出现新的 FAIL/WARN：
- 是否预期？（比如改 secret 后 ArgoCD 暂时 OutOfSync 是正常的）
- 不是预期 → 回滚或继续诊断

---

## 5. 已知限制（不要误报）

verify.sh 当前**不检查**以下项（避免误报）：
- 应用层业务逻辑（应该由应用自己的健康端点检查）
- sealed-secrets 加密功能（仅检查 controller pod 在）
- Webhook 真实触发流程（只检 endpoint 可达，不模拟 Gitee POST）
- TLS 证书有效期（CF 边缘自动续）
- 磁盘空间（应当由系统监控）

需要时由人或 AI 单独跑命令检查。

---

## 6. 给 AI 的提示词模板（用户可直接复制）

```
请进入 ~/infra 目录，读 SKILL.md，然后执行 bash verify.sh --json，
解析结果后给我一份基础设施健康报告。
对所有 FAIL/WARN 项，按 docs/07-ai-verification.md §1 对应章节诊断，
给出根因与修复建议。不要直接修改任何文件，只输出报告。
```

---

附：本文件与 SKILL.md 的关系

- `SKILL.md`：AI 入门读物（项目身份、架构、约束、惯例）
- `docs/07-ai-verification.md`（本文）：验证操作手册（命令 + 判定 + 诊断）
- `verify.sh`：自动化执行入口

AI 第一次进入此项目时建议**两份都读**，之后 verify.sh 就够用了。
