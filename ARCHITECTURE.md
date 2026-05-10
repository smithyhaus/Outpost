# Architecture

Outpost is a two-layer self-hosted dev backend, designed so that the
**stateful infrastructure** and **applications + CI/CD** are decoupled and
swappable.

## High-level diagram

```
                        Cloudflare edge (TLS terminated)
                                       │
                                       ▼
                         cloudflared  (single Tunnel; egress-only)
                                       │
              ┌────────────────────────┼────────────────────────────┐
              │                        │                             │
              ▼                        ▼                             ▼
    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────────┐
    │   Compose        │    │ caddy:80         │    │ host.docker.internal │
    │   (data layer)   │    │ HTTP routing     │    │ :30080               │
    │                  │    │                  │    │ (k3s Traefik NodePort)│
    │ postgres:5432  ◄─┼────│                  │    │                       │
    │ redis:6379    ◄──┤    │ search.* → meili │    │  ArgoCD              │
    │ rabbitmq:5672 ◄──┤    │ mq.* → rabbitmq  │    │  Tekton + Dashboard  │
    │ rabbitmq:15672 ──┤    │                  │    │  Docker Registry     │
    │ meilisearch:7700 ┘    └──────────────────┘    │  Sealed-Secrets      │
    │                                                │  Testkube (Gate A/B) │
    │                                                │  Argo Rollouts       │
    │                                                │     + Dashboard      │
    │                                                │  *.apps.* → user apps│
    │                                                │                       │
    │                       ▲ (k3s pods reach        │                       │
    │                        data layer via         │                       │
    │                        host.docker.internal)  │                       │
    └──────────────────┘                            └──────────────────────┘
```

## Why two layers

| Layer | Purpose | Lifetime expectations |
|-------|---------|----------------------|
| Compose | Stateful data services. State is persisted in Docker volumes. | Long-lived. Rare upgrades. |
| k3s | Stateless apps + GitOps CI/CD. State is rebuildable from manifests + container registry. | Short-lived. Frequent rollouts. |

This split has three concrete benefits:

1. **You can blow away k3s and rebuild it without losing data.** Apps are
   defined declaratively in the manifest repo; ArgoCD recreates them.
2. **Production migration is easy.** Swap the bridge ExternalName Service to
   point at managed Postgres / Redis / RabbitMQ; application code unchanged.
3. **Operational scope is contained.** The data layer doesn't need K8s
   expertise to manage; the app layer doesn't need volume/PV expertise.

## Bridge services (the load-bearing piece)

The two layers communicate through ExternalName Services in the
`infra-bridges` namespace:

```
postgres.infra-bridges.svc.cluster.local       → host.docker.internal:5432
redis.infra-bridges.svc.cluster.local          → host.docker.internal:6379
rabbitmq.infra-bridges.svc.cluster.local       → host.docker.internal:5672
meilisearch.infra-bridges.svc.cluster.local    → host.docker.internal:7700
```

Apps reference the K8s DNS names, never `host.docker.internal` directly. To
move to managed cloud services in production, change ONLY the Service's
`spec.externalName` — application connection strings stay identical.

## Public ingress (single Cloudflare Tunnel)

A single `cloudflared` container in Compose carries all ingress:

| Subdomain                       | Type | Backend                                    |
|---------------------------------|------|--------------------------------------------|
| `pg.<domain>`                   | TCP  | `postgres:5432`                            |
| `redis.<domain>`                | TCP  | `redis:6379`                               |
| `rabbitmq.<domain>`             | TCP  | `rabbitmq:5672`                            |
| `mq.<domain>`                   | HTTP | `caddy:80` → `rabbitmq:15672`              |
| `search.<domain>`               | HTTP | `caddy:80` → `meilisearch:7700`            |
| `argocd.<domain>`               | HTTP | `host.docker.internal:30080` → ArgoCD      |
| `tekton.<domain>`               | HTTP | `host.docker.internal:30080` → Tekton Dashboard *(BasicAuth)* |
| `rollouts.<domain>`             | HTTP | `host.docker.internal:30080` → Argo Rollouts UI *(BasicAuth)* |
| `hooks.<domain>`                | HTTP | `host.docker.internal:30080` → Tekton EL   |
| `registry.<domain>`             | HTTP | `host.docker.internal:30080` → Registry    |
| `*.apps.<domain>`               | HTTP | `host.docker.internal:30080` → user apps   |

Cloudflare terminates TLS at the edge — internal traffic is plain HTTP.
This is intentional and simplifies certificate management.

## GitOps pipeline

