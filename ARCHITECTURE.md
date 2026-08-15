# Architecture

Outpost is a two-layer self-hosted dev backend, designed so that the
**stateful infrastructure** and **applications + CI/CD** are decoupled and
swappable. As of v0.3.0, both layers live in-cluster (`full` mode) or as
pure Compose (`local` mode) — see [ADR-0004](docs/decisions/0004-data-layer-in-k3s.md)
for why the data layer moved off the `host.docker.internal` bridge.

## High-level diagram

```
                        Cloudflare edge (TLS terminated)
                                       │
                                       ▼
                         cloudflared  (single Tunnel; egress-only)
                                       │
                    ┌──────────────────┼──────────────────────────┐
                    │                  │                          │
                    ▼                  ▼                          ▼
          ┌──────────────────┐  ┌────────────┐        ┌────────────────────┐
          │ Compose (edge)   │  │ caddy:80   │        │  127.0.0.1:30080    │
          │                  │  │ (app-team  │        │  (k3s Traefik       │
          │ cloudflared      │  │  onboarded │        │   NodePort)         │
          │ caddy            │  │  compose   │        │                     │
          └──────────────────┘  │  routes)   │        │  registry.*  → OCI  │
                                 └────────────┘        │  search.*    → IR   │
                                                        │  mq.*        → IR   │
                                                        │  *.<domain>  → apps │
                                                        │  (k3s namespace     │
                                                        │   `apps`)           │
                                                        └──────────┬──────────┘
                                                                   │
                                          ┌────────────────────────┼───────────────────────┐
                                          │                        │                        │
                                          ▼                        ▼                        ▼
                                 ┌────────────────┐    ┌────────────────────┐   ┌──────────────────┐
                                 │ infra-bridges   │    │  outpost-ci         │   │  buildkit /       │
                                 │ (StatefulSets)  │    │  manifest-sync      │   │  registry          │
                                 │                 │    │  CronJob            │   │                    │
                                 │ postgres:5432   │    │  (git pull → apply  │   │  buildkitd (NodePort│
                                 │ redis:6379      │    │   -k → rollout wait │   │  30750 for the host │
                                 │ rabbitmq:5672   │    │   → heartbeat CM)   │   │  runner)             │
                                 │ manticore:9308  │    │                     │   │  registry (NodePort  │
                                 │ (local-path PVC,│    │  ServiceAccount     │   │  30500 for the host  │
                                 │  Retain policy) │    │  outpost-sync       │   │  runner + CLI)       │
                                 └────────────────┘    │  (apply rights,     │   └──────────────────┘
                                                        │   no cluster-admin) │
                                                        └────────────────────┘

                Host (WSL2/Linux/macOS)
                ┌──────────────────────────────────────────────────────────┐
                │ GitHub Actions self-hosted runner (systemd, org-level)   │
                │   long-polls api.github.com (outbound only, proxy-aware) │
                │   → checkout → scripts/ci/build-image.sh (buildctl via  │
                │     127.0.0.1:30750) → scripts/ci/run-tests.sh (Gate A) │
                │     → scripts/update-manifest.sh (gitee manifest repo)  │
                │                                                          │
                │ outpost-verify.timer (systemd, 30min) → verify.sh       │
                │   --quiet → notify-fanout on FAIL (outside cluster + CI)│
                └──────────────────────────────────────────────────────────┘
```

## Why two layers

| Layer | Purpose | Lifetime expectations |
|-------|---------|----------------------|
| Compose | Public ingress edge (`cloudflared` + `caddy`); `local`-mode data layer. | Long-lived. Rare upgrades. |
| k3s | Stateful data layer (`full` mode) + stateless apps + CI/CD glue. State is rebuildable from manifests + PVC snapshots + the container registry. | Short-lived except the data PVCs. Frequent app rollouts. |

This split has three concrete benefits:

1. **You can blow away the app-facing pieces of k3s and rebuild them
   without losing data.** Apps are defined declaratively in the manifest
   repo; `manifest-sync` recreates them. Data StatefulSets keep their PVCs
   (`Retain` policy) across a `reset.sh` unless explicitly told otherwise.
