# Plugin system

Outpost uses a **directory-based plugin model**. Each plugin kind has its
own subdirectory; each plugin is a self-contained directory with a fixed shape.

## Directory shape

```
plugins/
├── registry/
│   ├── self-hosted/      ← built-in default
│   └── aliyun-acr/
└── git-provider/
    ├── gitee/            ← built-in default
    ├── github/
    └── gitlab/
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

`bootstrap.sh` selects exactly one plugin per kind based on `.env`:

```env
REGISTRY_PLUGIN=self-hosted
GIT_PROVIDER_PLUGIN=gitee
```

The selected plugin's `manifest.yaml` is rendered through `render_template`
(see `platform/lib/portable.sh`) and applied — placeholders that fail to
resolve abort the install instead of silently producing broken output.

## Authoring a new plugin

1. Pick a kind (`registry`, `git-provider`, future: `tunnel`)
2. Create `plugins/<kind>/<name>/` with the contract files above
3. List required env in `plugin.yaml` and validate them in `preflight.sh`
4. Document the plugin in `README.md` (English; add `README.zh-CN.md` if you can)
5. Add a smoke test entry in `tests/plugins/<kind>-<name>.bats`
6. Open a PR — see `CONTRIBUTING.md`

Built-in plugins are the reference implementation. When in doubt, copy
`plugins/registry/self-hosted/` and modify.
