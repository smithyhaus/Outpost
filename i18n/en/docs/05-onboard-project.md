# 05 — Onboard a new project

End-to-end takes about 5 minutes per project once the infrastructure is up.

> **Want to verify the pipeline works before onboarding your real
> application?** Use one of the prebuilt Hello-World apps in
> `examples/hello-world/<lang>/` (React / Vue / C# / Python / Java /
> Go). All Dockerfiles and manifests are ready — push, copy, watch the
> pipeline succeed in ~2 minutes. See
> `../../../examples/hello-world/README.md`.

## Quickstart (command reference)

The full walkthrough below covers every detail; this is the command
sequence for a team that already knows the shape of it:

```bash
# 1. New repo? Scaffold one from a hello-world template (skip if you
#    already have an app repo with a root-level Dockerfile).
bash scripts/outpost new-app <name> --lang <go|python|java|csharp|react|vue>

# 2. Push the application source to your git provider.

# 3. Register the Tekton webhook via the provider API (needs an
#    admin-scoped GIT_TOKEN — see step 5 below for the manual fallback).
bash scripts/outpost register-webhooks --tekton-only

# 4. Scaffold deployment/service/ingress/kustomization + argocd-app into
#    a local clone of your manifest repo (or run `outpost onboard` for
#    the one-shot version of steps 4+, see step 2 of the walkthrough).
bash scripts/outpost manifest scaffold <app> --lang <lang> \
  --manifests-dir <path-to-manifest-repo-clone>

# 5. Create the app's Postgres database (skip if the app has no DB).
bash scripts/outpost db create <app>

# 6. Seal the secrets the manifest references.
bash scripts/outpost seal <app> KEY=value ...

# 7. Commit + push the manifest repo — ArgoCD takes over from here.
bash scripts/outpost verify --app <app>   # confirm sync/health after ArgoCD picks it up
```

> ⚠️ **If `WEBHOOK_REPO_WHITELIST` is set in `.env`,** a brand-new repo
> must be added to it **and** `bash bootstrap.sh` re-run before step 3's
> webhook actually delivers builds. Until then, pushes are silently
> dropped by the EventListener's CEL filter even though the provider
> shows the webhook delivery as 200 OK. `outpost onboard` and `outpost
> register-webhooks` both print a warning when they detect this.

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

> **Faster path:** `bash scripts/outpost new-app <name> --lang <go|python|java|csharp|react|vue>`
> scaffolds `my-apps/<name>/` from the matching hello-world template with all
> the renames done. Edit, copy the `manifest/` directory into your manifest
> repo. See `outpost help` for all subcommands.

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
          image: registry.<root>/<app>:latest   # ← Tekton patches this on every push
          # Secrets come from a SealedSecret — see step 2b. NEVER inline
          # plaintext connection strings here.
          envFrom:
            - secretRef:
                name: <app>-secrets
          # Non-secret config can stay inline:
          env:
            - name: LOG_LEVEL
              value: "info"
          # The apps namespace ships with a LimitRange (default 1cpu / 512Mi
          # per container, max 4cpu / 8Gi). Declare your own only if you need
          # something different.
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 1,    memory: 512Mi }
```

`ingress.yaml` should use `<app>-apps.<root>` — caught by the broad
`*.<root>` Cloudflare Tunnel wildcard, no per-app CF change needed.
The `-apps` suffix keeps the FQDN at one subdomain level so the free
Universal SSL `*.<root>` certificate covers it (a two-level
`*.apps.<root>` would require paid Advanced Certificate Manager).

**Image tag format:** Tekton writes a 7-character short SHA
(`registry.<root>/<app>:abc1234`). Rollback = revert the manifest repo
commit; `kubectl rollout undo` also works.

#### 2b. Secrets — never inline plaintext

Outpost provides SealedSecret out of the box. Mechanism +
disaster-recovery in [08-seal-secret.md](./08-seal-secret.md); the
canonical example lives at
[`examples/demo-app/`](../../../examples/demo-app/) — see its
`README.md`, `secret.example.yaml`, and `sealed-secret.example.yaml`.

Quick path:

```bash
# 1. Get the cluster's public sealing cert
kubeseal --fetch-cert > /tmp/pub.pem

# 2. Plaintext OUTSIDE the manifest repo (delete after sealing)
cp examples/demo-app/secret.example.yaml ~/secrets/<app>.yaml
$EDITOR ~/secrets/<app>.yaml          # fill <REPLACE_*> from INFRA.md

# 3. Seal — output goes into the manifest repo
kubeseal --cert /tmp/pub.pem -o yaml \
  < ~/secrets/<app>.yaml \
  > <manifest-repo>/apps/<app>/sealed-secret.yaml

