# Contributing to Outpost

Thanks for your interest! Whether it's a plugin, a doc translation, a
bug fix, or a platform port, we welcome the contribution.

## Quick start for contributors

1. **Fork & clone** the repo
2. **Run the lint & tests** locally:
   ```bash
   bash tests/lint.sh
   bats tests/bats/
   ```
3. **Make your change.** Keep the diff minimal and focused.
4. **Open a PR** against `main`. CI will run lint + the test matrix.

## Project structure (refresher)

See [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`SKILL.md`](SKILL.md) for
the layout. Two pieces matter most for contributors:

- **`platform/`** — per-OS hooks. Touch this if your change is OS-specific.
- **`plugins/`** — pluggable backends (registry, git-provider). Almost any
  new integration should be a plugin, not a core change.

## Authoring a plugin

The plugin contract is the most common contribution path. See
[`plugins/README.md`](plugins/README.md) for the contract.

In short, copy the closest existing plugin and adapt:

```bash
cp -r plugins/registry/self-hosted plugins/registry/<your-name>
# edit plugin.yaml, manifest.yaml, preflight.sh, README.md
```

Add a smoke test under `tests/plugins/<kind>-<name>.bats`. Update the
plugin table in `README.md` and `README.zh-CN.md`.

## Translating docs

Top-level files (`README.md`, `INFRA.md.template`) and per-doc files
under `i18n/<lang>/docs/` are bilingual. We currently ship `en` and
`zh-CN`. Pull requests adding a new language are welcome:

1. Mirror the directory structure under `i18n/<your-lang>/`
2. Translate at minimum: README and the seven `docs/0*.md` files
3. Update the README.md "Documentation" table

We do **not** auto-detect drift between languages. When you change EN,
update zh-CN (and vice versa) in the same PR. CI will warn about
filenames that exist in one language tree but not the others.

## Running the tests

We use [bats-core](https://github.com/bats-core/bats-core) for shell tests
plus `shellcheck` and `yamllint` for static analysis.

### Pre-push checklist (the local equivalent of CI)

Before pushing, run these two — together they're <30 s and catch every
issue the CI's static-analysis layers would catch:

```bash
bash tests/lint.sh && bats tests/bats/ tests/regression/
```

The macOS bash 3.2 compat that CI used to "test" via the macos-latest
runner is now exercised by your local pre-push run instead (the runner
turned out to misrepresent real macOS environments — see commit log
for the analysis).

### Test layout

```bash
# Static analysis — shellcheck + yamllint + docker compose config
bash tests/lint.sh

# Bats unit tests (no real cluster needed)
bats tests/bats/

# Plugin regression test (load-bearing — guards the plugin contract)
bats tests/regression/

# JSON schema lock for verify.sh output
bats tests/schema/
```

### CI tiers — what runs when

| Workflow | Trigger | Catches |
|---|---|---|
| `lint` | every push + PR | shellcheck (`-S warning`) + yamllint + docker-compose-config |
| `test-matrix` | every push + PR | bats unit + regression on `ubuntu-latest` |
| `e2e` | nightly cron + `[ci-e2e]` in commit subject + manual dispatch | fresh `bash bootstrap.sh` (full mode) on `ubuntu-latest` via k3d-in-Docker, asserts every resilience layer is present in the resulting cluster |

The `e2e` job is the only one that catches runtime bugs (Tekton param
coercion, kaniko CLI typos, .env corruption on re-source, etc.) — the
class of bugs that bit the project repeatedly before this CI tier was
added. It runs ~15 min, so we cron it daily instead of per-push.
Maintainer can opt in to e2e for a specific push by adding `[e2e]` to
the commit subject line.

## Code style

- Bash: keep functions small, name them with the `sk_` prefix when they
  belong to platform/lib/portable.sh.
- Idempotency: re-running a script must be safe.
- Don't break the [invariants](SKILL.md#4-critical-invariants--do-not-break)
  in `SKILL.md` without explicit discussion in the PR description.

## Commit messages

We use conventional-commits-ish prefixes:

- `feat(<area>):` new functionality
- `fix(<area>):` bug fix
- `docs(<area>):` docs only
- `chore(<area>):` repo plumbing
- `test(<area>):` test only
- `plugin(<kind>/<name>):` plugin-scoped change

`<area>` examples: `compose`, `k8s`, `bootstrap`, `verify`, `tekton`,
`argocd`, `i18n-zh-CN`, `tests`.

## Reporting bugs

Open an Issue using the **bug report** template. Include:

- OS + version (`uname -a` + `sw_vers` or `lsb_release -a`)
- outpost commit / tag
- `bash verify.sh --json` output (paste the relevant subset)
- What you expected vs what happened

## Security

Please **do not** open public issues for security findings. See
[`SECURITY.md`](SECURITY.md).

## Code of conduct

Be excellent to each other. See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

By contributing you agree that your contribution is licensed under the
project's [Apache 2.0 License](LICENSE).