2. **Production migration is easy.** Swap a bridge Service's selector for
   an `ExternalName` pointing at managed Postgres / Redis / RabbitMQ;
   application connection strings are unchanged either way.
3. **Operational scope is contained.** `local` mode needs nothing beyond
   Docker; `full` mode's data layer is an ordinary single-node
   `StatefulSet` + `local-path` PVC — no multi-node volume complexity.

## Bridge services (the load-bearing piece)

The data layer is reached through Services in the `infra-bridges`
namespace — same DNS names as always, now backed by real in-cluster pods
instead of a `host.docker.internal` bridge:

```
postgres.infra-bridges.svc.cluster.local       → StatefulSet postgres:5432
redis.infra-bridges.svc.cluster.local          → StatefulSet redis:6379
rabbitmq.infra-bridges.svc.cluster.local       → StatefulSet rabbitmq:5672
manticore.infra-bridges.svc.cluster.local      → StatefulSet manticore:9308 (HTTP)
manticore.infra-bridges.svc.cluster.local      → StatefulSet manticore:9306 (SQL)
```

Apps reference the K8s DNS names, never a host address directly. To move to
managed cloud services in production, change ONLY the Service's selector
(or type) to `ExternalName` — application connection strings stay
identical. See [ADR-0001](docs/decisions/0001-two-layer-split.md) (and its
amendment, [ADR-0004](docs/decisions/0004-data-layer-in-k3s.md)) for the
full rationale.

`local` mode is unaffected: it stays pure Compose (`local-data` profile) —
no k3s required at all.

## Public ingress (single Cloudflare Tunnel)

A single `cloudflared` container in Compose (`edge` profile) carries all
ingress, forking to either the Compose `caddy` container (app-team
onboarded Compose services) or the k3s Traefik NodePort (everything else):

| Subdomain            | Type | Backend                                                              |
|-----------------------|------|-----------------------------------------------------------------------|
| `<app>.<domain>` (Compose apps) | HTTP | `caddy:80` → `Caddyfile.d/<app>.caddy` (via `outpost onboard`, tier=compose) |
| `mq.<domain>`          | HTTP | Traefik `IngressRoute` → `rabbitmq.infra-bridges` :15672 (`core/k8s/06-bridges/ingressroutes.template.yaml`) |
| `search.<domain>`      | HTTP | Traefik `IngressRoute` → `manticore.infra-bridges` :9308 |
| `registry.<domain>`    | HTTP | Traefik `IngressRoute` → in-cluster registry (`plugins/registry/self-hosted/manifest.yaml`) |
| `*.<domain>`           | HTTP | Traefik → k3s `apps` namespace (catch-all; apps named `<x>-apps.<domain>` by convention) |

v0.2's raw TCP tunnel rows (`pg.` / `redis.` / `rabbitmq.`) are gone: the
data layer is in-cluster ClusterIP-only now. For ad-hoc external access use
`kubectl -n infra-bridges port-forward svc/postgres 5432:5432` (optionally
fronted by a CF Dashboard TCP route pointing at the forwarded host port) —
nothing ships permanently exposed by default.

Cloudflare terminates TLS at the edge — internal traffic is plain HTTP.
The single `*.<domain>` wildcard avoids two-level subdomains so the free
Universal SSL `*.<domain>` certificate covers every app — a two-level
`*.apps.<domain>` would require paid Advanced Certificate Manager. This is
intentional and simplifies certificate management.

There is **no `hooks.<domain>` route, no `argocd.<domain>` route, no
`tekton.<domain>` route, no `rollouts.<domain>` route** — the inbound
webhook path and every in-cluster CI/CD dashboard are retired in v0.3.0
(see [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)).

## CI/CD pipeline