# 4. Commit ONLY the SealedSecret. NEVER commit the plaintext.
rm ~/secrets/<app>.yaml
```

**Cross-reset survivability:** Outpost auto-backs up the master RSA
keypair to `secrets-backup/sealed-secrets-master.key.yaml` and restores
it on the next `bootstrap.sh`. A normal `reset.sh` keeps the file;
`reset.sh --hard` wipes it (forces every existing SealedSecret to be
re-sealed). See
[08-seal-secret.md](./08-seal-secret.md#controller-disaster-recovery).

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

> **First time you point Outpost at a manifest repo** (one-time per cluster;
> subsequent apps don't need to revisit this): in the manifest repo, add a
> webhook:
> - URL: `https://argocd.<root>/api/webhook`
> - Secret: `${ARGOCD_WEBHOOK_SECRET}` (INFRA.md §6)
> - Events: Push only
> - Content-Type: `application/json`
>
> This collapses ArgoCD's default 3-min poll interval to ~5s push-triggered
> sync. Re-print the URL + secret any time with
> `bash scripts/outpost setup-argocd-webhook`.

With the webhook configured ArgoCD syncs within ~5s; without it it still
syncs but on its own ~30s–3min poll cadence.

### 5. Application repo — webhook

**Preferred: `bash scripts/outpost register-webhooks`.** It registers
(or updates) the Tekton webhook on every repo in `WEBHOOK_REPO_WHITELIST`
directly via the provider API — no clicking through provider UIs:

```bash
bash scripts/outpost register-webhooks --dry-run --tekton-only   # preview first
bash scripts/outpost register-webhooks --tekton-only             # then apply
```

- **Needs an admin-scoped `GIT_TOKEN`** (repo-admin permission on the
  target host — set in `.env`, or `GIT_CREDENTIALS_EXTRA` for a host
  other than the manifest repo's). Without one it skips the repo with a
  clear message rather than failing silently.
- **Idempotent:** matches an existing hook by its target URL and updates
  it in place (PUT/PATCH) instead of creating a duplicate — safe to
  re-run any time (rotated secret, new repo added, etc).
- **Only touches repos listed in `WEBHOOK_REPO_WHITELIST`** (`.env`,
  comma-separated). If that variable is set and your new repo isn't in
  it yet, add it there first, then **re-run `bash bootstrap.sh`** — the
  EventListener's CEL filter only picks up whitelist changes on
  bootstrap, not on `register-webhooks` alone. Until you do, pushes are
  silently dropped by CEL even though the provider shows the webhook
  delivery as 200 OK. `outpost onboard` and `outpost register-webhooks`
  both print a warning when they detect a repo missing from the
  whitelist.

**Fallback: manual UI** (no admin token available, or you'd rather click
through it). The exact label varies by provider — see
`plugins/git-provider/<provider>/README.md` (`gitee` / `github` /
`gitlab`) for provider-specific field names:

- **URL:** `https://hooks.<root>`
- **Secret:** `${GIT_WEBHOOK_SECRET}` from `INFRA.md` §7
- **Events:** Push only
- **Active:** yes

> ⚠️ **Webhook secret hygiene:** the secret is *shared across all
> projects on this Outpost.* If it leaks, rotate it (regenerate in
> `.env`, re-run `bash bootstrap.sh`) AND update every onboarded repo's
> webhook config — there's no per-repo isolation in v0.2. `WEBHOOK_REPO_WHITELIST`
> (v0.3+) narrows the blast radius to listed repos, but doesn't replace
> per-repo secrets.

Test by pushing a commit. Within seconds:

```bash
kubectl get pipelinerun -n tekton-pipelines
```

Should show a new run. To inspect via the dashboard:

- `https://tekton.<root>` — Tekton Dashboard
  (BasicAuth: `OUTPOST_DASHBOARD_USER` / `OUTPOST_DASHBOARD_PASSWORD`
  in `INFRA.md` §0)

### 6. Watch the rollout

ArgoCD UI (`https://argocd.<root>`): the `<app>` application should go
to **Synced + Healthy**.

Application URL: `https://<app>-apps.<root>`.

### 7. (optional) Wire test gate + auto-rollback

Drop `outpost.test.yaml` at your application repo root to make Tekton
run tests **before** updating the manifest. Convert your `Deployment`
to an `argoproj.io/v1alpha1/Rollout` to get canary + automatic rollback
on health degradation. Multi-channel notifications (DingTalk / Feishu /
WeCom / generic webhook) fan out on every failure.

Walkthrough:
[`00-quickstart.md` Phase J](./00-quickstart.md#phase-j--test-gate-auto-rollback-notifications-optional-but-recommended).
Full design:
[`proposals/cicd-test-gate.md`](./proposals/cicd-test-gate.md).

### 8. (optional) Per-app build config — `outpost.build.yaml`

By default Tekton builds `./Dockerfile` at context `./` with the
registry-plugin-aware kaniko defaults (cache flags + `--insecure` for
self-hosted). Drop an `outpost.build.yaml` at your application repo
root to override any of:

```yaml
dockerfile: ./services/api/Dockerfile     # monorepo / subdir builds
context: ./services/api
buildArgs:                                # each becomes --build-arg=KEY=VAL
  - MAVEN_MIRROR=https://nexus.example.com/repository/maven-public
  - JAVA_VERSION=21
extraArgs:                                # passed through verbatim
  - --single-snapshot
  - --use-new-run
```

All keys are optional. Absent file → v0.2 defaults preserved exactly
(zero-regression). Live example:
[`../../../examples/hello-world/go/outpost.build.yaml`](../../../examples/hello-world/go/outpost.build.yaml).

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
