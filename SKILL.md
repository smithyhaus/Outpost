---
name: outpost
description: |
  Operating skill for the Outpost dev backend project. Two-layer
  architecture: Docker Compose for stateful data services + k3s for
  applications and GitOps CI/CD, fronted by a single Cloudflare Tunnel.
  Plugin-driven (registry, git-provider, test-runner, rollout, notification).
  Targets macOS / Linux / WSL2.
when_to_use: |
  Any operation inside an Outpost checkout — verifying health,
  diagnosing failures, onboarding a new project, modifying configuration,
  authoring a new plugin, or answering user questions about this stack.
---

# Outpost — operating skill

## 1. Identity

- **Type:** single-machine self-hosted dev backend.
- **Carriers:** Docker Compose (stateful data) + k3s (apps + CI/CD).
- **Public ingress:** Cloudflare Tunnel only — no public IP / port forward.
- **Plugin model:** directory-based, one plugin per kind, swap via `.env`.
- **Platforms:** macOS, Linux, Windows 11 + WSL2. OS-specific bits live in
  `platform/<os>.sh`; everything else is portable.
- **Two modes** (`OUTPOST_MODE` in `.env`):
  - `local` *(default)* — Compose data services on `localhost` only. No CF
    Tunnel, no k3s, no GitOps. Zero required input.
  - `full` — `local` + Cloudflare Tunnel + k3s + ArgoCD + Tekton.
    Requires `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`,
    `MANIFEST_REPO_URL`.

## 2. Architecture

```
Cloudflare edge (HTTPS / TLS)
    │
    ▼
cloudflared (Compose container)
    ├─→ caddy:80 ─→ search.* / mq.* (HTTP UIs for stateful infra)
    ├─→ postgres:5432 (TCP)
    ├─→ redis:6379 (TCP)
    ├─→ rabbitmq:5672 (TCP)
    └─→ host.docker.internal:30080 ─→ k3s Traefik
                                         ├─ argocd.*       → argocd-server
                                         ├─ hooks.*        → tekton EventListener
                                         ├─ registry.*     → docker-registry
                                         └─ *.<root>       → user apps (catch-all)
                                            (apps named `<x>-apps.<root>`,
                                             one-level FQDN → free Universal SSL)
```

**Layer boundaries are strict:**
- Layer 1 (Compose) is for stateful infrastructure + ingress only.
- Layer 2 (k3s) is for stateless apps + CI/CD.
- They communicate via ExternalName Services in the `infra-bridges` namespace:

```
postgres.infra-bridges.svc.cluster.local       → host.docker.internal:5432
redis.infra-bridges.svc.cluster.local          → host.docker.internal:6379
rabbitmq.infra-bridges.svc.cluster.local       → host.docker.internal:5672
manticore.infra-bridges.svc.cluster.local      → host.docker.internal:9308 (HTTP)
manticore.infra-bridges.svc.cluster.local      → host.docker.internal:9306 (SQL)
```

Apps reference these bridge DNS names. To migrate to managed cloud services
in production, change only the ExternalName — application code stays unchanged.

## 3. File pointer map