```
dev: git push
    (gitee = primary target; dual-push or gitee→github one-way
     push-mirror keeps a github copy in sync — github is CI-trigger-only)
    │
    ├──────────────────────────────► gitee (manifest repo lives here too;
    │                                        reconciliation baseline)
    │
    ▼
github.com receives the push → dispatches templates/github/outpost-build.yml
    │
    ▼
GitHub Actions self-hosted runner (host systemd service, org-level
registration, pure outbound long-poll — no inbound endpoint anywhere)
    │
    ├─ checkout (shallow)
    ├─ scripts/ci/build-image.sh
    │     buildctl → 127.0.0.1:30750 (buildkitd NodePort)
    │     push → in-cluster registry, tag = 7-char commit SHA
    │     (publish-type repos route to scripts/ci/publish-npm.sh instead)
    ├─ scripts/ci/run-tests.sh
    │     Gate A: outpost.test.yaml / Dockerfile.test — opt-in, clean no-op
    │     when neither is present
    ├─ scripts/update-manifest.sh
    │     clone gitee manifest repo, yq-patch the image tag, push
    │     (6-attempt jittered retry — cross-repo workflow concurrency
    │      still exists even with a single runner)
    │
    └─ on any-step failure → notify-fanout.sh build-failed
    │
    ▼
manifest-sync CronJob (ns outpost-ci, every MANIFEST_SYNC_INTERVAL minutes,
concurrencyPolicy: Forbid — single writer, never overlaps itself)
    │
    ├─ git pull manifest repo (gitee)
    ├─ kubectl apply -k <changed apps>
    ├─ rollout-wait (kind:Rollout aware — waits on Argo Rollouts' own
    │   status when ROLLOUT_PLUGIN=argo-rollouts, else Deployment rollout)
    ├─ write sync-heartbeat CM: last_sync_ts / applied_head / last_result
    └─ notify-fanout.sh deploy-succeeded / deploy-failed
    │
    ▼
App reachable at <app>-apps.<domain>
```

Five implications worth understanding:

- **No webhook, anywhere.** github.com dispatches the workflow to the
  runner via the runner's own outbound long-poll; the runner never accepts
  an inbound connection. `manifest-sync` never accepts one either — it
  polls on a k8s CronJob schedule.
- **Image tag is a 7-char commit short-SHA**, not `latest`. Rollback =
  `outpost rollback <app> [sha]` (rewrites the manifest via the same
  `update-manifest.sh` code path) or a manifest-repo git revert;
  `kubectl rollout undo` also works as a break-glass, but MUST be paired
  with a manifest revert or the next sync tick reverts it back (the
  manifest repo being the enforced source of truth is a feature).
- **The `apps` namespace is owned by the manifest repo, via
  `manifest-sync`.** Don't `kubectl apply` to it directly — the next sync
  tick will not revert your change automatically (there is no ArgoCD
  self-heal loop anymore), but it also won't be reflected in the manifest
  repo, so it silently drifts from the declared source of truth and will
  be clobbered the next time that app's manifest changes. The namespace
  still carries a `ResourceQuota` (30 pods / 4 req-cpu / 8Gi req-mem) and a
  `LimitRange` (default 1cpu/512Mi, max 4cpu/8Gi per container) so a
  runaway app can't pin the host.
- **Gate A is opt-in.** Repos without `outpost.test.yaml` or
  `Dockerfile.test` skip it cleanly. Gate B (progressive delivery via Argo
  Rollouts) is opt-in at the plugin level (`ROLLOUT_PLUGIN=argo-rollouts`,
  default `none`, controller-only — no dashboard).
- **No in-cluster CI/CD dashboard.** Build status: GitHub Actions UI, or
  `journalctl -u actions.runner.*` on the runner host. Deploy status:
  `outpost status` (sync-heartbeat summary) or `outpost logs sync`
  (latest manifest-sync Job logs).

## Anti-silent-failure: three independent layers

The single biggest recurring incident class pre-v0.3 was a link in the
push→build→deploy chain going quietly dark (a 9-day silent webhook outage
being the worst instance — see
[ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)). v0.3.0
answers this with three layers that each judge the chain from *outside*
the part of it they're checking:

