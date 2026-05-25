# Implementation Report: Outpost v0.4 Phase 3 — Onboard Primitives

## Summary

Implemented the three v0.4 onboard primitives — `outpost db create`,
`outpost seal-from-template`, `outpost manifest scaffold` — as
independently-callable, idempotent subcommands of the `outpost` CLI. Pure
logic lives in a new unit-tested lib (`platform/lib/onboard-lib.sh`); each
command emits human output by default and a locked JSON object under
`--json`. The mechanism-vs-content boundary from ADR 0002 is held: outpost
ships generic mechanism, all app content enters as args / `.env`.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Large | Large — accurate |
| Confidence | 8/10 | 8/10 — two deviations, no rework |
| Files Changed | 6 | 6 (4 created, 2 updated) |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | `platform/lib/onboard-lib.sh` — pure helpers | Complete | 5 functions: db-name, json-esc, json-emit, files-identical, render-subst |
| 2 | Wire libs into `scripts/outpost` | Complete | + symlink-aware `OUTPOST_HOME` (deviation — see below) |
| 3 | `cmd_db` + `db create` | Complete | idempotent via `pg_database` probe |
| 4 | `cmd_seal_from_template` | Complete | `render_template` → `kubeseal` |
| 5 | `cmd_manifest` + `manifest scaffold` | Complete | 5 files; drift reported, not clobbered |
| 6 | Router + `usage()` entries | Complete | 3 router cases, 3 usage lines |
| 7 | `tests/schema/onboard-output.schema.json` | Complete | single-object contract |
| 8 | `tests/bats/onboard-lib.bats` | Complete | 15 unit tests |
| 9 | `tests/bats/onboard-primitives.bats` | Complete | 15 e2e tests |
| 10 | `outpost-cli.bats` help assertion | Complete | 3 tokens added |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Static Analysis | Pass | `bash -n` clean on `scripts/outpost` + `onboard-lib.sh`; `tests/lint.sh` → `lint passed`; schema is valid JSON |
| Unit Tests | Pass | `onboard-lib.bats` 15/15 |
| E2e Tests | Pass | `onboard-primitives.bats` 15/15 (1 skipped — no postgres container; kubeseal-path covered) |
| Full Suite | Pass | `bats tests/bats/ tests/regression/` → **197/197, 0 failures** (was 167 after Phase 1+2; +30) |
| Build | N/A | bash project — no build step |
| Integration | N/A | primitives validated hermetically; cluster paths `skip` when tools absent |
| Edge Cases | Pass | empty args, bad `--lang`, leading-digit DB name, idempotent rerun, drift+exit 2, unresolved `${VAR}`, `set -u` empty-array — all covered |

## Files Changed

| File | Action | Lines |
|---|---|---|
| `platform/lib/onboard-lib.sh` | CREATED | +90 |
| `tests/schema/onboard-output.schema.json` | CREATED | +34 |
| `tests/bats/onboard-lib.bats` | CREATED | +105 |
| `tests/bats/onboard-primitives.bats` | CREATED | +143 |
| `scripts/outpost` | UPDATED | +303 / -3 |
| `tests/bats/outpost-cli.bats` | UPDATED | +1 / -1 |

## Deviations from Plan

- **Added symlink-aware `OUTPOST_HOME` resolution to `scripts/outpost`**
  (not in the plan's Task 2).
  - **WHAT**: `scripts/outpost` now resolves `${BASH_SOURCE[0]}` through its
    symlink chain before deriving `OUTPOST_HOME`.
  - **WHY**: `make install` symlinks the script into `PREFIX`. Once Task 2
    made `scripts/outpost` `source` `platform/lib/*.sh`, the invoked-via-symlink
    case derived `OUTPOST_HOME` from the *symlink's* directory → the
    `source` lines failed → the installed CLI aborted (caught by
    `makefile.bats` test "make install … runs the CLI"). The bug pre-existed
    (the installed CLI already resolved `OUTPOST_HOME` wrong) but was masked
    because `cmd_version` degrades gracefully; the new `source` lines turned
    it into a hard failure. The fix repairs the installed CLI for *all*
    subcommands, not just the regression.
- **Registry variable name.** The plan named `REGISTRY_PULL_HOST`; no such
  variable exists. `manifest scaffold` uses `REGISTRY_PUSH_HOST` (fallback
  `REGISTRY_HOST`, then `registry.example.com`) — the push host is what the
  build pipeline writes, so the scaffolded `kustomization.yaml`'s
  `images[].name` matches what `update-manifest` rewrites on the first build.

## Issues Encountered

- **`makefile.bats` regression** — root-caused to the symlink/`OUTPOST_HOME`
  interaction above; fixed with portable symlink resolution (no `readlink -f`,
  which macOS lacks). Full suite green afterward.
- **jq filter bug in a test** — the schema-shape assertion indexed `.status`
  against the enum array directly; corrected to the `.status as $s | … index($s)`
  form (the pattern `doctor.bats` already uses).

## Tests Written

| Test File | Tests | Coverage |
|---|---|---|
| `tests/bats/onboard-lib.bats` | 15 | Unit — `onboard_db_name` / `_json_esc` / `_emit_json` / `_files_identical` / `_render_subst` |
| `tests/bats/onboard-primitives.bats` | 15 | E2e — arg validation, `manifest scaffold` file output + idempotency + drift + `--force`, `--json` schema shape, `seal-from-template` residue path, `db create` idempotency |

## Behaviour Added

- `outpost db create <app> [--json]` — idempotent `CREATE DATABASE`.
- `outpost seal-from-template <app> --template <p> --output <p> [--json]` —
  envsubst (strict `${VAR}` residue check) + `kubeseal`.
- `outpost manifest scaffold <app> --lang <l> --manifests-dir <d> [--json] [--force]`
  — writes 5 manifest files; reports `drift` (exit 2) rather than clobbering
  hand-edited files.
- All three: human output by default, locked JSON under `--json`
  (`tests/schema/onboard-output.schema.json`), exit `0`/`1`/`2`.
- `make install` now produces a fully-working installed CLI (symlink fix).

## ADR 0002 Compliance

Verified at code-review level: `db create` makes an empty database (no schema/
seed); `seal-from-template` takes the app's template via `--template`;
`manifest scaffold` takes app name / lang / registry / domain as flags + `.env`.
No app-specific content is hardcoded in outpost or `onboard-lib.sh`.

## Next Steps

- [ ] Code review via `/code-review`
- [ ] Commit + PR via `/prp-pr` (stacks onto the open v0.4 branch / PR #1)
- [ ] PRD Phase 4 — webhook auto-register (parallel-eligible) or Phase 5 —
      `outpost onboard` orchestration (depends on Phases 3 + 4)

---

*Generated: 2026-05-21*
*Branch: feat/outpost-v0.4-phase1-cicd-wall-hardening*
