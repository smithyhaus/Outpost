# 00 — Quick Start (all platforms)

> This is the **only entry-point doc** for Outpost. Read it end-to-end and
> you can stand up the full stack from scratch. Everything else under
> `docs/` is reference material, not a tutorial.
> Covers macOS / Linux native / Windows WSL2.

## Pick a mode first

| Mode | What you get | Required input | When to use |
|------|--------------|----------------|-------------|
| **`local`** *(default)* | Compose data services on `localhost` (PG / Redis / RabbitMQ / Manticore Search) | none | personal dev backend on this box, no public hosting, no CI/CD |
| **`full`** | k3s data layer + Cloudflare Tunnel + GitHub Actions self-hosted runner + `manifest-sync` CD | `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`, `MANIFEST_REPO_URL`, `GITHUB_RUNNER_URL`, `GITHUB_RUNNER_PAT`, `OUTPOST_REPOS` | want a public domain + push-to-deploy CI/CD |

> You can switch modes at any time. Start in `local`; once comfortable,
> set `OUTPOST_MODE=full` in `.env` and re-run `bootstrap.sh`. Existing
> data volumes and generated passwords are reused.

> ℹ️ **Git providers (v0.3.0 changed this).** There is **no inbound
> webhook anywhere** — CI is a GitHub Actions workflow run by a
> self-hosted runner that long-polls github.com *outbound only*. So
> `GIT_PROVIDER_PLUGIN` is no longer a webhook-receiver selector; it's a
> **credential + host-ownership contract**. Each listed provider runs an
> authenticated `git ls-remote` against every `OUTPOST_REPOS` entry it
> owns during bootstrap, so a bad token fails loudly up front instead of
> silently killing builds later. It takes a comma-list, and the dual-
> provider setup is the normal one:
>
> ```env
> GIT_PROVIDER_PLUGIN=gitee,github   # gitee = primary push target + manifest repo
>                                    # github = CI trigger surface only
> ```
>
> See [ADR-0003](../../../docs/decisions/0003-github-actions-engine-swap.md).

---

## Terminology

- **Outpost host** — the machine that runs `bootstrap.sh` (macOS / Linux / WSL2).
  It also hosts the GitHub Actions runner.
- **Dev workstation** — the machine you use to write code and connect with
  DBeaver / Redis Insight / etc. (often the same as the Outpost host, but
  may be a different laptop).
- **Manifest repo** — the deploy source of truth: holds K8s YAML for each
  app under `apps/<app>/`. The `manifest-sync` CronJob pulls it on a timer
  and applies what changed. **Not** the same as your application code repo.
- **App repo** — your application source. Lives on gitee (primary), with a
  github copy that exists only so GitHub Actions can fire the build.

---

## `local` mode — shortest path (~2 min)

Same on every platform. If you don't need a public domain or CI/CD,
steps 1–4 are all you need.

1. **Phase B (system prep)** — see your platform's section below; just
   get Docker installed
2. `git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost`
3. `bash bootstrap.sh` (default mode is `local`; no `.env` edit needed)
4. Read `INFRA.md` for connection strings; `bash verify.sh` to confirm
   health

You can skip the rest of this document.

---

## `full` mode — complete walkthrough

Do A → I in order. If a phase fails, fix it before moving on; do not
skip ahead.

### Phase A — Cloudflare side (browser, ~10 min) — **same on all platforms**

- [ ] **A1** Move your domain's NS to Cloudflare (Free plan is fine), wait for propagation
- [ ] **A2** Zero Trust → Networks → Tunnels → **Create a tunnel** → choose `Cloudflared` → name it (anything, e.g. `outpost`) → Save
- [ ] **A3** On the install page, **copy only the token** (a long `eyJhIjoi…` string). Keep it for Phase D. **Do NOT** run that install command — we run cloudflared inside Compose, not on the host directly
- [ ] **A4** Open the tunnel detail page → **Public Hostname** tab → add **four HTTP rows**, all pointing at `host.docker.internal:30080` (full table in `01-cloudflare-setup.md` §3):
  - `search` / `mq` / `registry` / `*` (broad wildcard — catches apps named `<x>-apps.<root>`)
  - **No `hooks` / `argocd` / `tekton` / `rollouts` rows** — v0.3.0 retired the inbound-webhook path and every in-cluster CI/CD dashboard
  - **Don't use `*.apps`** — that's a two-level wildcard, not covered by free Universal SSL (would cost $10/mo for ACM). Apps follow the `<name>-apps.<root>` naming convention so the single broad `*.<root>` wildcard suffices.
  - **Extra for `registry`**: expand *Additional application settings → HTTP Settings → HTTP Host Header* and set it to `registry.<your-domain>` (Docker Registry is Host-header sensitive; without this, image pulls 401)