```
git push (Gitee / GitHub / GitLab)
    │
    ▼
hooks.<domain>  (cloudflared → Traefik → Tekton EventListener)
    │
    ▼
Tekton PipelineRun (in tekton-pipelines namespace):
    ① git-clone        — fetch the app repo at the pushed commit
    ② kaniko build     — build a Docker image
    ③ kaniko push      — push to <REGISTRY>/<repo>:<short-sha>  (7-char SHA)
    ④ run-tests        — Gate A: outpost.test.yaml / Dockerfile.test
                          (no-ops cleanly when neither is present)
    ⑤ update-manifest  — clone manifest repo, yq-patch image tag, push
                          (with rebase-on-conflict retry)
    │ ── on any-task failure → finally:
    │     notify-on-failure → fan-out to NOTIFICATION_PROVIDERS
    │     (dingtalk / feishu / wecom / webhook-generic)
    ▼
ArgoCD watches the manifest repo
    │
    ▼
ArgoCD sync → kubectl apply
    │
    ├─→ Deployment    → rolling deploy (default)
    │
    └─→ Rollout (CRD) → canary 10/25/50/100 with AnalysisTemplate gates
                        (Gate B: Web HTTP probe / Job-running-Testkube)
                        failure → automatic rollback + notify
    │
    ▼
App reachable at <app>.apps.<domain>
```

Five implications worth understanding:

- **Tekton uses the EventListener** (one webhook URL handles all repos).
- **Image tag is a 7-char commit short-SHA**, not `latest`. Rollback =
  revert the manifest repo commit; `kubectl rollout undo` also works.
- **The `apps` namespace is owned by ArgoCD.** Don't `kubectl apply` to
  it directly — self-heal will revert your change. The namespace also
  carries a `ResourceQuota` (30 pods / 4 req-cpu / 8Gi req-mem) and a
  `LimitRange` (default 1cpu/512Mi, max 4cpu/8Gi per container) so a
  runaway app can't pin the host.
- **Gate A / Gate B are opt-in.** Repos without `outpost.test.yaml` or
  `Dockerfile.test` skip Gate A cleanly; apps that stay `Deployment`
  instead of `Rollout` skip Gate B. Either way the pipeline still works.
- **Tekton + Argo Rollouts dashboards live behind a single Traefik
  BasicAuth middleware** (`OUTPOST_DASHBOARD_USER` /
  `OUTPOST_DASHBOARD_PASSWORD`). Upgrade to Cloudflare Access for
  SSO/IdP at the edge.

## Plugin model

Five pluggable seams in v0.2:

```
plugins/
├── registry/                 ← image registry
│   ├── self-hosted/          ← in-cluster Docker Registry v2 (default)
│   └── aliyun-acr/           ← Alibaba Cloud Container Registry
├── git-provider/             ← webhook source
│   ├── gitee/                ← (default)
│   ├── github/               ← uses Tekton's HMAC interceptor
│   └── gitlab/               ← X-Gitlab-Token plain compare
├── test-runner/              ← Phase 9: pre/post-deploy testing
│   ├── testkube/             ← K8s-native, 30+ engines (default)
│   └── catalog-tasks/        ← lightweight; per-language Tekton catalog
├── rollout/                  ← Phase 9: progressive delivery + rollback
│   └── argo-rollouts/        ← canary + AnalysisTemplate (default)
└── notification/             ← Phase 9: fan-out failure alerts
    ├── dingtalk/             ← signed webhook
    ├── feishu/               ← signed webhook
    ├── wecom/                ← URL-secret only
    └── webhook-generic/      ← raw JSON to your collector
```

Each plugin contains:
- `plugin.yaml` — metadata + required env
- `manifest.yaml` (and/or `compose.yaml`) — what `bootstrap.sh` will apply
- `preflight.sh` — validates required env before apply
- `README.md` — what / when / why
- *(notification only)* `argocd-cm-fragment.yaml` +
  `argocd-secret-fragment.yaml` — concatenated by bootstrap into
  `argocd-notifications-cm` / `argocd-notifications-secret`

Selectors in `.env` — each kind has its own:

```env
REGISTRY_PLUGIN=aliyun-acr
GIT_PROVIDER_PLUGIN=github
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=argo-rollouts
NOTIFICATION_PROVIDERS=dingtalk,feishu      # comma-list, optional
```

Re-run `bash bootstrap.sh`. The plugin contract is documented in
[`plugins/README.md`](plugins/README.md). Phase 9 design rationale:
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

- Compose data services bind `0.0.0.0:<port>` so k3s pods can reach them.
- Traefik exposes `NodePort 30080`; cloudflared depends on it.
- TLS terminates at the Cloudflare edge; internal traffic is plain HTTP.
- ArgoCD server runs `--insecure` (HTTP) so Traefik's IngressRoute works.
- Bridge services live in `infra-bridges`; renaming pollutes app configs.
- The `apps` namespace is GitOps-owned (manifest repo, not `kubectl apply`).
- `.env` and `INFRA.md` never enter version control.
- Self-hosted registry traffic is HTTP at the cluster level; containerd
  is configured with `insecure_skip_verify`.

These are reproduced verbatim in [`SKILL.md`](SKILL.md) for AI-agent
consumption.
