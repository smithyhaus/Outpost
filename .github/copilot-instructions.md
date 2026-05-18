# GitHub Copilot Workspace instructions

These are the rules Copilot (Workspace, Chat, and inline) should apply when
proposing changes in this repo. They mirror what human contributors are
expected to follow; the canonical operating doc is
[`SKILL.md`](../SKILL.md), with the AI-agent on-ramp in
[`AGENTS.md`](../AGENTS.md).

## Project at a glance

Outpost is a self-hosted dev backend in two modes:

- **`local`** (default): Docker Compose data services on `localhost`
  (Postgres / Redis / RabbitMQ / Meilisearch). Zero required input.
- **`full`**: `local` + Cloudflare Tunnel + k3s + ArgoCD + Tekton GitOps.

Built around a 5-kind **plugin model** — `registry`, `git-provider`,
`test-runner`, `rollout`, `notification`. Each plugin is a directory under
`plugins/<kind>/<name>/` with a strict contract (see
[`plugins/README.md`](../plugins/README.md)).

Cross-platform: macOS, Linux, WSL2.

## Coding conventions

- **Shell:** POSIX `sh` for scripts that run inside containers
  (`scripts/notify-fanout.sh`, `scripts/read-build-config.sh`,
  `scripts/update-manifest.sh`). Bash for everything host-side
  (`bootstrap.sh`, `platform/lib/*.sh`). Always `set -euo pipefail` for
  bash; `set -eu` for POSIX sh.
- **YAML:** 2-space indent. Use `${VAR}` envsubst placeholders — `render_template`
  in `platform/lib/portable.sh` will abort if any are unresolved.
- **Tests:** bats for shell logic. Place tests in `tests/bats/<name>.bats`.
  Goldens (fixture-locked outputs) go in `tests/regression/golden/`.
- **Naming:** kebab-case file names; snake_case shell functions; UPPER_SNAKE
  env vars.
- **Comments:** explain *why*, not *what*. Especially: cross-references
  between mirrored locations, fixture-lock rationale, security trade-offs.

## When proposing a change

1. **Check `TODOS.md`** — the change you're contemplating may already be
   captured with full context (What/Why/Pros/Cons/Milestone). Build on
   that context.
2. **Prefer the plugin model over forks.** New build cache strategy? It's
   a `registry` plugin change. New notification channel? It's a
   `notification` plugin.
3. **Don't mirror logic.** If a script and a Tekton Task need the same
   function, write it once and ConfigMap-mount the script. See
   `update-manifest-task`, `task-read-build-config`, `notify-task` for the
   pattern.
4. **Write the bats first.** When adding logic to `scripts/*.sh` or
   `platform/lib/*.sh`, add the bats test before the implementation.
5. **Run the gauntlet locally before opening a PR:**
   ```bash
   bats tests/bats/                # unit tests (~140+)
   bats tests/regression/          # golden snapshots
   bash tests/lint.sh              # shellcheck + yamllint + compose config
   ```

## What NOT to do

- Don't edit `INFRA.md` or `INFRA.zh-CN.md` by hand — they're regenerated.
- Don't `kubectl apply` into the `apps` namespace by hand — ArgoCD owns it.
- Don't add a new hard prereq (`yq`, `jq`, modern bash) without flagging it
  in `bootstrap.d/01-preflight.sh` and updating the README install section.
- Don't break the `OUTPOST_MODE=local` zero-prompt path. It's load-bearing
  for new-user onboarding.
- Don't introduce a fallback that hides a real error. `verify.sh` exits
  non-zero for FAIL and 2 for WARN — preserve that.

For deeper context on any subsystem, read [`SKILL.md`](../SKILL.md) and the
relevant section of [`TODOS.md`](../TODOS.md).