- [ ] **A5** The Tunnel status in the Dashboard will show *Inactive / Down* — **expected**, because cloudflared isn't running locally yet. **Do NOT run any connectivity check here.** Real verification happens in Phase F

### Phase B — System prep — **branches by Outpost-host platform**

#### B-mac (macOS) ~5 min

- [ ] **B1** Install Docker Desktop: `brew install --cask docker` → `open -a Docker`. Wait for the menu-bar whale to go green
- [ ] **B2** Install base tools: `brew install git jq gettext yq` (Apple Silicon already ships bash/curl/openssl)
- [ ] **B3** *(optional, restricted networks)* Docker Desktop → Settings → Docker Engine, add a mirror:
  ```json
  { "registry-mirrors": ["https://docker.m.daocloud.io"] }
  ```
- [ ] **B4** Self-test: `docker run --rm hello-world`
- [ ] Skip `.wslconfig` and Windows Task Scheduler (not applicable)
- [ ] ⚠️ macOS has no systemd. The runner still installs (bootstrap uses
      the runner's own `svc.sh`, which registers a launchd job), but the
      `outpost-verify.timer` dead-man switch is **skipped** — `verify.sh`
      will only run when you run it. If you want the automatic check,
      schedule `platform/systemd/outpost-verify-run.sh` from a LaunchAgent.
      `verify.sh` also reports `ci.runner.unit` as WARN on macOS because it
      can't query systemd; check with `~/actions-runner/svc.sh status`

#### B-linux (native Linux) ~5 min

- [ ] **B1** Base tools: `sudo apt update && sudo apt install -y curl git openssl gettext-base ca-certificates jq` (Debian/Ubuntu; use the equivalent for other distros)
- [ ] **B2** Docker: bootstrap can install it for you (via the official `get.docker.com` script), or install it manually beforehand
- [ ] **B3** Add yourself to the docker group: `sudo usermod -aG docker $USER`, then **log out and back in**
- [ ] **B4** Install `yq` (mikefarah v4+) and `buildctl` — the runner needs both on PATH for builds. See `templates/github/README.md` §3 for the full runner-host tool list
- [ ] **B5** Self-test: `docker run --rm hello-world`
- [ ] Skip `.wslconfig` and Windows Task Scheduler (not applicable)

#### B-wsl (Windows + WSL2) ~15 min

> Full details in `02-wsl-config.md` (only WSL2 readers need it)

- [ ] **B1** Confirm Win11 22H2+. PowerShell (admin): `wsl --install -d Ubuntu`
- [ ] **B2** Write `C:\Users\<you>\.wslconfig` (template in `02-wsl-config.md` §1) → PowerShell `wsl --shutdown`
- [ ] **B3** Inside WSL → write `/etc/wsl.conf` to enable systemd (`02-wsl-config.md` §2.1) → PowerShell `wsl --shutdown` again → reopen WSL
- [ ] **B4** Configure Docker mirror (`02-wsl-config.md` §2.2) + `sudo systemctl restart docker`
- [ ] **B5** `sudo apt install -y curl git openssl gettext-base ca-certificates jq` + install `yq` and `buildctl`
- [ ] **B6** Self-test: `docker run --rm hello-world` and `systemctl status` both work

### Phase C — Manifest repo (browser + any machine, ~3 min) — **same on all platforms**

- [ ] **C1** Create an **empty private** repo on Gitee / GitHub / GitLab, e.g. `<user>/manifests`. Gitee is the recommended host — the deploy path stays fully domestic that way
- [ ] **C2** Clone locally → add the `apps/` directory → push:
  ```bash
  git clone <repo HTTPS URL> manifests && cd manifests
  mkdir -p apps
  touch apps/.gitkeep
  git add . && git commit -m "init" && git push
  ```
  `apps/` is the only directory `manifest-sync` reads. (A legacy
  `argocd-apps/` directory is ignored outright — see the note in
  `05-onboard-project.md` §3.)
- [ ] **C3** On the Git provider, generate a **Personal Access Token**:
  - Gitee: tick `projects` (read+write)
  - GitHub: tick `repo` (full)
  - GitLab: tick `api`
  - Save it for Phase D

### Phase C2 — GitHub runner prerequisites (browser, ~5 min) — **same on all platforms**

CI runs on GitHub Actions with a runner on *your* host, so you need a
GitHub-side home for it:

- [ ] **C2-1** Pick a registration target: a GitHub **org** is recommended
      (`https://github.com/<org>` — one runner serves every private repo in
      the org). A single-repo URL works too, but then the runner only
      serves that repo
- [ ] **C2-2** Create a PAT that can mint runner registration tokens:
      `admin:org` scope for an org URL, repo-admin for a repo URL. Outpost
      uses it **only** to exchange for a short-lived registration token —
      it is never persisted into the runner and never echoed to logs
- [ ] **C2-3** For each app repo you'll build: make sure a **github copy
      exists**. Gitee stays the primary push target; github is only the CI
      trigger surface. Set up either dual-push or gitee's *one-way*
      push-mirror (never the bidirectional one — its 30-minute window can
      lose commits). `outpost onboard` prints the exact commands in Phase I

### Phase D — Outpost configuration (Outpost host, ~5 min) — **same on all platforms**

- [ ] **D1** `git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost`
- [ ] **D2** `cp .env.example .env`, edit these fields:
  ```env
  OUTPOST_MODE=full
  ROOT_DOMAIN=<your root domain>
  CF_TUNNEL_TOKEN=<token from A3>
  GIT_USER=<git username>
  GIT_TOKEN=<token from C3>
  MANIFEST_REPO_URL=<repo URL from C1, ending in .git>
  GIT_PROVIDER_PLUGIN=gitee,github        # comma-list; dual-provider is normal

  GITHUB_RUNNER_URL=https://github.com/<org>
  GITHUB_RUNNER_PAT=<PAT from C2-2>
  OUTPOST_REPOS=                          # filled in by `outpost onboard` (Phase I)
  ```
  Leave password fields (`POSTGRES_PASSWORD` etc.) blank — bootstrap auto-generates strong values
- [ ] **D3** *(if your app repos live on a host other than the manifest
      repo's)* set `GIT_CREDENTIALS_EXTRA=github.com|<user>|<token>` so the
      preflight `ls-remote` and reconciliation can authenticate there too

> `GITHUB_RUNNER_PAT` may be left empty — bootstrap then **skips the runner
> install with a loud WARN**, and `verify.sh` reports `ci.runner` as WARN.
> That is a legitimate state only for CI/e2e runs of this repo itself; on a
> real install it means **no build will ever trigger**.

### Phase E — Bootstrap (~5 min) — **same on all platforms**

- [ ] **E1** `bash bootstrap.sh` (auto-detects OS and routes to `platform/<os>.sh`)
- [ ] **E2** All 10 phases complete with:
  ```
  ═══════════════════════════════════════════════════════════════
    Outpost bootstrap complete (full mode) — verify: ALL PASS
  ═══════════════════════════════════════════════════════════════
  ```
  (the suffix reflects `verify.sh`'s verdict — `PASS with WARNINGS` is also a success)
- [ ] **E3** Phase 8 triggers one `manifest-sync` run and **waits for a
      fresh heartbeat**. If it can't get one within 300s, bootstrap exits
      non-zero on purpose: a stack that can't complete a single sync is not
      a working install. The error names the two commands to inspect
      (`kubectl -n outpost-ci logs job/manifest-sync-bootstrap`)
- [ ] **E4 (WSL2 only)** If bootstrap printed a `wsl --shutdown` reminder (first-time systemd enable), do that from PowerShell. After reopening WSL, systemd brings docker / k3s / Compose / the runner back automatically

### Phase F — Verify (~2 min) — **same on all platforms**

> ⚠️ This is the **one and only** place to run connectivity checks. Anything before bootstrap will fail.

- [ ] **F1** One-shot stack health: `bash verify.sh` — should be all PASS (WARN is acceptable)
- [ ] **F2** cloudflared connection registration:
  ```bash
  docker logs cloudflared --tail 50 | grep "Registered tunnel connection"
  ```
  Expect at least 4 lines (one per Cloudflare region)
- [ ] **F3** Cloudflare Dashboard → tunnel status flips to *Healthy*
- [ ] **F4** Browser → `https://mq.<your-domain>` (RabbitMQ management UI) and `https://registry.<your-domain>/v2/` (registry API, returns `{}`). Credentials live in `INFRA.md`. There is **no CI/CD dashboard to open** in v0.3
- [ ] **F5** CI/CD liveness — these are the checks that used to fail silently:
  ```bash
  systemctl status 'actions.runner.*'          # runner service up
  outpost status                               # sync-heartbeat: last_sync_ts / applied_head / last_result
  systemctl status outpost-verify.timer        # dead-man switch armed
  ```
- [ ] **F6** Any FAIL → look up the matching section in `06-troubleshooting.md` or `07-ai-verification.md` §1

### Phase G — Survive a restart — **branches by Outpost-host platform**

#### G-mac

bootstrap already registered a launchd LaunchAgent (`platform/macos.sh`).

- [ ] **G1** Confirm: `launchctl list | grep io.smithyhaus.outpost`
- [ ] **G2** Set Docker Desktop to start at login (Docker Desktop → Settings → General → Start Docker Desktop when you sign in)
- [ ] The k3d cluster comes back when Docker Desktop starts; Compose comes back via the LaunchAgent. No manual steps after reboot

#### G-linux

bootstrap ran `systemctl enable docker k3s`; Compose containers all carry `restart: unless-stopped`.

- [ ] **G1** Confirm: `sudo systemctl is-enabled docker k3s` both print `enabled`
- [ ] **G2** Confirm the CI/CD units survive too: `systemctl is-enabled outpost-verify.timer` and `systemctl status 'actions.runner.*'`
- [ ] No manual steps after reboot

#### G-wsl (**WSL2 only**)

systemd inside WSL is enabled, but **the WSL distro itself doesn't auto-start with Windows**. You need a Windows Task Scheduler entry to launch it.

- [ ] **G1** Follow `03-windows-autostart.md` to register a logon task that runs `wsl.exe -d Ubuntu -u <user> -- bash -lc "cd ~/outpost && ./status.sh"`
- [ ] **G2** Optional: in `.wslconfig` add `[experimental]\nautoMemoryReclaim=gradual` so WSL doesn't fully stop on idle
- [ ] **G3** Remember that a stopped distro means a stopped runner: pushes queue on GitHub instead of failing. `outpost-verify.timer` is what tells you — it catches up on `Persistent=true` after the distro returns

### Phase H — Dev workstation TCP access (optional) — **branches by dev-workstation platform**

⚠️ **Important**: this installs cloudflared on your **dev workstation** (the laptop you write code on) so it can open local TCP tunnels to PG / Redis / RabbitMQ. **Independent of the Outpost host.** If your Outpost host *is* your dev workstation, just use `localhost:5432` directly and **skip this phase**.

HTTP services (RabbitMQ UI / Manticore HTTP API / Registry) work in the browser via `https://...` — they do NOT need this phase. Note: Manticore's HTTP endpoint is a JSON API, not a UI — opening it in the browser returns API responses, not a dashboard.

Full instructions in `04-client-access.md`, **including the v0.3
prerequisite**: the data services are now ClusterIP-only inside k3s, so a
CF TCP row needs an origin you expose on the host first. Short version:

- **macOS workstation**: `brew install cloudflared` → `cloudflared login` → write a launchd plist
- **Linux workstation**: download the binary → write a systemd-user unit
- **Windows workstation**: `winget install --id Cloudflare.cloudflared` → Task Scheduler

### Phase I — Onboard your first app (optional) — **same on all platforms**

**Fastest end-to-end CI/CD smoke test**: use one of the ready-made
Hello-World apps in `examples/hello-world/<lang>/` as your application
repo — gets the whole pipeline exercised in ~2 minutes without writing
any code. Six languages: React / Vue / C# / Python / Java / Go. Each
ships with a `Dockerfile` and a `manifest/` directory.
Walkthrough: `../../../examples/hello-world/README.md`.

Onboarding your own application: see `05-onboard-project.md`. Sketch:

1. Create an application code repo with a `Dockerfile` at the root, on
   gitee (primary), plus a github copy
2. `bash scripts/outpost onboard <clone-url>` — appends the repo to
   `OUTPOST_REPOS` (which is what makes `verify.sh` reconciliation watch
   it) and prints the CI hookup steps
3. Copy `templates/github/outpost-build.yml` into the app repo at
   `.github/workflows/outpost-build.yml`; adjust the `branches: [main]`
   line if your deploy branch differs
4. Set up dual-push (or a gitee one-way push-mirror) so the github copy
   tracks gitee
5. In the manifest repo, add `apps/<app>/` (Deployment + Service +
   Ingress + kustomization) — `outpost manifest scaffold` does this
6. Push code → the runner builds and pushes a `sha-7`-tagged image →
   `scripts/update-manifest.sh` bumps the manifest repo → `manifest-sync`
   applies it within `MANIFEST_SYNC_INTERVAL` minutes →
   `https://<app>-apps.<root>` is live

**There is no webhook to register, on either repo.** If you're looking
for that step, it doesn't exist any more.

Application secrets (DB connection strings, API tokens) get sealed with
SealedSecret before committing to git — see `08-seal-secret.md`.

### Phase J — Test gate, auto-rollback, notifications (optional but recommended)

> This phase wires up:
>
> - **Gate A** — pre-deploy tests, run by `scripts/ci/run-tests.sh` on the runner **before** the manifest is bumped. On failure the manifest never updates, so the cluster never sees the broken image.
> - **Gate B** — post-deploy canary + automated rollback (Argo Rollouts, controller-only). Opt-in per app by adopting the `Rollout` CRD in its manifest.
> - **Multi-channel notifications** — DingTalk / Feishu / WeCom / generic webhook, plugin-driven, fanned out by `scripts/notify-fanout.sh`.
>
> **All of this is opt-in.** If you skip Phase J your pipeline still works — you just don't get tests, canaries, or alerts.
>
> Design history: `proposals/cicd-test-gate.md` (written for the
> Tekton/ArgoCD era — read it for the *why*, not the *how*).

#### J-1. Pick channels (browser, ~5 min)

For each channel you want, get a webhook URL from the vendor:

| Channel | Where to create the bot | Optional |
|---|---|---|
| DingTalk | Group settings → Bots → Custom (recommend signed) | sign secret |
| Feishu (Lark) | Group settings → Bots → Custom Bot | sign secret |
| WeCom (企业微信) | Group settings → Add Group Robot → Custom | — |
| Generic | Your own HTTPS endpoint that accepts JSON POST | Bearer token |

#### J-2. Drop into `.env` (Outpost host, ~1 min)

```env
# Pick any combination — comma-separated. Empty = no notifications.
NOTIFICATION_PROVIDERS=dingtalk,feishu

DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
DINGTALK_SIGN_SECRET=SEC...                  # optional (recommended)

FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...
FEISHU_SIGN_SECRET=                          # optional

WECOM_WEBHOOK_URL=
GENERIC_WEBHOOK_URL=
GENERIC_WEBHOOK_BEARER=                       # optional Bearer token

# Tests + rollback (defaults shown — usually no override needed)
TEST_RUNNER=testkube
TESTKUBE_MODE=skip                           # default — run-tests.sh evaluates
                                             # outpost.test.yaml directly;
                                             # set to oss to install the agent
ROLLOUT_PLUGIN=none                          # set to argo-rollouts for canaries
```

#### J-3. Re-run bootstrap (~3 min)

```bash
bash bootstrap.sh
```

Phase 9 of bootstrap will:

1. Handle the test runner (with `TESTKUBE_MODE=skip`, the default, nothing is installed in-cluster — Gate A runs on the host).
2. Install the **Argo Rollouts controller** if `ROLLOUT_PLUGIN=argo-rollouts` (controller only — there is no dashboard in v0.3).
3. Apply the enabled notification plugins' Secrets + ConfigMaps into `outpost-ci`, where the `manifest-sync` CronJob reads them.

**Events delivered to every enabled channel:**

| Event | Fires from | What you use it for |
|---|---|---|
| `build-failed` | the GitHub Actions workflow | Build, Gate A, or manifest bump went red |
| `deploy-succeeded` | the `manifest-sync` CronJob | A push actually shipped |
| `deploy-failed` | the `manifest-sync` CronJob | Bad manifest / image pull fail / rollout timed out |
| `verify-failed` | the host `outpost-verify.timer` | Something in the chain went dark — the detector that lives outside both the cluster and GitHub |

#### J-4. Add `outpost.test.yaml` to your app repo (~2 min per app)

Drop this at the repo root:

```yaml
version: 1
runner:
  image: golang:1.23-alpine     # optional; default alpine:3.20
  command:
    - sh
    - -c
    - "go test ./..."           # or pytest, npm test, mvn test, dotnet test
```

`.runner.command` is required. The command runs **inside a container**
(the app repo is untrusted code relative to the runner host), with the
workspace bind-mounted at `/workspace`. If neither `outpost.test.yaml` nor
`Dockerfile.test` is present in the repo root, Gate A **skips cleanly** —
your pipeline still works without tests.

#### J-5. Adopt Argo Rollouts in your app's manifest (optional but where the magic is)

Set `ROLLOUT_PLUGIN=argo-rollouts` and re-bootstrap, then in your manifest
repo's `apps/<app>/deployment.yaml` swap `Deployment` for `Rollout`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: my-app, namespace: apps }
spec:
  replicas: 3
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 30s }
        - setWeight: 50
        - pause: { duration: 30s }
        - setWeight: 100
  selector: { matchLabels: { app: my-app } }
  template: { ... }      # same as Deployment.spec.template
```

`manifest-sync` is `Rollout`-kind aware: instead of `kubectl rollout
status`, it polls `.status.phase` and treats `Degraded` as a failed
deploy — which fires `deploy-failed` to your channels.

#### J-6. Verify the wiring works (~2 min)

```bash
# Deploy side
outpost status                       # sync heartbeat
outpost logs sync                    # latest manifest-sync Job logs

# Build side (no in-cluster UI — builds run on the host runner)
journalctl -u 'actions.runner.*' -n 200
# …or the GitHub Actions tab on the app repo

# Namespaces
kubectl get pods -n outpost-ci
kubectl get pods -n argo-rollouts    # only if ROLLOUT_PLUGIN=argo-rollouts
kubectl get cm,secret -n outpost-ci
```

Test the failure path: break `examples/hello-world/go/main.go` (e.g. make a
test fail), `git push` → the workflow goes red at *Run tests (Gate A)* →
DingTalk/Feishu shows `build-failed` → manifest repo unchanged → cluster
app unaffected.

---

## Push-to-deploy crash course — 5 things you'll do every day (for newcomers)

### One-line mental model

```
You git push (to gitee AND github)                            ┌── App is live
    │                                                          │
    └─> GitHub dispatches outpost-build.yml to YOUR runner     │
          │                                                    │
          ├─> build-image.sh: buildctl → registry, tag = sha7  │
          ├─> run-tests.sh:   Gate A (opt-in)                  │
          └─> update-manifest.sh: rewrites the image tag in    │
              the manifest repo (gitee)                        │
              │                                                │
              └─> manifest-sync CronJob (every 2 min) pulls,   │
                  kubectl apply -k, waits for rollout ────────┘
```

**Everything flows through the manifest repo.** You don't `kubectl apply`
from your terminal. To change replicas / env vars / resource limits, you
edit YAML in the manifest repo and push — the next sync tick applies it.

### 1️⃣ "Where is my latest build?"

The **GitHub Actions tab** on your app repo — that's the build UI now.
The `outpost-build` workflow has three meaningful steps:

| Step | What it does | Common failure |
|------|--------------|----------------|
| `Build image` | `buildctl` → in-cluster buildkitd (`127.0.0.1:30750`) → push `sha-7` tag | bad Dockerfile / base-image pull timeout / buildkitd not Ready |
| `Run tests (Gate A)` | runs `outpost.test.yaml`'s command in a container | your tests actually failed; or `yq`/`docker` missing on the runner |
| `Update manifest` | rewrites the image tag in the manifest repo | manifest repo missing `apps/<app>/` / token can't push |

No GitHub access at the moment? The same logs are on the host:
`journalctl -u 'actions.runner.*' -n 200`.

### 2️⃣ "Is my app actually running in K8s?"

```bash
outpost status               # sync-heartbeat: last_sync_ts / applied_head / last_result
outpost verify --app <app>   # pods, deployed image, recent events for one app
```

`last_result=ok` with a fresh `last_sync_ts` means the CD half is alive.
A stale heartbeat (older than 3× `MANIFEST_SYNC_INTERVAL`) is a `verify.sh`
FAIL — deploys have stopped, regardless of what the CronJob object says.

### 3️⃣ Force a sync now (don't wait the 2 minutes)

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

### 4️⃣ My app is broken — how do I get to the logs?

```bash
outpost logs <app>                       # pods in the 'apps' namespace

# or by hand
kubectl get pods -n apps -l app=<app-name>
kubectl logs -n apps -l app=<app-name> -f --all-containers
kubectl logs -n apps <pod-name> --previous     # previous crash
```

### 5️⃣ How do I "deploy" a change?

**Option A — change code** (most common):
```
edit code in the app repo → git push → watch the GitHub Actions run (~1-2 min)
                                     → manifest-sync applies it (≤2 min) → done
```
Fully automatic. You only `git push`.

**Option B — change deployment params** (replicas, env vars, limits):
```
edit apps/<app>/deployment.yaml in the manifest repo → git push
                                     → next sync tick applies it
```

**Option C — roll back a bad deploy**:
```bash
outpost rollback <app>          # lists the tags still in the registry
outpost rollback <app> abc1234  # rewrites the manifest; sync converges in ~2 min
```
This path is **fully domestic** (gitee + local cluster) — it works with
github.com unreachable.

**Option D — change a secret** (DB password rotated, etc.):
- Don't edit `sealed-secret.yaml` in git directly (encrypted bytes won't decrypt).
- Re-run the application's `scripts/onboard.sh` to re-encrypt with the live public key, then push.
- Full flow: `08-seal-secret.md`.

> ⚠️ **Never `kubectl apply` directly into the `apps` namespace.** Nothing
> will revert it immediately — there's no ArgoCD self-heal loop any more —
> which is precisely the danger: your change silently diverges from the
> manifest repo and gets clobbered the next time that app's manifest
> changes. Always edit the manifest repo.

### Cheat sheet

| Goal | Where |
|------|-------|
| See where my build is | GitHub Actions tab, or `journalctl -u 'actions.runner.*'` |
| See deploy status | `outpost status` / `outpost logs sync` |
| See app runtime logs | `outpost logs <app>`, or `kubectl logs -n apps -l app=<X>` |
| Roll back a bad image | `outpost rollback <app> [sha]` |
| Add a secret to an app | the app repo's `scripts/onboard.sh` (see `08-seal-secret.md`) |
| Change replicas / resources / env | manifest repo `apps/<app>/deployment.yaml`, then push |
| Check the whole chain is alive | `bash verify.sh` (reconciliation is the ultimate judge) |

---

## What to read next

| Goal | Read |
|------|-------|
| Diagnose a misbehaving component | `06-troubleshooting.md` |
| Have an AI agent (Claude / Cursor / Cline) diagnose for you | `07-ai-verification.md` + `verify.sh --json` |
| Onboard the second / third / Nth app | `05-onboard-project.md` |
| Switch to Aliyun ACR / add a Git provider | `plugins/README.md` + edit `.env` + re-run `bootstrap.sh` |
| Understand the architecture | `../../../ARCHITECTURE.md` |
| Why Tekton + ArgoCD were replaced | `../../../docs/decisions/0003-github-actions-engine-swap.md` |

## Start over from scratch

```bash
~/outpost/reset.sh        # type the confirmation phrase to wipe volumes + K8s
~/outpost/bootstrap.sh    # re-run
```

For a full host rebuild (new WSL2 box, distro wipe), use the runbook
instead: `../../../docs/prp/runbooks/wsl2-redeploy-0.3.md`.
