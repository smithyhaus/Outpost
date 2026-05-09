# 00 — Quick Start (all platforms)

> This is the **only entry-point doc** for Outpost. Read it end-to-end and
> you can stand up the full stack from scratch. Everything else under
> `docs/` is reference material, not a tutorial.
> Covers macOS / Linux native / Windows WSL2.

## Pick a mode first

| Mode | What you get | Required input | When to use |
|------|--------------|----------------|-------------|
| **`local`** *(default)* | Compose data services on `localhost` (PG / Redis / RabbitMQ / Meilisearch) | none | personal dev backend on this box, no public hosting, no CI/CD |
| **`full`** | `local` + Cloudflare Tunnel + k3s + ArgoCD + Tekton GitOps | `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`, `MANIFEST_REPO_URL` | want a public domain + push-to-deploy GitOps |

> You can switch modes at any time. Start in `local`; once comfortable,
> set `OUTPOST_MODE=full` in `.env` and re-run `bootstrap.sh`. Existing
> data volumes and generated passwords are reused.

> ⚠️ **v0.1 limitation**: `full` mode is fully wired only for **Gitee**
> (the default). `GIT_PROVIDER_PLUGIN=github` / `gitlab` ship plugin
> scaffolding but `core/k8s/05-tekton/eventlistener.yaml` does not yet
> merge the plugin's trigger fragment (see "Multi-provider EventListener
> wiring" in `TODOS.md`). To use GitHub / GitLab today you'd need to
> hand-edit the EventListener's CEL filter and binding ref, or wait for
> v0.2.

---

## Terminology

- **Outpost host** — the machine that runs `bootstrap.sh` (macOS / Linux / WSL2).
- **Dev workstation** — the machine you use to write code and connect with
  DBeaver / Redis Insight / etc. (often the same as the Outpost host, but
  may be a different laptop).
- **Manifest repo** — ArgoCD's source-of-truth, holds K8s YAML for each
  app. **Not** the same as your application code repo.

---

## `local` mode — shortest path (~2 min)

Same on every platform. If you don't need a public domain or GitOps,
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
- [ ] **A4** Open the tunnel detail page → **Public Hostname** tab → add the 10 rows (full table in `01-cloudflare-setup.md` §3):
  - 7 HTTP rows: `search` / `mq` / `argocd` / `tekton` / `hooks` / `registry` / `*.apps`
  - 3 TCP rows: `pg` / `redis` / `rabbitmq`
  - **Extra for `registry`**: expand *Additional application settings → HTTP Settings → HTTP Host Header* and set it to `registry.<your-domain>` (Docker Registry is Host-header sensitive; without this, image pulls 401)
- [ ] **A5** The Tunnel status in the Dashboard will show *Inactive / Down* — **expected**, because cloudflared isn't running locally yet. **Do NOT run any connectivity check here.** Real verification happens in Phase F

### Phase B — System prep — **branches by Outpost-host platform**

#### B-mac (macOS) ~5 min

- [ ] **B1** Install Docker Desktop: `brew install --cask docker` → `open -a Docker`. Wait for the menu-bar whale to go green
- [ ] **B2** Install base tools: `brew install git jq gettext` (Apple Silicon already ships bash/curl/openssl)
- [ ] **B3** *(optional, restricted networks)* Docker Desktop → Settings → Docker Engine, add a mirror:
  ```json
  { "registry-mirrors": ["https://docker.m.daocloud.io"] }
  ```
- [ ] **B4** Self-test: `docker run --rm hello-world`
- [ ] Skip `.wslconfig` and Windows Task Scheduler (not applicable)

#### B-linux (native Linux) ~5 min

- [ ] **B1** Base tools: `sudo apt update && sudo apt install -y curl git openssl gettext-base ca-certificates jq` (Debian/Ubuntu; use the equivalent for other distros)
- [ ] **B2** Docker: bootstrap can install it for you (via the official `get.docker.com` script), or install it manually beforehand
- [ ] **B3** Add yourself to the docker group: `sudo usermod -aG docker $USER`, then **log out and back in**
- [ ] **B4** Self-test: `docker run --rm hello-world`
- [ ] Skip `.wslconfig` and Windows Task Scheduler (not applicable)