| Looking for | Path |
|-------------|------|
| **First-run quickstart (all platforms)** | `i18n/en/docs/00-quickstart.md` / `i18n/zh-CN/docs/00-quickstart.md` |
| Static architecture doc | `ARCHITECTURE.md` |
| Credentials (rendered) | `INFRA.md` / `INFRA.zh-CN.md` (gitignored) |
| Credential template (full mode) | `i18n/en/INFRA.md.template`, `i18n/zh-CN/INFRA.md.template` |
| Credential template (local mode) | `i18n/en/INFRA.local.md.template`, `i18n/zh-CN/INFRA.local.md.template` |
| Compose stack | `core/compose/docker-compose.yml` |
| Caddy routes | `core/compose/Caddyfile` |
| Cloudflared ingress reference | `core/compose/cloudflared/config.template.yml` |
| Namespaces | `core/k8s/00-namespaces.yaml` |
| Traefik NodePort config | `core/k8s/01-traefik-config.yaml` |
| ArgoCD pieces | `core/k8s/04-argocd/` |
| Tekton pieces | `core/k8s/05-tekton/` |
| Bridge services | `core/k8s/06-bridges/` |
| Demo app (manifest-only template) | `examples/demo-app/` |
| Hello-World pipeline smoke tests (6 languages) | `examples/hello-world/` |
| Cross-platform shell helpers | `platform/lib/portable.sh` |
| Per-OS hooks | `platform/{macos,linux,wsl2}.sh` |
| Plugins | `plugins/<kind>/<name>/` |
| Plugin authoring guide | `plugins/README.md` |
| Bootstrap installer | `bootstrap.sh` |
| One-shot remote installer (curl-pipe-bash) | `install.sh` |
| App-side onboarding schema | `tests/schema/outpost-app.schema.json` |
| `outpost.app.yaml` examples (minimal + multi-product) | `examples/outpost.app.yaml.*.example` |
| Caddy app-fragment dir (per-installation, gitignored content) | `core/compose/Caddyfile.d/` |
| LLM onboarding skill (drop into app repos) | `docs/onboarding/outpost-app.skill.md` |
| Health check (AI parseable) | `verify.sh` (`--json`) |
| Health check schema | `tests/schema/verify-output.schema.json` |
| AI verification playbook | `i18n/en/docs/07-ai-verification.md` |
| Roadmap | `TODOS.md` |
| Test suite | `tests/bats/`, `tests/regression/` |
| CI workflows | `.github/workflows/` |

## 4. Critical invariants — DO NOT BREAK

1. **Compose data services bind 0.0.0.0:<port>**. Removing this disconnects
   k3s pods from the data layer (bridge services lose reachability).
2. **Traefik exposes NodePort 30080**. cloudflared depends on it.
3. **TLS is terminated at the Cloudflare edge.** Internal traffic is plain
   HTTP. Do not introduce cert-manager / ACME unless you also rip out the
   Cloudflare Tunnel pattern.
4. **`argocd-cmd-params-cm.server.insecure=true`** is required for the
   Traefik IngressRoute to talk to argocd-server over HTTP.
5. **Bridge services live in `infra-bridges` namespace.** App connection
   strings depend on this DNS name; renaming pollutes every app config.
6. **`apps` namespace is owned by ArgoCD**. Do NOT `kubectl apply` directly
   to it — ArgoCD self-heal will revert the change. Modify the manifest
   repository instead.
7. **EventListener CEL filter contains the webhook secret**. Rotating
   `GIT_WEBHOOK_SECRET` requires re-rendering and `kubectl apply`.
8. **`.env` and `INFRA*.md` must never be committed.** Listed in .gitignore;
   plaintext secrets leaking equals total compromise.
9. **Self-hosted registry traffic is plain HTTP** at the cluster level
   (containerd is configured with `insecure_skip_verify`). Do not add a
   registry-side TLS cert — public TLS is at the CF edge.
10. **`render_template` (in `platform/lib/portable.sh`) MUST detect
    unresolved `${VAR}` placeholders and abort.** This is the central
    anti-silent-failure guardrail. Bypassing it (e.g. with raw envsubst)
    risks deploying manifests with empty hostnames or missing secrets.
11. **`OUTPOST_MODE` gates k3s phases.** When `local`, bootstrap.sh exits
    after Phase 4 (Compose); verify.sh skips k8s/ArgoCD/Tekton/edge
    sections and emits `summary.mode="local"`. Don't `kubectl apply` from
    bootstrap or expect bridge services in local mode.

## 5. Operating principles

### Default behaviours
- Read before modifying. Don't assume from filename — open the file.
- Read-only commands (`kubectl get`, `docker ps`, `verify.sh`) require no
  permission.
- Mutating operations (`kubectl apply`, `docker compose down`, edits to
  `.env`) require explicit user assent unless instructed otherwise.
