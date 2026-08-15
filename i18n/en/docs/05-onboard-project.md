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

# 2. Push the application source to gitee (primary) AND github (CI trigger).

# 3. Register the repo with Outpost. This appends it to OUTPOST_REPOS and
#    prints the CI hookup steps — there is NO webhook to register.
bash scripts/outpost onboard <clone-url>

# 4. Copy the CI workflow into the app repo (step 3 prints the exact path).
cp templates/github/outpost-build.yml \
   <app-repo>/.github/workflows/outpost-build.yml

# 5. Scaffold deployment/service/ingress/kustomization into a local clone
#    of your manifest repo.
bash scripts/outpost manifest scaffold <app> --lang <lang> \
  --manifests-dir <path-to-manifest-repo-clone>

# 6. Create the app's Postgres database (skip if the app has no DB).
bash scripts/outpost db create <app>

# 7. Seal the secrets the manifest references.
bash scripts/outpost seal <app> KEY=value ...

# 8. Commit + push the manifest repo — manifest-sync takes over from here.
bash scripts/outpost verify --app <app>   # confirm pods/image after the next sync tick
```

> ℹ️ **`OUTPOST_REPOS` is the registry that matters now.** It replaced
> `WEBHOOK_REPO_WHITELIST`, but it is not a gate — it's the **positive
> registry that `verify.sh` reconciliation walks**. A repo missing from it
> still builds and deploys fine; what you lose is the anti-silence layer,
> because nothing is comparing that repo's live HEAD against its deployed
> image tag. `outpost onboard` appends it for you; `outpost off-board`
> removes it.

## Prerequisites

- `bash bootstrap.sh` has completed successfully
- The manifest repo (`MANIFEST_REPO_URL`) exists and contains at least an
  empty `apps/` directory
- A GitHub Actions self-hosted runner is registered and online
  (`systemctl status 'actions.runner.*'`)
- `INFRA.md` is at hand for connection strings

## Steps

### 1. Application repository

Create a repo for the application and push the code. The root must
contain a `Dockerfile`.

Two remotes, two different jobs:

| Remote | Role | Must stay in sync? |
|--------|------|--------------------|
| **gitee** (primary) | where you push, what reconciliation reads, where the manifest repo lives | — |
| **github** (copy) | the *only* reason it exists: GitHub Actions fires the build workflow from it | yes — a dead mirror means builds silently stop |

Keep them in sync with **dual push** (recommended — a failure is visible
in your terminal at push time):

```bash
cd <app-repo>
git remote set-url --add --push origin <gitee-url>
git remote set-url --add --push origin <github-url>
# one `git push` now reaches both forges
```

The alternative is gitee's **one-way** push-mirror (gitee → github,
configured in the gitee repo settings UI). Use the one-way mirror only —
gitee's own docs warn that the bidirectional mirror's 30-minute window can
lose commits. Either way, a dead mirror is caught by `verify.sh`
reconciliation, not by anything inside the workflow.

### 2. Register the repo

```bash
bash scripts/outpost onboard <clone-url>
```

This appends the URL to `OUTPOST_REPOS` in `.env` (idempotent) and prints
the CI hookup steps. If the source carries an `outpost.app.yaml` it is
*also* onboarded as a Compose-tier app (Caddy fragment + compose
override). Useful flags: `--dry-run`, `--manifests-dir <path> --lang <lang>`
to scaffold k8s manifests in the same pass, `--install-skill` to drop the
LLM onboarding skill into the app's `.claude/skills/`.

### 3. Application repo — the CI workflow

```bash
mkdir -p <app-repo>/.github/workflows
cp templates/github/outpost-build.yml \
   <app-repo>/.github/workflows/outpost-build.yml
