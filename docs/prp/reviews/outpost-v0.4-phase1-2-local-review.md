# Code Review: Outpost v0.4 Phase 1 + Phase 2 (local, uncommitted)

**Reviewed**: 2026-05-20
**Branch**: `feat/outpost-v0.4-phase1-cicd-wall-hardening` (Phase 1 + Phase 2 stacked)
**Decision**: APPROVE — 1 HIGH + 1 MEDIUM found and fixed during review

## Summary

Phase 1 pins the EventListener CEL ref filter to a configurable
`OUTPOST_DEPLOY_BRANCH` (wall C3) and adds a 6-wall regression-lock suite.
Phase 2 adds `outpost doctor` — a read-only ex-ante preflight. Implementation
is clean, well-commented, mode-aware, and bash-3.2-safe. Review found one
reproducible hang bug and one schema-contract gap; both fixed and locked with
a regression test before sign-off.

## Findings

### CRITICAL
None.

### HIGH
- **`doctor.sh:47` — `--egress` with no value hung the CLI forever.**
  `shift 2` is a no-op when only one positional remains (count out of range),
  so `$#` stayed `1` and the `while [[ $# -gt 0 ]]` arg-parser spun. Confirmed
  reproducible.
  **Fixed**: `shift; [[ $# -gt 0 ]] && shift`. Locked by new test
  `doctor.bats:31` (watchdog: must terminate within 30s).

### MEDIUM
- **`doctor.sh:231,257` — egress check `id` could break the JSON contract.**
  The `id` was derived from a user-supplied `--egress` host via
  `tr 'A-Z/' 'a-z_'` only. A plausible input (`--egress registry.local:5000`)
  produced `egress.registry.local:5000`, violating the schema `id` pattern
  `^[a-z][a-z0-9_.-]*$`; and `id` was interpolated into JSON without
  `json_esc`, so a host containing `"` would emit invalid JSON.
  **Fixed**: sanitise to `[a-z0-9._-]` via `tr -c`; route `id` through
  `json_esc` in the JSON branch.

### LOW
- `doctor.sh:211` hardcodes the kaniko build image `v1.5.1`. TODOS.md already
  tracks a v0.4 task to replace/bump kaniko — when that lands, this string
  must move in lockstep or doctor silently probes a stale image. Acceptable
  for now (the canonical pin lives in an upstream catalog Task, not a repo
  yaml, so there is no clean variable to source). Note only.
- `doctor.sh` pulls `alpine:3.20` via `docker run --rm` for the
  host-gateway check — a benign image-cache write. The header carves this
  out explicitly ("`docker run --rm` only"). Note only.

## Validation Results

| Check | Result |
|---|---|
| Lint (`tests/lint.sh`) | Pass |
| Tests (`bats tests/bats tests/regression`) | Pass — 167/167, 0 failures |
| Build | N/A (bash project) |
| `bash -n` on changed shell files | Pass |

## Files Reviewed

| File | Change |
|---|---|
| `.env.example` | Modified — `OUTPOST_DEPLOY_BRANCH` doc |
| `bootstrap.d/02-config.sh` | Modified — `OUTPOST_DEPLOY_BRANCH` default + persist |
| `plugins/git-provider/{gitee,github,gitlab}/trigger.yaml` | Modified — CEL ref filter pinned to deploy branch |
| `scripts/outpost` | Modified — `doctor` subcommand wiring |
| `doctor.sh` | Added — preflight orchestrator (+ 3 review fixes) |
| `platform/lib/doctor-checks.sh` | Added — pure check helpers |
| `tests/bats/cicd-walls.bats` | Added — 6-wall regression locks |
| `tests/bats/doctor-checks.bats` | Added — unit tests |
| `tests/bats/doctor.bats` | Added — e2e tests (+ arg-parser regression lock) |
| `tests/bats/eventlistener-assemble.bats` | Modified — C3 assertions |
| `tests/bats/outpost-cli.bats` | Modified — `doctor` in help assertion |
| `tests/schema/doctor-output.schema.json` | Added — JSON output contract |

## Decision Rationale

The HIGH and MEDIUM were fixed in-review (small, contained, behaviour-locking
edits) and the full suite is green, so the branch is APPROVE rather than
REQUEST CHANGES. No outstanding blockers for commit + PR.