- **Never** run `reset.sh` unless the user said "reset" or "wipe everything".
- **Never** delete the namespaces `argocd`, `tekton-pipelines`,
  `infra-bridges`, `registry`, `kube-system`. They are load-bearing.

### Diagnosis order (cheap → expensive)
1. `bash verify.sh --json` (whole stack, ~5–10s)
2. `kubectl get pods -A | grep -v Running` (find sick pods)
3. `kubectl describe pod -n <ns> <pod>` (event log)
4. `kubectl logs -n <ns> <pod> --tail 100`
5. `docker logs <container> --tail 100` (Compose layer)
6. Consult `i18n/en/docs/06-troubleshooting.md`
7. Ask the user, with a specific question and what you've tried.

### Modification flow
```
1. Read existing file
2. State the intent: what & why
3. Show the proposed diff
4. User confirms
5. Apply
6. Run verify.sh on the affected section
```

### Project onboarding

**The architectural contract — read this once, then never get tier-confused:**

```
+-----------------------------------------------------------+
|                      cloudflared                          |
+-----+--------------------------+--------------------------+
      |                          |                          |
      v                          v                          v
*.<ROOT_DOMAIN>           <prefix>.<ROOT_DOMAIN>      <built-in>.<ROOT_DOMAIN>
broad CF wildcard         top-level (per-svc CF rule) argocd/hooks/search/mq/registry
(catches everything)
      |                          |                          |
      v                          v                          v
  k3s Traefik                Caddy :80                  Caddy :80
      |                          |                          |
      v                          v                          v
  STATELESS APPS             STATEFUL INFRA            BUILT-IN SERVICES
  named `<x>-apps.<root>`    SIDECARS (tier=compose)   (postgres / redis / ...)
  (tier=k3s)
```

**SSL constraint behind the naming convention:** Cloudflare Universal SSL
covers `*.<ROOT_DOMAIN>` for free (one-level wildcard). Apps live at
`<x>-apps.<ROOT_DOMAIN>` — still one-level FQDN, so free Universal SSL
covers them too. A two-level `*.apps.<ROOT_DOMAIN>` would require paid
Advanced Certificate Manager (~$10/mo) and is therefore avoided.
CF Tunnel doesn't support partial-label wildcards like `*-apps.<root>` in
public hostnames either — the `-apps` suffix is a naming convention
(enforced by validator + IngressRoute Host matching), not a CF routing
pattern.

When the user says "onboard X" / "add new project X":

1. **Decide the tier first:**
   - **Stateless application?** (HTTP server, worker, queue consumer, ML
     inference, CRUD service, ...) → `tier=k3s`. This is the default.
     Lands under `<name>-apps.<ROOT_DOMAIN>` — caught by the single
     `*.<ROOT_DOMAIN>` Cloudflare Tunnel wildcard → k3s Traefik. Zero
     Cloudflare Dashboard work per app.
   - **Stateful infrastructure?** (extra database, message queue, search
     engine, object store — anything that owns persistent data and would
     live alongside Postgres/Redis/RabbitMQ/Manticore) → `tier=compose`.
     Lands on a top-level subdomain via Caddy; requires a matching
     Cloudflare Tunnel Public Hostname entry pointing at `http://caddy:80`.
   - **In doubt?** It's almost certainly an application. Choose `tier=k3s`.

2. **Run `outpost onboard <path-or-url>`** if the repo has an
   `outpost.app.yaml`. For tier=k3s, pass `--manifests-dir <local-clone>
   --lang <go|python|java|csharp|react|vue>` to scaffold the k3s
   manifests. Honors `spec.k3s.manifest_repo` (per-app override) over the
   global `MANIFEST_REPO_URL`.

3. **If X has no `outpost.app.yaml`**, copy one from:
   - `examples/outpost.app.yaml.minimal.example` — tier=k3s starter
   - `examples/outpost.app.yaml.multiproduct.example` — tier=k3s with
     path-based fan-out (the SCM-MCP-style case, done right)
   - `examples/outpost.app.yaml.stateful-infra.example` — tier=compose,
     the only legitimate stateful-infra case