# edit the `branches: [main]` line if your deploy branch differs
git -C <app-repo> add .github/workflows/outpost-build.yml
git -C <app-repo> commit -m "ci: outpost build workflow"
```

That ~40-line file is the *entire* per-repo CI surface. All real logic
lives in this repo's hardened scripts on the runner host, resolved through
`$OUTPOST_ROOT` (injected via `~/actions-runner/.env` when bootstrap
installs the runner). Upgrading build logic = `git pull` on the Outpost
host, not editing N app repos. Details: `templates/github/README.md`.

Push to the deploy branch and the runner picks it up. Watch it in the
app repo's **GitHub Actions** tab, or on the host:

```bash
journalctl -u 'actions.runner.*' -n 200
```

### 4. Manifest repo — `apps/<app>/`

> **Faster path:** `bash scripts/outpost manifest scaffold <app> --lang <lang> --manifests-dir <path>`
> generates all of the below from the matching hello-world template with
> the renames done. `outpost new-app <name> --lang <lang>` scaffolds the
> *application* side into `my-apps/<name>/`. See `outpost help`.

Add to your manifest repo:

```
apps/<app>/
├── deployment.yaml
├── service.yaml
├── ingress.yaml
└── kustomization.yaml     ← manifest-sync prefers `apply -k` when present
```

Key points in `deployment.yaml`:

```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.<root>/<app>:latest   # ← CI patches this on every push
          # Secrets come from a SealedSecret — see step 4b. NEVER inline
          # plaintext connection strings here.
          envFrom:
            - secretRef:
                name: <app>-secrets
          # Non-secret config can stay inline:
          env:
            - name: LOG_LEVEL
              value: "info"
          # The apps namespace ships with a LimitRange (default 500m / 512Mi
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

**Image tag format:** CI writes a 7-character short SHA
(`registry.<root>/<app>:abc1234`). That `sha-7` shape is a contract —
`verify.sh` reconciliation compares it against the repo's live branch
head. Rollback = `outpost rollback <app> [sha]`.

> ⚠️ `outpost manifest scaffold` also writes a fifth file,
> `argocd-apps/<app>.yaml`. That is **legacy**: `manifest-sync` reads only
> `apps/`, and a commit that touches nothing under `apps/` is logged as
> "nothing to apply". The file is harmless; you can delete it.

#### 4b. Secrets — never inline plaintext

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

### 5. Push the manifest repo

```bash
git add apps/<app>/
git commit -m "feat: onboard <app>"
git push
```

`manifest-sync` (ns `outpost-ci`) pulls every `MANIFEST_SYNC_INTERVAL`
minutes, diffs `applied_head..HEAD`, and `kubectl apply -k`s each touched
`apps/<dir>` — then waits for the rollout. There is nothing else to
configure: **no webhook on the manifest repo either**, and no sync button
to press. If you're impatient:

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

### 6. Watch the rollout

```bash
outpost status                # sync heartbeat: last_sync_ts / applied_head / last_result
outpost verify --app <app>    # pods + deployed image + recent events
outpost logs <app>            # app logs from the 'apps' namespace
```

Application URL: `https://<app>-apps.<root>`.

### 7. (optional) Wire test gate + auto-rollback

Drop `outpost.test.yaml` at your application repo root to make CI run
tests **before** updating the manifest (Gate A — the manifest never moves
on a red test, so the cluster never sees the broken image). Set
`ROLLOUT_PLUGIN=argo-rollouts` and convert your `Deployment` to an
`argoproj.io/v1alpha1/Rollout` to get canary + automatic rollback;
`manifest-sync` is `Rollout`-kind aware and fails the sync on `Degraded`.
Multi-channel notifications (DingTalk / Feishu / WeCom / generic webhook)
fan out on `build-failed` / `deploy-failed` / `verify-failed`.

