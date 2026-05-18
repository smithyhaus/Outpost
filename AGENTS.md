# AGENTS.md

This file is the AI-agent on-ramp following the [agents.md](https://agents.md)
convention (Cursor / Cline / Aider / generic LLM coding tools). It points at
the canonical operating doc rather than duplicating it.

## Canonical source

Read **[`SKILL.md`](SKILL.md)** end-to-end. It is the single source of truth
for:

- Identity and platforms (macOS / Linux / WSL2; `local` and `full` modes)
- Architecture (two layers: Compose for stateful data, k3s for apps + GitOps)
- File pointer map (where every concern lives)
- Invariants you must not break (e.g. one Cloudflare Tunnel, ExternalName
  bridges, plugin contract files)
- Verification (`bash verify.sh --json`, `bash scripts/outpost status`)
- Common tasks and the right tool for each

If anything below contradicts `SKILL.md`, `SKILL.md` wins.

## The four facts every agent must know before touching code

1. **Two modes.** `OUTPOST_MODE=local` runs Compose data services only (PG /
   Redis / RabbitMQ / Meilisearch on `localhost`, zero required input).
   `OUTPOST_MODE=full` adds Cloudflare Tunnel + k3s + ArgoCD + Tekton GitOps
   and requires `ROOT_DOMAIN`, `CF_TUNNEL_TOKEN`, `GIT_USER`, `GIT_TOKEN`,
   `MANIFEST_REPO_URL`. Don't break the local-mode zero-prompt path.
2. **Plugin model.** Five kinds: `registry`, `git-provider`, `test-runner`,
   `rollout`, `notification`. Each plugin is a directory under
   `plugins/<kind>/<name>/` with a strict contract (see
   [`plugins/README.md`](plugins/README.md)). Per-kind contract enforced by
   `tests/bats/plugin-contract-per-kind.bats`. **Don't fork an upstream
   project to swap behavior — write a plugin.**
3. **No silent failures.** Every `${VAR}` in a rendered manifest must be set
   or `render_template` aborts (see `platform/lib/portable.sh`).
   `verify.sh --json` emits structured PASS/WARN/FAIL with a locked schema
   (`tests/schema/verify-output.schema.json`). Don't add a fallback that
   masks a real error — surface it.
4. **Tests first.** Logic that lives in `scripts/*.sh` has bats coverage in
   `tests/bats/*.bats`. The split is intentional: scripts are
   canonical-and-testable; ConfigMap-mounted into Tekton Tasks at run-time.
   When you change a script, run the corresponding bats. When you add new
   logic, add the bats first.

## Repo layout at a glance

```
bootstrap.sh              # orchestrator (60 lines); phases live in bootstrap.d/
bootstrap.d/              # one file per phase (preflight → summary)
core/compose/             # Compose stack (data services + tunnel + caddy)
core/k8s/                 # k3s manifests (ArgoCD, Tekton, bridges, dashboards)
platform/lib/             # portable.sh, registry-config.sh, cel-helpers.sh,
                          # eventlistener-assemble.sh, sign-webhook.sh
plugins/<kind>/<name>/    # plugin directories — copy a sibling of the same
                          # kind to scaffold (cross-kind copy trips the
                          # per-kind contract test)
scripts/                  # canonical scripts (outpost CLI, update-manifest,
                          # read-build-config, notify-fanout)
tests/bats/               # bats unit tests; tests/regression/ goldens
i18n/{en,zh-CN}/docs/     # user docs (kept in sync; CI flags drift)
TODOS.md                  # roadmap + per-item context
CHANGELOG.md              # Keep-a-Changelog format
```

## How to verify your change

```bash
bats tests/bats/                   # 142+ unit tests; should be all green
bats tests/regression/             # golden manifest snapshots
bash tests/lint.sh                 # shellcheck + yamllint + compose config
```

For an integration check on a real cluster:

```bash
bash bootstrap.sh                  # idempotent — safe to re-run
bash verify.sh --json | jq         # post-install health, AI-parseable
bash scripts/outpost status        # ongoing health
```

## What NOT to do

- **Don't hand-edit `INFRA.md` / `INFRA.zh-CN.md`** — they're regenerated
  from templates on every bootstrap; your edits get clobbered.
- **Don't `kubectl apply` into the `apps` namespace by hand** — ArgoCD owns
  it; self-heal will revert you.
- **Don't introduce a new top-level dependency on `yq`/`jq`/`bash` without
  flagging it in `bootstrap.d/01-preflight.sh`.** Outpost runs on
  default-ish macOS/Linux/WSL2 installs and adding a hard prereq is a real
  cost to onboarding.
- **Don't mirror logic in two places.** If a script and a Tekton Task need
  the same function, write it once and ConfigMap-mount the script (see
  `update-manifest`, `read-build-config`, `notify-fanout` for the pattern).