1. **Reconciliation (`verify.sh`, the ultimate judge).** For every
   `OUTPOST_REPOS` entry, an authenticated `git ls-remote` gets the *live*
   branch head and compares it against the image tag actually deployed for
   that app in the manifest repo. A mismatch persisting past
   `OUTPOST_STALENESS_THRESHOLD` (default 1800s) is FAIL, naming the repo —
   this catches a dead gitee→github mirror, GitHub being unreachable, the
   runner being offline, a red workflow, a dead buildkitd, or a stalled
   sync CronJob, because all of those manifest as exactly this symptom:
   live code that never became a deployed tag.
2. **Liveness checks.** Runner systemd unit active + `GITHUB_RUNNER_PAT`
   authenticated `curl` against the GitHub API confirming an online runner
   (API unreachable = FAIL "CI trigger path down" when the PAT is set;
   WARN "runner not configured" when it's empty) + `sync-heartbeat` age
   beyond 3× `MANIFEST_SYNC_INTERVAL` = FAIL + real TCP/auth probes of all
   four data services.
3. **A host `systemd` timer** (`platform/systemd/outpost-verify.timer`,
   `OnBootSec=5min`, `OnUnitActiveSec=30min`, `Persistent=true`) runs
   `verify.sh --quiet` and fans FAIL out through `notify-fanout.sh` — this
   detector lives outside both the cluster and GitHub, so it keeps
   reporting even if either of those is the thing that died.

## Plugin model

Four pluggable seams in v0.3.0 (`rollout` is now controller-only, no
dashboard tier; the old `test-runner/catalog-tasks` Tekton-catalog plugin
is removed):

```
plugins/
├── registry/                 ← image registry
│   ├── self-hosted/          ← in-cluster Docker Registry v2 (default)
│   └── aliyun-acr/           ← Alibaba Cloud Container Registry
├── git-provider/             ← credential + git ls-remote preflight contract
│   ├── gitee/                ← (default)
│   ├── github/
│   └── gitlab/
├── test-runner/              ← Gate A pre-deploy testing
│   └── testkube/             ← K8s-native, 30+ engines (default)
├── rollout/                  ← opt-in progressive delivery + auto-rollback
│   └── argo-rollouts/        ← controller-only, default OFF (ROLLOUT_PLUGIN=none)
└── notification/             ← CI/sync/verify event fan-out
    ├── dingtalk/              ← signed webhook
    ├── feishu/                ← signed webhook
    ├── wecom/                 ← URL-secret only
    └── webhook-generic/       ← raw JSON to your collector
```

**v0.3 change: the inbound-webhook path is gone.** Pre-v0.3, `git-provider`
plugins wired a provider's push webhook into a Tekton EventListener, and
`notification` plugins fed `argocd-notifications-cm`/`-secret`. Both
ArgoCD and Tekton are removed. `git-provider` plugins are now a
**credential + host-matching contract**: `preflight.sh` runs a real
authenticated `git ls-remote` against every `OUTPOST_REPOS` entry whose
host matches the plugin, failing loudly on bad credentials *before*
bootstrap finishes rather than discovering it the first time a build
should have fired. `notification` plugins feed three events instead of
ArgoCD's notification triggers: `build-failed` (workflow),
`deploy-succeeded`/`deploy-failed` (sync job), `verify-failed` (the
systemd timer) — all through `scripts/notify-fanout.sh`.

Each plugin contains:
- `plugin.yaml` — metadata + required env
- `manifest.yaml` (and/or `compose.yaml`) — what `bootstrap.sh` will apply
- `preflight.sh` — validates required env (and, for `git-provider`, live
  credentials) before apply
- `README.md` — what / when / why

Selectors in `.env` — each kind has its own:

```env
REGISTRY_PLUGIN=aliyun-acr
GIT_PROVIDER_PLUGIN=gitee,github      # comma-list — dual-provider is normal in v0.3
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=argo-rollouts          # default: none
NOTIFICATION_PROVIDERS=dingtalk,feishu      # comma-list, optional
```

Re-run `bash bootstrap.sh`. The plugin contract is documented in
[`plugins/README.md`](plugins/README.md). Test-gate design rationale:
[`i18n/en/docs/proposals/cicd-test-gate.md`](i18n/en/docs/proposals/cicd-test-gate.md).

## Cross-platform layering

OS-specific bits are isolated in `platform/<os>.sh`. Currently:

| Hook                            | macOS                          | Linux native            | WSL2                            |
|---------------------------------|--------------------------------|-------------------------|---------------------------------|
| `sk_install_docker`             | Check Docker Desktop           | `get.docker.com` script | inherits from Linux             |
| `sk_install_k3s`                | k3d (k3s in Docker)            | native k3s              | inherits from Linux             |
| `sk_setup_autostart`            | LaunchAgent                    | systemd                 | systemd + WSL `wsl.conf` advice |
| `sk_configure_registry_mirror`  | UI-only (Docker Desktop)       | writes daemon.json      | inherits from Linux             |
| `sk_print_post_install_notes`   | per-OS notes                   | per-OS notes            | per-OS + Windows Task Scheduler |

The GitHub Actions runner and `outpost-verify.timer` both require
`systemd`, so they're Linux/WSL2-only; macOS dev boxes run `verify.sh`
manually or via a LaunchAgent equivalent if desired.

Common shell helpers — including the central `render_template` function
that prevents silent envsubst failures — live in
[`platform/lib/portable.sh`](platform/lib/portable.sh).

## Anti-silent-failure: `render_template`

A frequent pain in shell-driven infra is `envsubst` quietly emitting empty
strings for unset variables. Manifests pass `kubectl apply` validation but
reference empty hostnames or missing secrets, producing puzzling failures
later.

`render_template`:

1. envsubst's the template
2. greps the output for any leftover `${VAR}` pattern
3. if any remain, deletes the output and exits with a clear error

Every manifest that has placeholders is rendered through this function.
This is invariant #10 in [`SKILL.md`](SKILL.md).

## Layer invariants

The core invariants — never break these:

- Compose (`edge` profile) exposes only `cloudflared` + `caddy`; app data
  no longer lives in Compose in `full` mode.
- Traefik exposes `NodePort 30080`; cloudflared depends on it.
- TLS terminates at the Cloudflare edge — internal traffic is plain HTTP.
- Bridge services live in `infra-bridges`; renaming pollutes app configs.
- **The manifest repo is the enforced source of truth for the `apps`
  namespace** — `manifest-sync` is the only writer that matters; a
  `kubectl apply` outside that flow silently drifts and gets clobbered on
  the next sync of that app.
- **`sync-heartbeat` freshness is a hard signal.** Any consumer relying on
  "deploys are working" must check `last_sync_ts` age, not just that the
  CronJob object exists.
- **The GitHub Actions runner is outbound-only.** No inbound port, no
  webhook secret, no firewall rule to open — if this ever changes, it
  breaks the entire threat model this architecture was chosen for.
- **The deploy/rollback hot path is fully domestic** (gitee + local
  cluster) and must keep working even when github.com or the outbound
  proxy is down — never introduce a deploy-path dependency on GitHub
  reachability.
- `.env` and `INFRA.md` never enter version control.
- Self-hosted registry traffic is HTTP at the cluster level; containerd
  is configured with `insecure_skip_verify`.

These are reproduced verbatim in [`SKILL.md`](SKILL.md) for AI-agent
consumption.

## Further reading

- [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md) — why
  Tekton + ArgoCD were replaced, and why GitHub Actions runner + manifest-
  sync over the alternatives that were evaluated (Drone, Woodpecker, Gitee
  Go, Gitea Actions).
- [ADR-0004](docs/decisions/0004-data-layer-in-k3s.md) — why the data
  layer moved into k3s for `full` mode.
- [`docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md`](docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md)
  — the full research artifact behind both ADRs.
