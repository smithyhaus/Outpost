---
name: outpost
description: |
  Operating skill for the Outpost dev backend project. Two-layer
  architecture: Docker Compose for the public-ingress edge + k3s for
  stateful data services, applications, and CI/CD (GitHub Actions
  self-hosted runner + manifest-sync CronJob), fronted by a single
  Cloudflare Tunnel. Plugin-driven (registry, git-provider, test-runner,
  rollout, notification). Targets macOS / Linux / WSL2.
when_to_use: |
  Any operation inside an Outpost checkout — verifying health,
  diagnosing failures, onboarding a new project, modifying configuration,
  authoring a new plugin, or answering user questions about this stack.
---

# Outpost — operating skill

## 1. Identity

- **Type:** single-machine self-hosted dev backend.
- **Carriers:** Docker Compose (edge: cloudflared + caddy; `local` mode
  also carries the data layer) + k3s (`full`-mode data layer, apps,
  CI/CD glue).
- **CI:** GitHub Actions self-hosted runner (host systemd service, pure
  outbound long-poll — no inbound webhook anywhere).
- **CD:** `manifest-sync` CronJob (ns `outpost-ci`) — pulls the manifest
  repo, applies changed apps, waits for rollout, writes a heartbeat.
- **Public ingress:** Cloudflare Tunnel only — no public IP / port forward.
- **Plugin model:** directory-based, one plugin per kind, swap via `.env`.
- **Platforms:** macOS, Linux, Windows 11 + WSL2. OS-specific bits live in
  `platform/<os>.sh`; everything else is portable. The runner and
  `outpost-verify.timer` require `systemd` (Linux/WSL2 only).
- **Two modes** (`OUTPOST_MODE` in `.env`):
  - `local` *(default)* — Compose data services on `localhost` only. No CF
    Tunnel, no k3s, no CI/CD. Zero required input.
  - `full` — k3s data layer + Cloudflare Tunnel + GitHub Actions
    self-hosted runner + manifest-sync CD. Requires `ROOT_DOMAIN`,
    `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`, `MANIFEST_REPO_URL`,
    `GITHUB_RUNNER_URL`, `GITHUB_RUNNER_PAT`, `OUTPOST_REPOS`.

## 2. Architecture

```
Cloudflare edge (HTTPS / TLS)
    │
    ▼
cloudflared (Compose container, `edge` profile)
    ├─→ caddy:80 ─→ per-app routes (tier=compose apps, via `outpost onboard`)
    └─→ host.docker.internal:30080 ─→ k3s Traefik
                                         ├─ search.*       → manticore (IngressRoute)
                                         ├─ mq.*           → rabbitmq mgmt (IngressRoute)
                                         ├─ registry.*     → docker-registry
                                         └─ *.<root>       → user apps (catch-all)
                                            (apps named `<x>-apps.<root>`,
                                             one-level FQDN → free Universal SSL)

Host (outside both Compose and k3s):
  GitHub Actions self-hosted runner (systemd) → long-polls api.github.com
    → scripts/ci/build-image.sh (buildctl via 127.0.0.1:30750 buildkitd
      NodePort) → scripts/ci/run-tests.sh → scripts/update-manifest.sh
  outpost-verify.timer (systemd, 30min) → verify.sh --quiet → notify on FAIL
```

**Layer boundaries in v0.3.0:**
- Compose (`edge` profile) is ingress-only in `full` mode: `cloudflared` +
  `caddy`. `local` mode additionally carries the whole data layer in
  Compose (`local-data` profile) — no k3s at all.
- k3s carries the `full`-mode data layer (`infra-bridges` StatefulSets),
  stateless apps, and the CI/CD glue (`outpost-ci` namespace).
- Apps reach the data layer via ordinary in-cluster Service DNS in
  `infra-bridges` — no bridge/`ExternalName` indirection anymore
  ([ADR-0004](docs/decisions/0004-data-layer-in-k3s.md)):

```
postgres.infra-bridges.svc.cluster.local       → StatefulSet postgres:5432
redis.infra-bridges.svc.cluster.local          → StatefulSet redis:6379
rabbitmq.infra-bridges.svc.cluster.local       → StatefulSet rabbitmq:5672
manticore.infra-bridges.svc.cluster.local      → StatefulSet manticore:9308 (HTTP)
manticore.infra-bridges.svc.cluster.local      → StatefulSet manticore:9306 (SQL)
```

Apps reference these DNS names. To migrate to managed cloud services in
production, swap the Service to `ExternalName` — application code stays
unchanged either way.

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
| CI/CD engine (RBAC, PVC, sync CronJob, NodePorts) | `core/k8s/03-ci/` |
| Buildkitd (do-not-modify, quenched) | `core/k8s/08-buildkit/` |
| Bridge services (data layer StatefulSets, `full` mode) | `core/k8s/06-bridges/` |
| GitHub Actions workflow template | `templates/github/outpost-build.yml` |
| Host-run CI scripts (build/test/publish) | `scripts/ci/` |
| In-cluster manifest-sync script | `scripts/sync/manifest-sync.sh` |
| Repo-name → `apps/<dir>` mapping (shared by verify.sh + sync) | `scripts/lib/manifest-map.sh` |
| Runner + verify-timer systemd units | `platform/systemd/` |
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