4. **Schema is the contract.** `tests/schema/outpost-app.schema.json`
   describes every field; `onboard_app_validate` (in
   `platform/lib/onboard-lib.sh`) enforces:
   - `tier=k3s` + `spec.routes` or `spec.caddy_fragment` → REJECTED
     (apps use IngressRoute via manifests, not Caddy fragments)
   - `tier=compose` + host ending in `-apps.<ROOT_DOMAIN>` → REJECTED
     (the `-apps` suffix is the apps naming convention; CF Tunnel's
     `*.<ROOT_DOMAIN>` wildcard routes that traffic to k3s, caddy never
     sees it)

5. **For k3s-tier apps**, also follow `i18n/en/docs/05-onboard-project.md`
   end-to-end (manifest repo files, SealedSecret, ArgoCD Application).
   Reuse `examples/demo-app/` as the manifest template.

6. **Anti-patterns to refuse:**
   - Adding per-app routes to `core/compose/Caddyfile` directly (the
     pre-v0.5 anti-pattern).
   - Setting `tier=compose` on a stateless server to "get caddy routing"
     — that route through caddy is for infra only, not for apps.
   - Adding a top-level subdomain for an app to bypass the
     `<name>-apps.<root>` naming convention (forces manual CF Dashboard
     work + violates the tier boundary).

Don't ask about tech stack — that lives in the user's repo, not here.

### Plugin authoring
Five plugin kinds today: `registry`, `git-provider`, `test-runner`,
`rollout`, `notification`. Future: `tunnel` (frp / tailscale / ngrok),
listed in `TODOS.md`.
- Copy the closest existing plugin under `plugins/<kind>/<name>/` and adapt.
- Required files per `plugins/README.md` contract: `plugin.yaml`,
  `manifest.yaml` (or `compose.yaml`), `preflight.sh`, `README.md`.
- Notification plugins additionally contribute
  `argocd-cm-fragment.yaml` + `argocd-secret-fragment.yaml` (concatenated
  by bootstrap into `argocd-notifications-cm` / `-secret`).
- Add a smoke test in `tests/bats/<kind>-plugins.bats`.
- Update the matrix in the project root `README.md` AND `README.zh-CN.md`.

## 6. Verification quick reference

Full check: `bash verify.sh --json` — parse the JSON. Schema lives at
`tests/schema/verify-output.schema.json`.

Single-layer probes:

```bash
# Compose
docker compose -f core/compose/docker-compose.yml ps
docker logs cloudflared --tail 30 | grep -i "Registered tunnel"

# k3s
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get application -n argocd
kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp | tail -5

# Bridges
kubectl get svc -n infra-bridges
kubectl run -it --rm test --image=alpine --restart=Never -- \
  sh -c "apk add busybox-extras >/dev/null && nc -zv host.docker.internal 5432"

# Public ingress (when ROOT_DOMAIN is real)
curl -sS -o /dev/null -w "%{http_code}\n" "https://argocd.${ROOT_DOMAIN}"
```

Detailed pass/fail criteria + diagnosis: `i18n/en/docs/07-ai-verification.md`.

## 7. Common task playbook

### "Is the stack healthy?"
Run `bash verify.sh --json`. Report PASS/WARN/FAIL counts; expand each
non-PASS with the cited check id and a one-line root cause hypothesis.

### "What's the connection string for X?"
Read from `INFRA.md` (or `INFRA.zh-CN.md`). Do not synthesize on the fly —
the rendered file is the source of truth.

### "Why didn't my push deploy?"
1. Git provider → repo → Webhooks → most recent delivery (status code)
2. `kubectl logs -n tekton-pipelines deploy/el-<provider>-listener --tail 100`
3. `kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp | tail -3`
4. ArgoCD UI → the Application → look at the commit it last synced