Walkthrough:
[`00-quickstart.md` Phase J](./00-quickstart.md#phase-j--test-gate-auto-rollback-notifications-optional-but-recommended).
Design history (Tekton/ArgoCD era — read for the *why*):
[`proposals/cicd-test-gate.md`](./proposals/cicd-test-gate.md).

### 8. (optional) Per-app build config — `outpost.build.yaml`

By default CI builds `./Dockerfile` at context `./` with the
registry-plugin-aware defaults. Drop an `outpost.build.yaml` at your
application repo root to override any of:

```yaml
dockerfile: ./services/api/Dockerfile     # monorepo / subdir builds
context: ./services/api
buildArgs:                                # each becomes --build-arg=KEY=VAL
  - MAVEN_MIRROR=https://nexus.example.com/repository/maven-public
  - JAVA_VERSION=21
extraArgs:                                # kaniko-era passthrough
  - --single-snapshot
```

All keys are optional; an absent file keeps the defaults exactly.

> **v0.3 note on `extraArgs`:** the build engine is now buildkit
> (`buildctl` against the in-cluster daemon), not kaniko.
> `scripts/ci/build-image.sh` accepts only `--build-arg=K=V` entries out
> of `extraArgs` and **silently ignores kaniko-only flags** — that
> filtering is deliberate (an unfiltered passthrough would let one repo's
> config inject a second `buildctl` flag and overwrite another app's image
> tag in the shared registry). `buildArgs` is the supported way to pass
> build arguments.

Live example:
[`../../../examples/hello-world/go/outpost.build.yaml`](../../../examples/hello-world/go/outpost.build.yaml).

## Troubleshooting

### The build never started

The push reached gitee but not github, or the runner is down. In order:

```bash
git ls-remote <github-url> refs/heads/main   # is the mirror current?
systemctl status 'actions.runner.*'          # is the runner alive?
bash verify.sh                               # ci.runner.online / ci.workflow.<app>
```

`verify.sh` reconciliation catches all of these from the outside: a repo
whose live HEAD hasn't become a deployed tag within
`OUTPOST_STALENESS_THRESHOLD` (default 1800s) is a FAIL naming the repo.

### The workflow failed

Open the run in the app repo's GitHub Actions tab (or
`journalctl -u 'actions.runner.*' -n 200`) and read the failing step:

- `Build image` — Dockerfile error, base-image pull timeout, or buildkitd
  not Ready (`kubectl -n buildkit get pods`)
- `Run tests (Gate A)` — your tests failed, or the runner host is missing
  `yq` / `docker`
- `Update manifest` — the manifest repo has no `apps/<app>/`, or
  `GIT_TOKEN` can't push

### Image built but the app didn't update

- Check the manifest repo for a recent commit by the CI bot
  (`chore(<app>): bump image to <sha>`). No commit → the workflow's
  `Update manifest` step never ran or failed
- Commit exists → look at the CD half: `outpost status` (is
  `last_sync_ts` fresh, is `last_result=ok`?) then `outpost logs sync`

### Pod CrashLoopBackOff in apps/
- Usually a wrong connection string (typo in bridge service name)
- `kubectl describe pod -n apps <pod>` for events
- `kubectl exec -it -n apps <pod> -- nslookup postgres.infra-bridges.svc.cluster.local`

### I applied something with kubectl and it disappeared

Expected. The manifest repo is the enforced source of truth for the `apps`
namespace. Nothing reverts your change immediately (there's no self-heal
loop any more), but it silently diverges and gets clobbered the next time
that app's manifest changes. Put it in the manifest repo instead.

## Multiple Git providers

`GIT_PROVIDER_PLUGIN` accepts a comma-separated list (e.g.
`GIT_PROVIDER_PLUGIN=gitee,github,gitlab` in `.env`). In v0.3 this is a
**credential contract, not a routing one**: each listed provider's
`preflight.sh` runs an authenticated `git ls-remote` against every
`OUTPOST_REPOS` entry whose host it owns, so a revoked token fails at
bootstrap instead of quietly breaking builds later. There is no
EventListener to assemble and no per-provider webhook signature to
configure.

For private app repos on a host *other* than the manifest repo's, add
per-host credentials:

```env
GIT_CREDENTIALS_EXTRA=github.com|ci-bot|ghp_xxxx,gitlab.mycorp.com|ci-bot|glpat-yyyy
```

Re-run `bash bootstrap.sh` after changing either variable.