1. **Traefik exposes NodePort 30080**. cloudflared depends on it.
2. **TLS is terminated at the Cloudflare edge.** Internal traffic is plain
   HTTP. Do not introduce cert-manager / ACME unless you also rip out the
   Cloudflare Tunnel pattern.
3. **Bridge services live in `infra-bridges` namespace.** App connection
   strings depend on this DNS name; renaming pollutes every app config.
4. **The manifest repo is the enforced source of truth for `apps`, via
   `manifest-sync`.** There is no self-heal loop — `kubectl apply` outside
   this flow doesn't get reverted automatically, but it silently drifts
   from the declared source and gets clobbered the next time that app's
   manifest changes. Modify the manifest repository, not the live cluster.
5. **`sync-heartbeat` (ConfigMap, ns `outpost-ci`) freshness is a hard
   signal.** `last_sync_ts` older than 3× `MANIFEST_SYNC_INTERVAL` means
   deploys have stopped — treat as FAIL, not a warning.
6. **The GitHub Actions runner is outbound-only.** No inbound port, no
   webhook secret, nothing to open in a firewall. Never reintroduce an
   inbound webhook path without a very deliberate ADR-level decision (see
   [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)).
7. **The deploy/rollback hot path must stay fully domestic** (gitee +
   local cluster) — it must keep working when github.com or the outbound
   proxy is down. Never make `outpost rollback`, `manifest-sync`, or
   `update-manifest.sh` depend on GitHub reachability.
8. **`.env` and `INFRA*.md` must never be committed.** Listed in .gitignore;
   plaintext secrets leaking equals total compromise. `GITHUB_RUNNER_PAT`
   is never echoed/logged — mask it in any diagnostic output.
9. **Self-hosted registry traffic is plain HTTP** at the cluster level
   (containerd is configured with `insecure_skip_verify`). Do not add a
   registry-side TLS cert — public TLS is at the CF edge.
10. **`render_template` (in `platform/lib/portable.sh`) MUST detect
    unresolved `${VAR}` placeholders and abort.** This is the central
    anti-silent-failure guardrail. Bypassing it (e.g. with raw envsubst)
    risks deploying manifests with empty hostnames or missing secrets.
11. **`OUTPOST_MODE` gates k3s/CI phases.** When `local`, bootstrap.sh
    exits after the Compose phase; verify.sh skips k8s/CI/edge sections
    and emits `summary.mode="local"`. Don't `kubectl apply` from bootstrap
    or expect bridge services / the runner in local mode.
12. **`OUTPOST_REPOS` is the reconciliation basis.** An app repo that
    builds and deploys but isn't registered in `OUTPOST_REPOS` is
    invisible to `verify.sh`'s anti-silence reconciliation layer — always
    register via `outpost onboard`, never hand-edit around it.
13. **`08-buildkit/`, `07-verdaccio/` and `update-manifest.sh`'s retry
    logic are quenched — do not modify.** They carry hard-won hardening
    (ACR-safe push, path-traversal guards, the 6-attempt jittered push
    retry) ported forward unchanged across the v0.3.0 engine swap.

## 5. Operating principles

### Default behaviours
- Read before modifying. Don't assume from filename — open the file.
- Read-only commands (`kubectl get`, `docker ps`, `verify.sh`) require no
  permission.
- Mutating operations (`kubectl apply`, `docker compose down`, edits to
  `.env`) require explicit user assent unless instructed otherwise.
- **Never** run `reset.sh` unless the user said "reset" or "wipe everything".
  In `full` mode this now touches live application data (data layer moved
  into k3s, ADR-0004) — dump-first discipline applies; see
  `docs/prp/runbooks/wsl2-redeploy-0.3.md`.
- **Never** delete the namespaces `infra-bridges`, `outpost-ci`, `buildkit`,
  `registry`, `kube-system`. They are load-bearing.

### Diagnosis order (cheap → expensive)
1. `bash verify.sh --json` (whole stack, ~5–10s — the reconciliation +
   liveness checks that catch a dead CI/CD chain from outside it)