### "Add a Postgres extension"
- Postgres lives in Compose, not in any manifest.
- Edit `core/compose/postgres-init/01-pgvector.sql` — only effective on a
  fresh data volume.
- For an existing DB:
  ```bash
  docker exec -it postgres psql -U "$POSTGRES_USER" \
    -c 'CREATE EXTENSION IF NOT EXISTS <name>;'
  ```
- Update the credentials vault (`INFRA.md.template` for both languages).

### "Expose a new subdomain"

**Pick the right path by what you're exposing — the architectural contract
(see §5 "Project onboarding") drives the answer:**

- **Stateless application on `<name>-apps.<root>`** (the common case):
  add an `IngressRoute` in the manifest repo with `Host(`<name>-apps.<root>`)`.
  No Cloudflare changes — the broad `*.<root>` CF Tunnel wildcard already
  routes through cloudflared → k3s Traefik, where Traefik matches by Host
  header. Use `outpost onboard --manifests-dir <path> --lang <l>` for
  scaffolding.
- **Stateful infra HTTP service on `<prefix>.<root>`** (e.g. adding
  Elasticsearch's HTTP UI): write a Caddy fragment via
  `outpost onboard` (tier=compose) — do NOT edit
  `core/compose/Caddyfile` directly; the fragment lands in
  `core/compose/Caddyfile.d/<name>.caddy`. **Add a specific Public Hostname
  in the Cloudflare Dashboard** (`<prefix>.<root>` → `http://caddy:80`) so
  it overrides the broad `*.<root>` wildcard for this exact name — CF uses
  most-specific-wins matching.
- **Stateful infra TCP service** (raw database port etc.): just add a
  Public Hostname (TCP type) in the Cloudflare Dashboard. Caddy is
  HTTP-only and isn't in the path.

**Refuse to do**: edit `core/compose/Caddyfile` for a per-app route, or
set `tier=compose` for a stateless application to get the caddy ingress.
Those bypass the contract. See SKILL.md §5 for the why.

### "View an application's logs"
```bash
kubectl logs -n apps -l app=<app-name> --tail 200 --all-containers
kubectl logs -n apps <pod> -f
```

### "cloudflared is not connecting"
```bash
docker logs cloudflared --tail 100   # look for "Registered tunnel connection"
# Common: token expired, DNS not propagated, CF degraded
docker compose -f core/compose/docker-compose.yml restart cloudflared
```

### "Switch the Docker registry"
1. Pick a different value for `REGISTRY_PLUGIN` in `.env`
   (currently: `self-hosted`, `aliyun-acr`)
2. Fill the plugin's required env (preflight will tell you which)
3. Re-run `bash bootstrap.sh` — idempotent
4. Existing image tags in the old registry are NOT migrated; rebuild.

### "Add a new git provider plugin (beyond Gitee/GitHub/GitLab)"
1. `cp -r plugins/git-provider/gitee plugins/git-provider/<new-name>`
2. Edit `manifest.yaml` to map the new provider's payload into the
   pipeline's expected params (`repo-url`, `repo-name`, `branch`, etc.)
3. Implement signature verification in the EventListener interceptor —
   Tekton has built-ins for `github`; for plain-token providers, follow
   the `gitee` CEL pattern; for HMAC providers, use the `bitbucket-server`
   pattern.
4. Update `preflight.sh` and `README.md`. Add `tests/plugins/<name>.bats`.

## 8. Out of scope (don't propose)

- Production HA / multi-node / backup-restore (intentionally not the goal)
- GPU pass-through (out of scope for v0.1)
- cert-manager / ACME (TLS lives at Cloudflare edge)
- In-cluster stateful services (Postgres etc. stay in Compose)
- New top-level languages beyond `en` and `zh-CN` for v0.1 (deferred to v0.2 — see TODOS)
- Modifying k3s control plane args (e.g. `--disable=traefik`) without
  explicit user approval

## 9. Context links

- Roadmap of deferred items: `TODOS.md`
- Each plugin README under `plugins/<kind>/<name>/`
- Test plan and schema lock: `tests/`
