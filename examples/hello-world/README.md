# Hello-world smoke tests

Six minimal applications in popular languages, each engineered to be
the **smallest thing that proves your CI/CD pipeline works**:

| Language | Stack                               | Final image base       |
|----------|-------------------------------------|------------------------|
| React    | Vite 5 + React 18, served by nginx  | `nginx:1.27-alpine`    |
| Vue      | Vite 5 + Vue 3, served by nginx     | `nginx:1.27-alpine`    |
| C#       | ASP.NET Core 8 minimal API          | `aspnet:8.0-alpine`    |
| Python   | FastAPI + uvicorn                   | `python:3.12-slim`     |
| Java     | Spring Boot 3.3 + Spring Web        | `eclipse-temurin:21-jre-alpine` |
| Go       | `net/http` (no external deps)       | `scratch`              |

## Manifest layout — two supported modes

The `update-manifest` Tekton task auto-detects how to bump the image tag:

| Mode | Trigger | What gets rewritten on each push |
|------|---------|----------------------------------|
| **kustomize** *(preferred)* | `apps/<app>/kustomization.yaml` exists with an `images:` section | matching `.images[].newTag` (and `.newName`) — appends if no match |
| **legacy** | only `apps/<app>/deployment.yaml` exists | `.spec.template.spec.containers[0].image` |

Five of the examples (`react`, `vue`, `csharp`, `python`, `java`) ship the
**legacy** layout (`manifest/deployment.yaml` + `service.yaml` + `ingress.yaml`).
The **`go`** example additionally ships `manifest/kustomization.yaml` to
demonstrate the kustomize path; copy that whole `manifest/` directory into
your manifest repo as `apps/hello-go/` and the Tekton task will pick the
kustomize mode automatically.

## Common contract

Every example, identical from the platform's perspective:

- Listens on `0.0.0.0:8080`
- `GET /`        → `200`, plain text body `Hello from <Lang>!`
- `GET /healthz` → `200`, plain text body `ok`
- Container `EXPOSE 8080`
- Multi-stage Dockerfile so kaniko builds cleanly with no
  Docker-in-Docker tricks
- **`outpost.test.yaml`** at the repo root — declares the test command
  Tekton runs at Gate A (between build and manifest update). The MVP
  shipped command is a placeholder echo; the `tests/` directory holds
  the *real* unit tests that Phase 2 will wire in. Repos without
  `outpost.test.yaml` skip Gate A cleanly, so this is purely opt-in.

## Phase J — auto-rollback demo (go only, for now)

`examples/hello-world/go/manifest/` ships **two** alternative shapes:

| File              | What it does                                                           |
|-------------------|------------------------------------------------------------------------|
| `deployment.yaml` | Plain `Deployment` — simple rolling update (default for all 6 langs)   |
| `rollout.yaml`    | `argoproj.io/v1alpha1/Rollout` with canary 25→50→75→100 + analysis     |

Pick one when you copy `manifest/` into your manifest repo. The
`Rollout` variant is the only working demo of Phase J's auto-rollback
behaviour today — break the `/healthz` endpoint, push, and watch the
canary analysis abort the rollout automatically. See
[`i18n/en/docs/00-quickstart.md`](../../i18n/en/docs/00-quickstart.md) Phase J.

## Smoke-test walkthrough

> Prereqs: full-mode bootstrap is done (`bash verify.sh` is all PASS),
> manifest repo has empty `apps/` and `argocd-apps/` dirs, webhook
> hostname `hooks.<root>` is reachable. See `i18n/<lang>/docs/00-quickstart.md`
> Phases A–F.

Example for `go` — substitute any other language directory the same way.

### 1. Push the example as your application repo

```bash
cd examples/hello-world/go

# Create an empty private repo on Gitee/GitHub/GitLab named e.g. hello-go
git init
git checkout -b main
git add .
git commit -m "init: hello-go smoke test"
git remote add origin https://gitee.com/<you>/hello-go.git
git push -u origin main
```

### 2. Drop the manifests into your manifest repo

```bash
cd <your-manifest-repo>
mkdir -p apps/hello-go argocd-apps
cp <outpost>/examples/hello-world/go/manifest/*.yaml apps/hello-go/
cp <outpost>/examples/hello-world/go/argocd-application.yaml argocd-apps/hello-go.yaml
```

Then edit the four files to fill in your real values:

- `apps/hello-go/deployment.yaml` — change `registry.example.com` to `registry.<your-root-domain>`
- `apps/hello-go/ingress.yaml`    — change `hello-go.apps.example.com` to `hello-go.apps.<your-root-domain>`
- `argocd-apps/hello-go.yaml`     — change `repoURL` to your manifest repo URL

```bash
git add apps/hello-go argocd-apps/hello-go.yaml
git commit -m "feat: onboard hello-go"
git push
```

ArgoCD picks up the new Application within ~30s. The Deployment will
initially fail to pull the image (the registry has nothing yet) — fine,
that resolves itself in the next step.

### 3. Configure the webhook on the application repo

In Gitee / GitHub / GitLab, on the `hello-go` repo:

- URL: `https://hooks.<your-root-domain>`
- Secret: `GIT_WEBHOOK_SECRET` from `INFRA.md`
- Trigger: Push event only

### 4. Push a commit; watch the magic

```bash
cd <hello-go-app-repo>
echo "" >> README.md   # or any change
git commit -am "trigger: pipeline smoke test"
git push
```

Within ~30s:

```bash
kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp | tail -3
# Watch SUCCEEDED transition Unknown → True
```

When that completes, the manifest repo gets a new commit
(`chore(hello-go): bump image to <sha>`); ArgoCD picks it up within
~30s and rolls the Deployment.

### 5. Verify

```bash
curl https://hello-go.apps.<your-root-domain>
# → Hello from Go!

curl https://hello-go.apps.<your-root-domain>/healthz
# → ok
```

If those two `curl`s succeed, **the whole pipeline works** —
git → Tekton → registry → ArgoCD → ingress → app.

## Troubleshooting

| Symptom | Most likely cause |
|---------|------------------|
| Pipeline never starts | Webhook misconfigured; check Gitee/GitHub/GitLab "Recent deliveries" |
| `git-clone` task fails | `git-credentials` Secret has wrong PAT; `kubectl get secret -n tekton-pipelines git-credentials` |
| `build-and-push` fails | Look at the Dockerfile path / kaniko logs (`kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run> -c step-build-and-push`) |
| `update-manifest` fails | manifest repo missing `apps/hello-<lang>/deployment.yaml`, or the PAT can't push |
| ArgoCD stuck OutOfSync | `kubectl get app -n argocd hello-<lang> -o yaml` and read `.status.conditions` |
| 502 from `https://hello-<lang>.apps.<root>` | Pod not ready yet, or readinessProbe path mismatch |

Detailed diagnosis: `i18n/<lang>/docs/06-troubleshooting.md`.