2. `kubectl get pods -A | grep -v Running` (find sick pods)
3. `kubectl describe pod -n <ns> <pod>` (event log)
4. `kubectl logs -n <ns> <pod> --tail 100`
5. `docker logs <container> --tail 100` (Compose edge layer)
6. `journalctl -u actions.runner.* -n 200` (runner-side build issues)
7. Consult `i18n/en/docs/06-troubleshooting.md`
8. Ask the user, with a specific question and what you've tried.

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
*.<ROOT_DOMAIN>           <prefix>.<ROOT_DOMAIN>      search/mq/registry.<ROOT_DOMAIN>
broad CF wildcard         top-level (per-svc CF rule) top-level (per-svc CF rule)
(catches everything)
      |                          |                          |
      v                          v                          v
  k3s Traefik                Caddy :80                  k3s Traefik
      |                          |                          |
      v                          v                          v
  STATELESS APPS             STATEFUL INFRA            BUILT-IN SERVICES
  named `<x>-apps.<root>`    SIDECARS (tier=compose)   (manticore / rabbitmq /
  (tier=k3s)                 (app-onboarded services)   registry — IngressRoute,
                                                          core/k8s/06-bridges/,
                                                          NOT Caddy)
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
   end-to-end (manifest repo files, SealedSecret, `outpost.build.yaml` /
   CI workflow). Reuse `examples/demo-app/` as the manifest template.

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
- `git-provider` plugins are a **credential + `git ls-remote` preflight**
  contract in v0.3.0 — no `trigger.yaml`, no webhook wiring. `preflight.sh`
  must run a real authenticated `git ls-remote` against matching
  `OUTPOST_REPOS` hosts and fail loudly on bad credentials.
- `notification` plugins feed `scripts/notify-fanout.sh` events
  (`build-failed`, `deploy-succeeded`, `deploy-failed`, `verify-failed`) —
  no ArgoCD notification fragments anymore.
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
kubectl get cronjob -n outpost-ci manifest-sync
kubectl get configmap sync-heartbeat -n outpost-ci -o yaml
kubectl get jobs -n outpost-ci -l app=manifest-sync --sort-by=.metadata.creationTimestamp | tail -5

# Bridges (data layer, full mode — real in-cluster pods now)
kubectl get pods -n infra-bridges
kubectl get svc -n infra-bridges

# CI (host side)
systemctl status 'actions.runner.*'
journalctl -u 'actions.runner.*' -n 100
systemctl status outpost-verify.timer

# Public ingress (when ROOT_DOMAIN is real)
curl -sS -o /dev/null -w "%{http_code}\n" "https://registry.${ROOT_DOMAIN}"
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
There's no webhook to check anymore — walk the actual chain instead:
1. Is the repo in `OUTPOST_REPOS`? (`outpost onboard` registers it; a
   push from an unregistered repo is invisible to reconciliation.)
2. Did it reach github.com? Both remotes need the commit — check dual-push
   output in the dev terminal, or the gitee→github mirror status.
3. GitHub Actions UI on the app repo → did the workflow run, and what step
   failed? Or: `journalctl -u actions.runner.* -n 200` on the runner host.
4. Did `update-manifest.sh` land the commit in the manifest repo? Check the
   manifest repo's recent commits.
5. `outpost logs sync` — did `manifest-sync` pick it up and apply it?
6. `bash verify.sh --json` — the reconciliation check (`reconcile.*`) will
   name the repo if live HEAD and deployed tag disagree past
   `OUTPOST_STALENESS_THRESHOLD`.

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

### "Roll back a bad deploy"
`outpost rollback <app> [sha]` — lists the registry tags for `<app>` (last
`OUTPOST_REGISTRY_KEEP_TAGS`, default 10), then rewrites the manifest repo
to the chosen `sha` through the same `update-manifest.sh` code path
`scripts/ci` uses, and waits for `manifest-sync` to converge (≤2 sync
intervals). Fully domestic — works even when github.com is unreachable.

**Break-glass warning:** `kubectl rollout undo` still works directly
against the cluster, but it is a break-glass escape hatch, not a normal
rollback path. Because the manifest repo is the enforced source of truth
and there is no self-heal loop, a `rollout undo` NOT paired with a
manifest-repo revert will be silently overwritten on the next
`manifest-sync` tick that touches that app — the sync putting the "wrong"
(but manifest-declared) image back is the system working as designed, not
a bug. Always pair a `rollout undo` with `outpost rollback` (or a manual
manifest revert) in the same incident.

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
2. Edit `preflight.sh` to run an authenticated `git ls-remote` against the
   new provider's host, using its credential shape (token-in-URL, SSH key,
   etc.) — this is the entire "wiring" a git-provider plugin does in
   v0.3.0, no webhook signature verification needed anywhere.
3. Document the clone-URL shape the plugin expects in `README.md` (it must
   match what operators will put in `OUTPOST_REPOS`).
4. Update `preflight.sh` and `README.md`. Add `tests/plugins/<name>.bats`.

## 8. Out of scope (don't propose)

- Production HA / multi-node / backup-restore (intentionally not the goal)
- GPU pass-through
- cert-manager / ACME (TLS lives at Cloudflare edge)
- Automated StatefulSet volume snapshots / backups for the data layer
  (single-node/single-operator scope — see ADR-0004; manual dump-first
  discipline is the current answer)
- Reintroducing an inbound webhook path (see ADR-0003 — this was tried,
  and repeatedly failed silently)
- New top-level languages beyond `en` and `zh-CN` (see TODOS)
- Modifying k3s control plane args (e.g. `--disable=traefik`) without
  explicit user approval

## 9. Context links

- Roadmap of deferred items: `TODOS.md`
- Each plugin README under `plugins/<kind>/<name>/`
- Test plan and schema lock: `tests/`
