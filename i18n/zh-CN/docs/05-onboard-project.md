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

参考 `~/infra/k8s/examples/demo-app/` 模板，在 manifest 仓库新建：

```
apps/<app>/
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

**deployment.yaml** 关键点：
```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.<root>/<app>:latest   # ← Tekton 会自动改 tag
          env:
            - name: DATABASE_URL
              value: "postgres://...@postgres.infra-bridges.svc.cluster.local:5432/..."
            # 连接串从 INFRA.md 复制
```

**ingress.yaml** 用 `<app>.apps.<root>` 域名（已被 cloudflared 通配符路由覆盖，无需改 CF 配置）。

**密钥(连接串、token 等)**:用 SealedSecret 加密后入库,见
[08-seal-secret.md](./08-seal-secret.md)。流程标准化为
`scripts/seal-secret.sh -i secret.yaml -o sealed-secret.yaml`。

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

ArgoCD 大约 30 秒内会检测到变更，自动创建 Application 与 Deployment。

### 5. Gitee 应用仓库 — 配 Webhook

仓库 → 管理 → WebHooks → 添加：
- URL：`https://hooks.<root>`
- 密码：`${GITEE_WEBHOOK_SECRET}`（INFRA.md §7）
- 触发事件：仅勾 **Push**
- 状态：启用

测试一下：再 push 一个 commit 到应用仓库 → 几秒后 Tekton 应当自动起 PipelineRun：

```bash
kubectl get pipelinerun -n tekton-pipelines
```

### 6. 观察上线

ArgoCD UI（`https://argocd.<root>`）：找到 `<app>` Application，应当显示 Synced + Healthy。

应用访问：`https://<app>.apps.<root>`

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
- 但 EventListener 当前的 CEL filter 只接 Gitee（`X-Git-Oschina-Event`）
- 需要在 `k8s/05-tekton/eventlistener.yaml` 加新的 trigger（不同 interceptor + binding）
- 见 `k8s/05-tekton/triggerbinding-gitee.yaml` 仿写一份 GitLab/GitHub 版本

本期模板只覆盖 Gitee，其他平台后续按需扩展。
