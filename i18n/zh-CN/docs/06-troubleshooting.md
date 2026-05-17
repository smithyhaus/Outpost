# 06 — 故障排查

## 通用诊断

```bash
~/infra/status.sh
```

## Compose 层

### 容器起不来
```bash
cd ~/infra/compose
docker compose ps
docker compose logs <service> --tail 100
```

### cloudflared 没连通
```bash
docker logs cloudflared --tail 100
```
看到 `Registered tunnel connection` 就 OK；常见错误：
- `failed to fetch token` → `CF_TUNNEL_TOKEN` 错或过期
- `connection refused` → CF Dashboard 里 Public Hostname 配错（service URL 错或端口错）

### 数据服务挂掉
```bash
# 看健康
docker inspect --format='{{.State.Health.Status}}' postgres
# 看错误日志
docker logs postgres --tail 200
```

## k3s / K8s

### k3s 起不来
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200
```
WSL2 常见问题：
- `cgroup v2 not supported` → 启用 systemd（docs/02）
- `iptables: command not found` → `sudo apt install iptables`
- `failed to bind ":6443"` → 端口冲突

### Traefik 没在 30080 监听
```bash
# 看 helm chart config 是否生效
kubectl get helmchartconfig -n kube-system
kubectl describe svc -n kube-system traefik
```
确认 `Type: NodePort`，nodePort 30080。

### pod 卡在 Pending
```bash
kubectl describe pod -n <ns> <pod>
```
常见：
- `0/1 nodes are available: 1 Insufficient memory` → WSL 给的内存不够
- `pod has unbound immediate PersistentVolumeClaims` → local-path-provisioner 没起

### pod 连不上 host.docker.internal
mirrored networking 模式下 pod 内可直连。如果不行：
```bash
kubectl run -it --rm test --image=alpine --restart=Never -- sh -c \
  "apk add curl && curl -v http://host.docker.internal:5432"
```
失败的话改成用 WSL host IP（`ip route show default`）。

## ArgoCD

### UI 打不开 / 502
```bash
kubectl logs -n argocd deploy/argocd-server --tail 100
kubectl get ingressroute -n argocd
```
常见：
- 没关 self-signed TLS（cmd-params-cm 的 `server.insecure` 没生效）→ `kubectl rollout restart deploy/argocd-server -n argocd`
- IngressRoute Host 拼错

### Application 显示 OutOfSync
- UI 点 SYNC
- 看 `Status` 详情，多半是 manifest 仓库里某个字段不合法
- `kubectl get app -n argocd <app> -o yaml` 看 conditions

### 拉 Git 仓库失败（任意 provider）
- 检查 `git-manifest-repo` secret 里的 token 是否还有效
- token 过期重新生成后：`kubectl edit secret -n argocd git-manifest-repo`

## Tekton

### Webhook 收到但 PipelineRun 没起
```bash
kubectl logs -n tekton-pipelines deploy/el-build-listener --tail 200
```
常见：
- CEL filter 失败 → `X-Gitee-Token` 不匹配
- TriggerBinding 字段路径错（Gitee payload 字段名变了）

### PipelineRun 卡在 git-clone
- workspace PVC 没绑上 → 看 `kubectl describe pvc -n tekton-pipelines`
- git-credentials 没配对 → 测试：
  ```bash
  kubectl exec -it <git-clone-pod> -- git clone <repo>
  ```

### Kaniko build 失败
- Dockerfile 不存在 → 应用仓库根目录确实没有
- registry push 401 → `registry-credentials` 跟 active registry plugin 不匹配
  (self-hosted 匿名;aliyun-acr 需要真实账密)。验证:
  `kubectl -n tekton-pipelines get secret registry-credentials -o jsonpath='{.data.config\.json}' | base64 -d`
- registry 不可达 → `kubectl exec -it <pod> -- wget -O- http://registry.<root>` 测试

### `admission webhook denied: tasks + finally > pipeline`
你给 Pipeline 加了 task(或调大了某个 task 的 timeout),累加之和
超过 `triggertemplate.yaml` 里 `timeouts.tasks` / `timeouts.finally`
的预算。Tekton 在创建 PipelineRun 时硬性校验
`tasks + finally <= pipeline`。
修法:改 `core/k8s/05-tekton/triggertemplate.yaml` 里对应字段并 re-apply。

### Dashboard 返回 401
Tekton Dashboard + Argo Rollouts UI 共用一份 Traefik BasicAuth
中间件。用户 = `OUTPOST_DASHBOARD_USER`(默认 `outpost`),密码 =
`OUTPOST_DASHBOARD_PASSWORD` — 都在 `INFRA.md` §0 和 `.env` 里。
查看集群当前生效的 htpasswd:
`kubectl -n tekton-pipelines get secret dashboard-auth-secret -o jsonpath='{.data.users}' | base64 -d`

## Phase J — 测试网关 / 自动回滚 / 多通道告警

(只在你按 [`00-quickstart.md` Phase J](./00-quickstart.md) 启用了之后才相关。)

### `run-tests` task 总是 skipped
仓库根目录既没 `outpost.test.yaml` 也没 `Dockerfile.test`。这是
"该仓库没启用测试网关"的干净路径。要启用,加任一文件即可。

### `run-tests` task 报 `bash: command not found` / 类似
Task 跑在 alpine:3.20 step 里。`outpost.test.yaml` 的
`runner.command` 必须自己 apk-install 需要的 runtime,例如
`["sh","-c","apk add --no-cache go && go test ./..."]`。
Phase 2 会切到 Testkube TestWorkflow + content.git;现在重 runtime 安装是应用作者负担。

### Rollouts 每次金丝雀都被中止
`AnalysisTemplate` 阈值故意收紧
(`failureLimit: 2`、`consecutiveErrorLimit: 3`)。检查:
```bash
kubectl get analysisrun -n apps
kubectl describe analysisrun -n apps <name>
```
如果服务健康但探针返回的 shape 不对,把
`plugins/rollout/argo-rollouts/analysistemplate-default.yaml`
里的 `successCondition` 放宽。

### 通知不触发
- `.env` 里 `NOTIFICATION_PROVIDERS` 空 → 加上启用的通道,重跑 bootstrap。
- `kubectl logs -n tekton-pipelines <pipelinerun-pod> -c step-fanout`
  看每家 provider 的 POST 结果。`[WARN] <p> delivery failed` 表示
  对方返回 non-2xx,重点检查 webhook URL。
- 钉钉 / 飞书加签 webhook:本机时钟漂移会让 HMAC 签名失败,确保 NTP 同步。

## 网络 / Cloudflare

### 域名解析不到
```bash
dig argocd.<root>
```
返回应当是 Cloudflare 的 IP；如果是 NXDOMAIN 说明 NS 没切到 Cloudflare 或者 Public Hostname 没配。

### 域名 OK 但 Cloudflare 报 502
- cloudflared 没起 → `docker logs cloudflared`
- service URL 写错 → CF Dashboard 改

### Webhook 返回 522 / 524
- WSL 没起 / docker 没起
- 任务计划自启失败 → 看 `/tmp/infra-autostart.log`

## 全部重来

```bash
./reset.sh         # 输入确认串。**默认保留** secrets-backup/
./bootstrap.sh     # 自动从 secrets-backup/ 恢复 sealed-secrets master key
```

如果怀疑 sealed-secrets master key 已经泄露,或想要彻底干净的起点
(强制重新 seal 所有现有 SealedSecret):

```bash
./reset.sh --hard  # 也清掉 secrets-backup/
                   # 之后每个 manifest 仓库的 SealedSecret 都得重新 seal
./bootstrap.sh
```