#### B-wsl (Windows + WSL2) ~15 min

> Full details in `02-wsl-config.md` (only WSL2 readers need it)

- [ ] **B1** Confirm Win11 22H2+. PowerShell (admin): `wsl --install -d Ubuntu`
- [ ] **B2** Write `C:\Users\<you>\.wslconfig` (template in `02-wsl-config.md` §1) → PowerShell `wsl --shutdown`
- [ ] **B3** Inside WSL → write `/etc/wsl.conf` to enable systemd (`02-wsl-config.md` §2.1) → PowerShell `wsl --shutdown` again → reopen WSL
- [ ] **B4** Configure Docker mirror (`02-wsl-config.md` §2.2) + `sudo systemctl restart docker`
- [ ] **B5** `sudo apt install -y curl git openssl gettext-base ca-certificates jq`
- [ ] **B6** Self-test: `docker run --rm hello-world` and `systemctl status` both work

### Phase C — Manifest repo (browser + any machine, ~3 min) — **same on all platforms**

- [ ] **C1** Create an **empty private** repo on Gitee / GitHub / GitLab, e.g. `<user>/manifests`
- [ ] **C2** Clone locally → add two empty directories → push:
  ```bash
  git clone <repo HTTPS URL> manifests && cd manifests
  mkdir -p apps argocd-apps
  touch apps/.gitkeep argocd-apps/.gitkeep
  git add . && git commit -m "init" && git push
  ```
- [ ] **C3** On the Git provider, generate a **Personal Access Token**:
  - Gitee: tick `projects` (read+write)
  - GitHub: tick `repo` (full)
  - GitLab: tick `api`
  - Save it for Phase D

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
  GIT_PROVIDER_PLUGIN=gitee     # or github / gitlab
  ```
  Leave password fields (`POSTGRES_PASSWORD` etc.) blank — bootstrap auto-generates strong values

### Phase E — Bootstrap (~5 min) — **same on all platforms**

- [ ] **E1** `bash bootstrap.sh` (auto-detects OS and routes to `platform/<os>.sh`)
- [ ] **E2** All 9 phases complete with:
  ```
  ═══════════════════════════════════════════════════════════════
    Outpost bootstrap complete (full mode)
  ═══════════════════════════════════════════════════════════════
  ```
- [ ] **E3 (WSL2 only)** If bootstrap printed a `wsl --shutdown` reminder (first-time systemd enable), do that from PowerShell. After reopening WSL, systemd brings docker / k3s / Compose back automatically

### Phase F — Verify (~2 min) — **same on all platforms**

> ⚠️ This is the **one and only** place to run connectivity checks. Anything before bootstrap will fail.

- [ ] **F1** One-shot stack health: `bash verify.sh` — should be all PASS (WARN is acceptable)
- [ ] **F2** cloudflared connection registration:
  ```bash
  docker logs cloudflared --tail 50 | grep "Registered tunnel connection"
  ```
  Expect at least 4 lines (one per Cloudflare region)
- [ ] **F3** Cloudflare Dashboard → tunnel status flips to *Healthy*
- [ ] **F4** Browser → `https://argocd.<your-domain>` (ArgoCD) and `https://tekton.<your-domain>` (Tekton Dashboard) — both should load. Credentials live in `INFRA.md`
- [ ] **F5** Any FAIL → look up the matching section in `06-troubleshooting.md` or `07-ai-verification.md` §1

### Phase G — Survive a restart — **branches by Outpost-host platform**

#### G-mac

bootstrap already registered a launchd LaunchAgent (`platform/macos.sh:52`).

- [ ] **G1** Confirm: `launchctl list | grep io.smithyhaus.outpost`
- [ ] **G2** Set Docker Desktop to start at login (Docker Desktop → Settings → General → Start Docker Desktop when you sign in)
- [ ] The k3d cluster comes back when Docker Desktop starts; Compose comes back via the LaunchAgent. No manual steps after reboot

