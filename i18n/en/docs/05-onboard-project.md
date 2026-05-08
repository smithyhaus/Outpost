# 05 — Onboard a new project

End-to-end takes about 5 minutes per project once the infrastructure is up.

> **Want to verify the pipeline works before onboarding your real
> application?** Use one of the prebuilt Hello-World apps in
> `examples/hello-world/<lang>/` (React / Vue / C# / Python / Java /
> Go). All Dockerfiles and manifests are ready — push, copy, watch the
> pipeline succeed in ~2 minutes. See
> `../../../examples/hello-world/README.md`.

## Prerequisites

- `bash bootstrap.sh` has completed successfully
- The manifest repo (`MANIFEST_REPO_URL`) exists and contains at least
  empty `apps/` and `argocd-apps/` directories
- `INFRA.md` is at hand for connection strings

## Steps

### 1. Application repository

In your Git provider, create a repo for the application and push the
code. The root must contain a `Dockerfile`.

### 2. Manifest repo — `apps/<app>/`

Use `examples/demo-app/` as the template. Add to your manifest repo:

```
apps/<app>/
├── deployment.yaml
├── service.yaml
└── ingress.yaml
```

Key points in `deployment.yaml`:

```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.<root>/<app>:latest    # ← Tekton patches this
          env:
            - name: DATABASE_URL
              value: "postgres://...@postgres.infra-bridges.svc.cluster.local:5432/..."
            # connection strings come from INFRA.md
```

`ingress.yaml` should use `<app>.apps.<root>` (already covered by the
wildcard in your Cloudflare Tunnel config — no CF change needed).

### 3. Manifest repo — `argocd-apps/<app>.yaml`

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
    repoURL: <your manifest repo URL>
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

### 4. Push the manifest repo

```bash
git add apps/<app>/ argocd-apps/<app>.yaml
git commit -m "feat: onboard <app>"
git push
```

ArgoCD picks up the change within ~30s and creates the Application +
Deployment.

### 5. Application repo — webhook

In your application repo, configure a webhook (the exact UI label
varies by Git provider):

- **URL:** `https://hooks.<root>`
- **Secret:** `${GIT_WEBHOOK_SECRET}` from `INFRA.md` §7
- **Events:** Push only
- **Active:** yes

Test by pushing a commit. Within seconds:

```bash
kubectl get pipelinerun -n tekton-pipelines
```

Should show a new run.

### 6. Watch the rollout

ArgoCD UI (`https://argocd.<root>`): the `<app>` application should go
to **Synced + Healthy**.

Application URL: `https://<app>.apps.<root>`.

## Troubleshooting

### Pipeline failed
```bash
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run> \
  --all-containers --tail=200
```

### Image build succeeded but ArgoCD didn't sync
- Check the manifest repo for a recent commit by the CI bot
  (`chore(<app>): bump image to <sha>`)
- ArgoCD UI → click **Refresh** on the Application

### Webhook didn't trigger
- Provider's webhook delivery log → look at the most recent attempt
- 200 OK + something in EventListener logs = OK
- 401 → secret mismatch. Check what's in `INFRA.md` vs the provider UI
- 5xx / no response → cloudflared down or k3s Traefik down

### Pod CrashLoopBackOff in apps/
- Usually a wrong connection string (typo in bridge service name)
- `kubectl describe pod -n apps <pod>` for events
- `kubectl exec -it -n apps <pod> -- nslookup postgres.infra-bridges.svc.cluster.local`

## Multiple Git providers

If different repos live on different providers, configure each repo's
webhook with the URL above. The active `GIT_PROVIDER_PLUGIN` decides
which interceptor handles incoming hooks. To support more than one
simultaneously, add a second `GIT_PROVIDER_PLUGIN` to the EventListener
manually (see `plugins/git-provider/<name>/manifest.yaml` for the
trigger fragment shape).
