# Plugin system

Outpost uses a **directory-based plugin model**. Each plugin kind has its
own subdirectory; each plugin is a self-contained directory with a fixed shape.

## Directory shape

```
plugins/
├── registry/
│   ├── self-hosted/        ← built-in default
│   └── aliyun-acr/
├── git-provider/
│   ├── gitee/              ← built-in default
│   ├── github/
│   └── gitlab/
├── test-runner/            ← test gate (Gate A / Gate B)
│   └── testkube/           ← built-in default — K8s-native, 30+ engines
├── rollout/                ← opt-in canary + auto-rollback (default OFF)
│   └── argo-rollouts/      ← built-in default, controller-only
└── notification/           ← multi-channel CI/CD alerts
    ├── dingtalk/
    ├── feishu/
    ├── wecom/
    └── webhook-generic/
```

## v0.3 change: the inbound-webhook path is gone

Pre-v0.3, `git-provider` plugins wired a provider's push webhook into a
Tekton EventListener, and `notification` plugins fed ArgoCD's
`argocd-notifications-cm`/`-secret`. Both ArgoCD and Tekton are removed in
v0.3 (see `docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md`):

- CI is a **GitHub Actions self-hosted runner** — pure outbound long-poll,
  no inbound endpoint to configure or leak a shared webhook secret from.
- CD is a **manifest-sync CronJob** (ns `outpost-ci`) that pulls the
  manifest repo and applies changed apps.
- `git-provider` plugins are now a **credential + host-matching contract**:
  `preflight.sh` runs a real authenticated `git ls-remote` against every
  `OUTPOST_REPOS` entry whose host the plugin owns.
- `notification` plugins describe what the sync job / GitHub Actions
  workflow / `verify.sh` systemd timer consume (via `scripts/notify-fanout.sh`,
  either volume-mounted in-cluster or via its `--env-file` flag on the host).

## Plugin contract

Every plugin directory **must** contain:

| File              | Purpose                                                    | Required |
|-------------------|------------------------------------------------------------|----------|
| `plugin.yaml`     | Metadata (kind, name, required env, description)           | yes      |
| `manifest.yaml`   | Kubernetes manifests / data contract (uses `${VAR}` envsubst placeholders) | one of   |
| `compose.yaml`    | Docker Compose snippet (uses `${VAR}` placeholders)        | manifest |
|                   |                                                            | / compose |
| `preflight.sh`    | Validates required env vars are set (and, for `git-provider`, actually probes credentials) | yes      |
| `README.md`       | What it does, when to use it, what it costs                | yes      |
| `values.example`  | Sample values / annotated env block                        | optional |

`bootstrap.sh` selects one plugin per kind based on `.env`. Two kinds accept a
comma-separated list — `notification` (fan out to multiple channels) and
`git-provider` (each enabled provider's `preflight.sh` only probes the
`OUTPOST_REPOS` entries whose host it owns, so gitee + github + gitlab
coexist safely).

```env
REGISTRY_PLUGIN=self-hosted
GIT_PROVIDER_PLUGIN=gitee                     # or a comma-list: gitee,github,gitlab
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=none                           # opt-in: argo-rollouts
NOTIFICATION_PROVIDERS=dingtalk,feishu       # comma-list, optional
```

Manifest content (when present) is rendered through `render_template` (see
`platform/lib/portable.sh`) — placeholders that fail to resolve abort the
install instead of silently producing broken output. `git-provider`
plugins' `manifest.yaml` in v0.3 is a plain data contract (host +
credential-template), not a Kubernetes object — nothing is `kubectl apply`'d
for them anymore.

## Authoring a new plugin

1. Pick a kind (`registry`, `git-provider`, `test-runner`, `rollout`, `notification`, or future: `tunnel`)
2. Create `plugins/<kind>/<name>/` with the contract files above
3. List required env in `plugin.yaml` and validate them in `preflight.sh`
4. Document the plugin in `README.md` (English; add `README.zh-CN.md` if you can)
5. Add a smoke test entry in `tests/bats/<kind>-plugins.bats`
6. Open a PR — see `CONTRIBUTING.md`

### Per-kind required extras (beyond the universal contract)

As of v0.3 (plugin contract v2), **no kind ships extras beyond the
universal contract** — both prior extras were retired along with the
inbound-webhook path:

| Kind          | Retired extra (pre-v0.3)                            | Why it's gone |
|---------------|------------------------------------------------------|---------------|
| `notification`| `argocd-cm-fragment.yaml`, `argocd-secret-fragment.yaml` | ArgoCD removed — nothing left to merge into |
| `git-provider`| `trigger.yaml`                                     | Tekton EventListener removed — no inbound webhook to splice a Trigger into |

`tests/bats/plugin-contract-per-kind.bats` enforces both retirements (fails
loudly if either file reappears) and still has a place to declare a NEW
per-kind extra if a future kind needs one.

Built-in plugins are the reference implementation. When in doubt, copy
a plugin **of the same kind** you're authoring (e.g. copy
`plugins/notification/wecom/` to build a new notification plugin).