#### G-linux

bootstrap ran `systemctl enable docker k3s`; Compose containers all carry `restart: unless-stopped`.

- [ ] **G1** Confirm: `sudo systemctl is-enabled docker k3s` both print `enabled`
- [ ] No manual steps after reboot

#### G-wsl (**WSL2 only**)

systemd inside WSL is enabled, but **the WSL distro itself doesn't auto-start with Windows**. You need a Windows Task Scheduler entry to launch it.

- [ ] **G1** Follow `03-windows-autostart.md` to register a logon task that runs `wsl.exe -d Ubuntu -u <user> -- bash -lc "cd ~/outpost && ./status.sh"`
- [ ] **G2** Optional: in `.wslconfig` add `[experimental]\nautoMemoryReclaim=gradual` so WSL doesn't fully stop on idle

### Phase H — Dev workstation TCP access (optional) — **branches by dev-workstation platform**

⚠️ **Important**: this installs cloudflared on your **dev workstation** (the laptop you write code on) so it can open local TCP tunnels to PG / Redis / RabbitMQ. **Independent of the Outpost host.** If your Outpost host *is* your dev workstation, just use `localhost:5432` directly and **skip this phase**.

HTTP services (ArgoCD UI / RabbitMQ UI / Meilisearch / Registry) work in the browser via `https://...` — they do NOT need this phase.

Full instructions in `04-client-access.md`. Short version:

- **macOS workstation**: `brew install cloudflared` → `cloudflared login` → write a launchd plist
- **Linux workstation**: download the binary → write a systemd-user unit
- **Windows workstation**: `winget install --id Cloudflare.cloudflared` → Task Scheduler

### Phase I — Onboard your first app (optional) — **same on all platforms**

**Fastest end-to-end CI/CD smoke test**: use one of the ready-made
Hello-World apps in `examples/hello-world/<lang>/` as your application
repo — gets the whole pipeline exercised in ~2 minutes without writing
any code. Six languages: React / Vue / C# / Python / Java / Go. Each
ships with a `Dockerfile`, `manifest/`, and `argocd-application.yaml`.
Walkthrough: `../../../examples/hello-world/README.md`.

Onboarding your own application: see `05-onboard-project.md`. Sketch:

1. Create an application code repo with a `Dockerfile` at the root
2. In the manifest repo, add `apps/<app>/` (Deployment + Service + Ingress) and `argocd-apps/<app>.yaml` (ArgoCD Application)
3. Configure a webhook on the application repo: URL `https://hooks.<root>`, secret `${GIT_WEBHOOK_SECRET}` from `INFRA.md`
4. Push code → Tekton builds → ArgoCD deploys → `https://<app>.apps.<root>` is live

Application secrets (DB connection strings, API tokens) get sealed with
SealedSecret before committing to git — see `08-seal-secret.md`.

---

## GitOps crash course — 5 things you'll do every day (for newcomers)

### One-line mental model

```
You git push                                                   ┌── App is live
    │                                                          │
    └─> Tekton builds a docker image and pushes to registry    │
          │                                                    │
          └─> Tekton rewrites the image tag in the manifest    │
              repo (new SHA)                                   │
              │                                                │
              └─> ArgoCD sees the manifest changed,            │
                  kubectl applies it for you ─────────────────┘
```

**Everything flows through the manifest repo.** You don't `kubectl apply`
from your terminal. To change replicas / env vars / resource limits, you
edit YAML in the manifest repo and push — ArgoCD catches up automatically.

### 1️⃣ "Where is my latest build?"

Open **Tekton Dashboard**: `https://tekton.<your-root>` (no login; the
homepage *is* the PipelineRuns list).

The top entry is your most recent build. Click in to see the 3 tasks:

| Task | What it does | Common failure |
|------|--------------|----------------|
| `fetch-source` | clones your app repo | wrong git creds / wrong repo URL |
| `build-and-push` | kaniko build + push to registry | bad Dockerfile / base-image pull timeout |
| `update-manifest` | rewrites the image tag in the manifest repo | manifest repo missing `apps/<app>/` / token can't push |

