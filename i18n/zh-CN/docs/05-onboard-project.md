# 05 — 接入新项目（onboard）

把一个新仓库纳入 CICD 体系，全程 ~ 5 分钟。

> **想先试通流水线再接自己的项目?** 直接用 `examples/hello-world/<lang>/`
> 里的现成 Hello-World 当应用仓库(支持 React / Vue / C# / Python / Java
> / Go),~2 分钟跑通端到端,所有 manifest 和 Dockerfile 都已就绪。
> 见 `../../../examples/hello-world/README.md`。

## 前提

- 基础设施 bootstrap 已完成
- manifest 仓库 `${MANIFEST_REPO_URL}` 已存在并初始化（至少有 `apps/` 与 `argocd-apps/` 两个目录）
- INFRA.md 在手边

## 步骤

### 1. 应用代码仓库

在 Gitee 建仓库 `<your-user>/<app>`，push 代码，确保根目录有 `Dockerfile`。

### 2. manifest 仓库 — 加 `apps/<app>/`

> **更快路径:** `bash scripts/outpost new-app <name> --lang <go|python|java|csharp|react|vue>`
> 会从对应的 hello-world 模板 scaffold 出 `my-apps/<name>/`,所有重命名都做好。
> 改完后把 `manifest/` 目录拷进你的 manifest 仓库即可。
> 完整子命令清单看 `outpost help`。

参考 `examples/demo-app/` 模板,在 manifest 仓库新建:

```
apps/<app>/
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

**deployment.yaml** 关键点:
```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.<root>/<app>:latest   # ← Tekton 每次 push 自动改 tag
          # 密钥从 SealedSecret 注入(见步骤 2b)。**绝对不要**把明文连接串
          # 直接写到这里入 git。
          envFrom:
            - secretRef:
                name: <app>-secrets
          # 非 secret 配置可以 inline:
          env:
            - name: LOG_LEVEL
              value: "info"
          # apps namespace 自带 LimitRange(单容器默认 1cpu/512Mi,
          # 上限 4cpu/8Gi)。需要不同就显式声明。
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 1,    memory: 512Mi }
```

**ingress.yaml** 用 `<app>-apps.<root>` 域名 — 被广义 `*.<root>` 通配 CF Tunnel 路由覆盖,加新应用无需改 CF 配置。`-apps` 后缀让 FQDN 保持一级子域,免费 Universal SSL `*.<root>` 直接覆盖(二级 `*.apps.<root>` 要付费 Advanced Certificate Manager)。

**镜像 tag 格式:** Tekton 写 7 字符短 SHA(`registry.<root>/<app>:abc1234`)。
回滚 = `git revert` manifest 仓库的那次 commit;`kubectl rollout undo` 也行。

#### 2b. 密钥 — 永远不要 inline 明文

Outpost 自带 SealedSecret。完整原理与故障恢复见
[08-seal-secret.md](./08-seal-secret.md);标准范例在
[`examples/demo-app/`](../../../examples/demo-app/) — 看其
`README.md`、`secret.example.yaml`、`sealed-secret.example.yaml`。

最短路径:

```bash
# 1. 拿集群公钥
kubeseal --fetch-cert > /tmp/pub.pem

# 2. 明文文件放在 manifest 仓库**外**(seal 完就删)
cp examples/demo-app/secret.example.yaml ~/secrets/<app>.yaml
$EDITOR ~/secrets/<app>.yaml          # <REPLACE_*> 用 INFRA.md 的真实值填

# 3. seal 后输出到 manifest 仓库
kubeseal --cert /tmp/pub.pem -o yaml \
  < ~/secrets/<app>.yaml \
  > <manifest-repo>/apps/<app>/sealed-secret.yaml

# 4. **只**入库 SealedSecret。明文绝对不要 commit。
rm ~/secrets/<app>.yaml
```

**跨 reset 持久性:** Outpost 自动把 master RSA 密钥对备份到
`secrets-backup/sealed-secrets-master.key.yaml`,下次 `bootstrap.sh`
会 restore。普通 `reset.sh` 保留备份;`reset.sh --hard` 才彻底删除
(强制重新 seal 所有 SealedSecret)。详见
[08-seal-secret.md "控制器灾难恢复"](./08-seal-secret.md#控制器灾难恢复)。

### 3. manifest 仓库 — 加 `argocd-apps/<app>.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: <你的 manifest 仓库 URL>
    targetRevision: main
    path: apps/<app>
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 4. push manifest 仓库

```bash
git add apps/<app>/ argocd-apps/<app>.yaml
git commit -m "feat: onboard <app>"
git push
```

> **首次接入新 manifest 仓库时**(每个集群只配一次,后续接入的 app 不用重配):
> 在 manifest 仓库 → 管理 → WebHooks → 添加:
> - URL:`https://argocd.<root>/api/webhook`
> - Secret:`${ARGOCD_WEBHOOK_SECRET}`(INFRA.md §6)
> - 触发事件:仅 Push
> - Content-Type:`application/json`
>
> 这个 webhook 让 ArgoCD 立即 sync(~5s),而不是默认的 3 分钟轮询。
> 用 `bash scripts/outpost setup-argocd-webhook` 可重新打印 URL 和 secret。

