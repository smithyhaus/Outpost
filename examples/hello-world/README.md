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

`scripts/update-manifest.sh` (run by the GitHub Actions workflow's final
step, on the host runner) auto-detects how to bump the image tag:

| Mode | Trigger | What gets rewritten on each push |
|------|---------|----------------------------------|
| **kustomize** *(preferred)* | `apps/<app>/kustomization.yaml` exists with an `images:` section | matching `.images[].newTag` (and `.newName`) — appends if no match |
| **legacy** | only `apps/<app>/deployment.yaml` exists | `.spec.template.spec.containers[0].image` |

Five of the examples (`react`, `vue`, `csharp`, `python`, `java`) ship the
**legacy** layout (`manifest/deployment.yaml` + `service.yaml` + `ingress.yaml`).
The **`go`** example additionally ships `manifest/kustomization.yaml` to
demonstrate the kustomize path; copy that whole `manifest/` directory into
your manifest repo as `apps/hello-go/` and `update-manifest.sh` will pick
the kustomize mode automatically.

## Common contract

Every example, identical from the platform's perspective:

- Listens on `0.0.0.0:8080`
- `GET /`        → `200`, plain text body `Hello from <Lang>!`
- `GET /healthz` → `200`, plain text body `ok`
- Container `EXPOSE 8080`
- Multi-stage Dockerfile so `scripts/ci/build-image.sh` (buildctl) builds
  cleanly with no Docker-in-Docker tricks
- **`outpost.test.yaml`** at the repo root — declares the test command
  `scripts/ci/run-tests.sh` runs at Gate A (between build and manifest
  update). The MVP shipped command is a placeholder echo; the `tests/`
  directory holds the *real* unit tests. Repos without
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

> Prereqs: full-mode bootstrap is done (`bash verify.sh` is all PASS —
> including the `ci.runner.*` checks), manifest repo has an empty `apps/`
> dir, `GITHUB_RUNNER_URL`/`GITHUB_RUNNER_PAT` are set and the runner is
> registered. See `i18n/<lang>/docs/00-quickstart.md` Phases A–F.

Example for `go` — substitute any other language directory the same way.

### 1. Push the example as your application repo

```bash
cd examples/hello-world/go

# Create an empty private repo on Gitee (primary) — and a github copy for
# the CI trigger surface, e.g. hello-go on both.
git init
git checkout -b main
git add .
git commit -m "init: hello-go smoke test"
git remote add origin https://gitee.com/<you>/hello-go.git
git remote set-url --add --push origin https://gitee.com/<you>/hello-go.git
git remote set-url --add --push origin https://github.com/<you>/hello-go.git
git push -u origin main   # pushes to both remotes
```

### 2. Register it with Outpost and copy the CI workflow

```bash
cd ~/outpost   # this repo
outpost onboard https://gitee.com/<you>/hello-go.git
```

This appends the repo to `OUTPOST_REPOS` (the reconciliation basis
`verify.sh` watches) and offers to copy
`templates/github/outpost-build.yml` into `hello-go`'s
`.github/workflows/` — accept it, then commit + push that file from the
`hello-go` repo.

### 3. Drop the manifests into your manifest repo

```bash
cd <your-manifest-repo>
mkdir -p apps/hello-go
cp <outpost>/examples/hello-world/go/manifest/*.yaml apps/hello-go/
```

Then edit the files to fill in your real values:

- `apps/hello-go/deployment.yaml` — change `registry.example.com` to `registry.<your-root-domain>`
- `apps/hello-go/ingress.yaml`    — change `hello-go-apps.example.com` to `hello-go-apps.<your-root-domain>`

```bash
git add apps/hello-go
git commit -m "feat: onboard hello-go"
git push
```

The `manifest-sync` CronJob applies this within `MANIFEST_SYNC_INTERVAL`
minutes. The Deployment will initially fail to pull the image (the
registry has nothing yet) — fine, that resolves itself in the next step.

### 4. Push a commit; watch the magic

```bash
cd <hello-go-app-repo>
echo "" >> README.md   # or any change
git commit -am "trigger: pipeline smoke test"
git push   # dual-push fires both remotes; github dispatches the workflow
```

Watch it build:

```bash
# GitHub Actions UI on the hello-go repo, or:
journalctl -u 'actions.runner.*' -f
```

When that completes, the manifest repo gets a new commit
(`chore(hello-go): bump image to <sha>`); `manifest-sync` picks it up
within `MANIFEST_SYNC_INTERVAL` minutes and rolls the Deployment.

```bash
outpost logs sync
```

### 5. Verify

```bash
curl https://hello-go-apps.<your-root-domain>
# → Hello from Go!

curl https://hello-go-apps.<your-root-domain>/healthz
# → ok
```

If those two `curl`s succeed, **the whole pipeline works** —
git → GitHub Actions runner → registry → manifest-sync → ingress → app.

## Troubleshooting

| Symptom | Most likely cause |
|---------|------------------|
| Workflow never starts | Repo missing `.github/workflows/outpost-build.yml`, or dual-push/mirror to github isn't actually landing commits there |
| Runner never picks it up | `systemctl status 'actions.runner.*'` — not registered or not running; check `GITHUB_RUNNER_PAT` scope |
| `build-image.sh` fails | Look at the workflow step log — buildkitd NodePort (127.0.0.1:30750) unreachable, or Dockerfile path wrong |
| `update-manifest.sh` fails | manifest repo missing `apps/hello-<lang>/deployment.yaml`, or `GIT_TOKEN` can't push |
| `manifest-sync` not converging | `outpost logs sync`; check `sync-heartbeat` age with `outpost status` |
| Reconciliation FAIL for this repo | `bash verify.sh --json` — is it in `OUTPOST_REPOS`? Did the mirror/dual-push actually land on github? |
| 502 from `https://hello-<lang>-apps.<root>` | Pod not ready yet, or readinessProbe path mismatch |

Detailed diagnosis: `i18n/<lang>/docs/06-troubleshooting.md`.