Each task expands to per-step logs, GitHub-Actions style.

### 2️⃣ "Is my app actually running in K8s?"

Open **ArgoCD UI**: `https://argocd.<your-root>` (user `admin`, password
in `INFRA.md` §6 or via `grep ARGOCD_ADMIN_PASSWORD .env`).

The home page shows every Application as a card with two status flags:

| Status | Meaning | What to do |
|--------|---------|------------|
| **Synced + Healthy** (green) | what's running == what's in git, and pods ready | nothing |
| **OutOfSync** | git changed, cluster hasn't caught up yet | usually auto-syncs in 30s. Otherwise click **SYNC** |
| **Degraded** | applied OK but pods aren't healthy (CrashLoop / ImagePullBackOff / readiness failing) | click into the card → find the red resource → click the pod → look at Events / Logs |
| **Missing** | manifest declares it but cluster doesn't have it | same: click SYNC |

Click any card and you see "what the manifest declares" vs "what the
cluster actually has", with the diff highlighted.

### 3️⃣ Force ArgoCD to sync now (don't wait the 30s)

ArgoCD UI → click the Application card → top right **SYNC** → default
options → SYNCHRONIZE.

Or from the terminal:
```bash
kubectl patch application <app> -n argocd --type merge \
  -p '{"operation":{"sync":{}}}'
```

### 4️⃣ My app is broken — how do I get to the logs?

Via ArgoCD: open the Application → click the red pod → **LOGS** tab.
Or via terminal:

```bash
# Find the pod name
kubectl get pods -n apps -l app=<app-name>

# Live tail
kubectl logs -n apps -l app=<app-name> -f --all-containers

# Logs from the previous crash
kubectl logs -n apps <pod-name> --previous
```

### 5️⃣ How do I "deploy" a change?

**Option A — change code** (most common):
```
edit code in the app repo → git push → watch Tekton Dashboard ~30s
                                     → wait for ArgoCD sync ~30s → done
```
Fully automatic. You only `git push`.

**Option B — change deployment params** (replicas, env vars, limits):
```
edit apps/<app>/deployment.yaml in the manifest repo → git push
                                     → ArgoCD applies within 30s
```

**Option C — change a secret** (DB password rotated, etc.):
- Don't edit `sealed-secret.yaml` in git directly (encrypted bytes won't decrypt).
- Re-run the application's `scripts/onboard.sh` to re-encrypt with the live public key, then push.
- Full flow: `08-seal-secret.md`.

> ⚠️ **Never `kubectl apply` directly into the `apps` namespace.** ArgoCD's
> self-heal will overwrite your change within 30s, restoring whatever the
> manifest repo says. Always edit the manifest repo.

### Cheat sheet

| Goal | Where |
|------|-------|
| See where my build is | Tekton Dashboard `https://tekton.<root>` |
| See app deploy status / force sync | ArgoCD UI `https://argocd.<root>` |
| See app runtime logs | ArgoCD → Application → pod → LOGS, or `kubectl logs -n apps -l app=<X>` |
| Add a secret to an app | the app repo's `scripts/onboard.sh` (see `08-seal-secret.md`) |
| Change replicas / resources / env | manifest repo `apps/<app>/deployment.yaml`, then push |

---

## What to read next

| Goal | Read |
|------|-------|
| Diagnose a misbehaving component | `06-troubleshooting.md` |
| Have an AI agent (Claude / Cursor / Cline) diagnose for you | `07-ai-verification.md` + `verify.sh --json` |
| Onboard the second / third / Nth app | `05-onboard-project.md` |
| Switch to Aliyun ACR / GitHub / GitLab | `plugins/README.md` + edit `.env` + re-run `bootstrap.sh` |
| Understand the architecture | `../../ARCHITECTURE.md` |

## Start over from scratch

```bash
~/outpost/reset.sh        # type the confirmation phrase to wipe volumes + K8s
~/outpost/bootstrap.sh    # re-run
```
