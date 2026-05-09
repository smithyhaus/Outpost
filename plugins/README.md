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
├── test-runner/            ← Phase 9 (test gate)
│   ├── testkube/           ← built-in default — K8s-native, 30+ engines
│   └── catalog-tasks/      ← lightweight; Tekton Catalog per-language
├── rollout/                ← Phase 9 (auto-rollback)
│   └── argo-rollouts/      ← built-in default
└── notification/           ← Phase 9 (multi-channel alerts)
    ├── dingtalk/
    ├── feishu/
    ├── wecom/
    └── webhook-generic/
```

## Plugin contract

Every plugin directory **must** contain:

| File              | Purpose                                                    | Required |
|-------------------|------------------------------------------------------------|----------|
| `plugin.yaml`     | Metadata (kind, name, required env, description)           | yes      |
| `manifest.yaml`   | Kubernetes manifests (uses `${VAR}` envsubst placeholders) | one of   |
| `compose.yaml`    | Docker Compose snippet (uses `${VAR}` placeholders)        | manifest |
|                   |                                                            | / compose |
| `preflight.sh`    | Validates required env vars are set                        | yes      |
| `README.md`       | What it does, when to use it, what it costs                | yes      |
| `values.example`  | Sample values / annotated env block                        | optional |

`bootstrap.sh` selects exactly one plugin per kind based on `.env`. Some
kinds (notification) accept a comma-separated list — fan out to multiple
channels.

```env
REGISTRY_PLUGIN=self-hosted
GIT_PROVIDER_PLUGIN=gitee
TEST_RUNNER=testkube
ROLLOUT_PLUGIN=argo-rollouts
NOTIFICATION_PROVIDERS=dingtalk,feishu       # comma-list, optional
```

The selected plugin's `manifest.yaml` is rendered through `render_template`
(see `platform/lib/portable.sh`) and applied — placeholders that fail to
resolve abort the install instead of silently producing broken output.

## Authoring a new plugin

1. Pick a kind (`registry`, `git-provider`, `test-runner`, `rollout`, `notification`, or future: `tunnel`)
2. Create `plugins/<kind>/<name>/` with the contract files above
3. List required env in `plugin.yaml` and validate them in `preflight.sh`
4. Document the plugin in `README.md` (English; add `README.zh-CN.md` if you can)
5. Add a smoke test entry in `tests/bats/<kind>-plugins.bats`
6. Open a PR — see `CONTRIBUTING.md`

### Notification plugin extra files

Notification plugins additionally contribute install-time fragments that
bootstrap merges into ArgoCD's notifications config:

| File                        | Purpose |
|-----------------------------|---------|
| `argocd-cm-fragment.yaml`   | Lines under `data:` of `argocd-notifications-cm` (services + templates) |
| `argocd-secret-fragment.yaml` | Lines under `stringData:` of `argocd-notifications-secret` (URL keys) |

Both fragments are 2-space-indented. bootstrap concatenates them onto a base
template and applies once, so the resulting CM/Secret carries entries for
every enabled provider.

Built-in plugins are the reference implementation. When in doubt, copy
`plugins/registry/self-hosted/` and modify.