配上 webhook 后 ArgoCD 在 ~5s 内 sync 完;未配 webhook 时 ArgoCD 仍会在 ~30s 到 3 min 之间轮询发现变更并 sync。

### 5. Gitee 应用仓库 — 配 Webhook

仓库 → 管理 → WebHooks → 添加:
- URL:`https://hooks.<root>`
- 密码:`${GIT_WEBHOOK_SECRET}`(INFRA.md §7)
- 触发事件:仅勾 **Push**
- 状态:启用

> ⚠️ **Webhook secret 注意:** 这个密钥 *跨 Outpost 上所有项目共享*。
> 一旦泄露,要轮换(改 `.env`,重跑 `bash bootstrap.sh`)
> 并更新**每个**接入仓库的 webhook 配置 — v0.2 没有 per-repo 隔离。
> (v0.3 计划加 per-repo CEL 白名单作为最便宜的缓解。)

测试:再 push 一个 commit 到应用仓库 → 几秒后 Tekton 应当自动起 PipelineRun:

```bash
kubectl get pipelinerun -n tekton-pipelines
```

走 dashboard 看的话:

- `https://tekton.<root>` — Tekton Dashboard
  (BasicAuth:用户 `OUTPOST_DASHBOARD_USER`,密码
   `OUTPOST_DASHBOARD_PASSWORD`,均见 INFRA.md §0)

### 6. 观察上线

ArgoCD UI(`https://argocd.<root>`):找到 `<app>` Application,应当显示 Synced + Healthy。

应用访问:`https://<app>-apps.<root>`

### 7. (可选)接入测试网关 + 自动回滚

在应用仓库根目录放一份 `outpost.test.yaml`,Tekton 会在更新 manifest
**之前**先跑一遍测试。把 `Deployment` 转成
`argoproj.io/v1alpha1/Rollout` 后,健康分析失败会**自动回滚**。任何
失败都 fan-out 到所有启用的通知通道(钉钉 / 飞书 / 企微 / 通用 webhook)。

操作步骤见
[`00-quickstart.md` Phase J](./00-quickstart.md#phase-j--测试网关自动回滚多通道告警可选推荐)。
完整设计见
[`proposals/cicd-test-gate.md`](./proposals/cicd-test-gate.md)。

### 8. (可选)按应用的 build 配置 — `outpost.build.yaml`

默认情况下 Tekton 构建 `./Dockerfile`、context 为 `./`，再叠加
registry-plugin 自动加的 kaniko 参数（cache flags + self-hosted 的
`--insecure`）。在应用仓库根目录放一份 `outpost.build.yaml`，可以覆盖：

```yaml
dockerfile: ./services/api/Dockerfile     # monorepo / 子目录构建
context: ./services/api
buildArgs:                                # 每条被转成 --build-arg=KEY=VAL
  - MAVEN_MIRROR=https://nexus.example.com/repository/maven-public
  - JAVA_VERSION=21
extraArgs:                                # 原样追加给 kaniko
  - --single-snapshot
  - --use-new-run
```

所有键都可选。文件不存在时完全等同 v0.2 默认行为（零回归）。示例：
[`../../../examples/hello-world/go/outpost.build.yaml`](../../../examples/hello-world/go/outpost.build.yaml)。

## 常见问题

### Pipeline 跑挂了
```bash
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run> --all-containers --tail=200
```

### Image build 成功但 ArgoCD 没同步
- 检查 `update-manifest-task` 是否成功 push 回 manifest 仓库
- 检查 manifest 仓库 commit 历史，看是否有新的 "chore(...): bump image" commit
- ArgoCD UI 手动点 Refresh / Sync

### Webhook 没触发
- Gitee 仓库 → 管理 → WebHooks → 看最近一次推送的响应
- 200 OK + 我们 EventListener 有 log 才算通
- 401 → `X-Gitee-Token` 不匹配，检查 Secret
- 网络不通 → CF Tunnel 路由错或 Compose cloudflared 没起

### 应用 pod CrashLoopBackOff
- 多半是连接串拼错，pod 内打不到 `*.infra-bridges`
- `kubectl describe pod -n apps <pod>` 看 Events
- `kubectl exec -it -n apps <pod> -- nslookup postgres.infra-bridges.svc.cluster.local` 验证 DNS

## 跨 git 平台（GitLab / GitHub）

如果某个项目代码在 GitLab 或 GitHub：
- Webhook 配置方式相同，URL 都是 `https://hooks.<root>`
- v0.3+：在 `.env` 改 `GIT_PROVIDER_PLUGIN=github` 或 `gitlab`，重跑 `bash bootstrap.sh` 即可。bootstrap 会用对应 plugin 的 sibling `trigger.yaml` 重新装配 EventListener（GitHub 走 Tekton 内置 HMAC interceptor，GitLab 走明文 `X-Gitlab-Token`）。
- 要新增第四种 provider：在 `plugins/git-provider/<name>/` 下放 `trigger.yaml`（描述 Trigger spec）、`manifest.yaml`（描述 TriggerBinding）、`plugin.yaml`、`preflight.sh`、`README.md`，参考 gitee/github/gitlab。
