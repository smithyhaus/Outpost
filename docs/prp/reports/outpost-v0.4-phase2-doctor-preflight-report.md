# Implementation Report: `outpost doctor` — Ex-Ante Preflight

## Summary

Implemented Outpost v0.4 Phase 2: `outpost doctor` — a pre-bootstrap preflight
that catches the failure modes which today only surface mid-`bootstrap.sh`
(port collisions, Docker down, unresolved domain, malformed Cloudflare token,
unreachable build image, blocked build egress). It mirrors `verify.sh` exactly
in structure, adds a `fix_hint` per check, emits human + `--json` output, exits
`0`/`1`/`2`, and is fully read-only / idempotent. Pure check logic lives in a
unit-tested lib.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Large | Large — accurate |
| Confidence | 8/10 | 9/10 — one planned deviation, no rework |
| Files Changed | 7 | 7 (5 created, 2 updated) |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | `platform/lib/doctor-checks.sh` — pure check functions | Complete | 4 functions: port_state, port_holder, cf_token_state, dns_state |
| 2 | `doctor.sh` — orchestrator | Complete | Mirrors verify.sh; 6 check sections; mode-aware |
| 3 | Wire `doctor` into the `outpost` CLI | Complete | `cmd_doctor` + router case + usage entry |
| 4 | `tests/schema/doctor-output.schema.json` | Complete | verify's schema + required `fix_hint` |
| 5 | `tests/bats/doctor-checks.bats` — unit tests | Complete | 7 tests (synthetic failures) |
| 6 | `tests/bats/doctor.bats` — e2e tests | Complete | 5 tests — **deviated** (see Deviations) |
| 7 | `doctor` in `outpost-cli.bats` help assertion | Complete | one token added |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Static Analysis | Pass | `bash tests/lint.sh` → `[ OK ] lint passed`; `bash -n` clean on both new shell files; schema is valid JSON |
| Unit Tests | Pass | `doctor-checks.bats` 7/7; `doctor.bats` 5/5; `outpost-cli.bats` 11/11 |
| Full Suite | Pass | `bats tests/bats/ tests/regression/` → **166/166, 0 failures** (was 154 after Phase 1; +12) |
| Build | N/A | bash project — no build step |
| Integration | N/A | doctor is a read-only preflight — no server |
| Edge Cases | Pass | unset-var defaults, docker-down WARN-skip, lsof-absent, local-vs-full mode, `nc`/`jq`-absent skips — all covered by tests |

## Files Changed

| File | Action | Lines |
|---|---|---|
| `platform/lib/doctor-checks.sh` | CREATED | +58 |
| `doctor.sh` | CREATED | +270 |
| `tests/schema/doctor-output.schema.json` | CREATED | +42 |
| `tests/bats/doctor-checks.bats` | CREATED | +52 |
| `tests/bats/doctor.bats` | CREATED | +59 |
| `scripts/outpost` | UPDATED | +7 |
| `tests/bats/outpost-cli.bats` | UPDATED | +1 / -1 |

## Deviations from Plan

- **`doctor.bats` — replaced the planned e2e CF-token test with an e2e
  egress-failure test.**
  - **WHAT**: The plan's Task 6 test "a malformed `CF_TUNNEL_TOKEN` … is
    reported FAIL" was dropped; a "`--egress <bogus>` forces a FAIL with a
    non-empty `fix_hint`" test was added in its place. The plan's separate
    `fix_hint` test was merged into the schema-shape test. Net: 5 e2e tests
    instead of 6.
  - **WHY**: `doctor.sh` sources `.env` *after* inheriting env vars (so doctor
    works pre-bootstrap with sensible defaults). On any configured machine the
    real `.env` would clobber the test's injected `CF_TUNNEL_TOKEN=bogus` and
    `OUTPOST_MODE=full`, making the assertion non-deterministic. The
    bad-CF-token synthetic case is already covered hermetically at the unit
    level (`doctor-checks.bats`: "doctor_cf_token_state: short junk is
    invalid"). `--egress` is a CLI argument — immune to `.env` — so it
    *reliably* drives the full `doctor.sh` pipeline end-to-end into a FAIL +
    `fix_hint` regardless of machine state. Coverage is equal-or-better.
- **Section numbering**: doctor.sh numbers its sections 1–6 sequentially; the
  plan loosely mirrored verify.sh's "Section 8" label for egress. Cosmetic.

## Issues Encountered

None. The plan's GOTCHAs were all handled proactively:
- `set -uo pipefail` with **no `-e`** — a failing check does not abort the script.
- bash 3.2 safety — used a `port_svc()` `case` function, not a `declare -A`
  associative array (macOS default bash is 3.2).
- Empty-array expansion under `set -u` — the `--egress` loop is guarded by an
  `[[ ${#EGRESS_HOSTS[@]} -eq 0 ]]` check so the empty array is never expanded.
- `docker run` / `docker manifest inspect` only run when `docker info` succeeds;
  otherwise WARN-skip cleanly.

## Tests Written

| Test File | Tests | Coverage |
|---|---|---|
| `tests/bats/doctor-checks.bats` | 7 | Unit — port free/busy, CF-token valid/invalid, DNS nxdomain, port-holder graceful degrade |
| `tests/bats/doctor.bats` | 5 | E2E — syntax, human summary, `--json` schema shape, forced egress FAIL + `fix_hint`, CLI wiring |

## Behaviour Added

- `outpost doctor` / `outpost doctor --egress h1,h2` — new CLI subcommand.
- `doctor.sh [--json|--quiet|--egress …]` — new top-level script (sibling of `verify.sh`).
- Smoke run on this machine: 21 checks, exit reflects FAIL/WARN, JSON validates
  against `doctor-output.schema.json`.
- Read-only / idempotent — no file writes; `docker run --rm` only.

## Next Steps

- [ ] Code review via `/code-review`
- [ ] Commit + PR via `/prp-pr` (Phase 1 + Phase 2 are stacked on one branch)
- [ ] PRD Phase 3 — onboard primitives (`db create` / `seal-from-template` / `manifest scaffold`)
- [ ] **Before Phase 3/5 planning**: investigate commit `c1e1050 revert: 把 onboarding 编排移出 infras`

---

*Generated: 2026-05-20*
*Branch: feat/outpost-v0.4-phase1-cicd-wall-hardening (Phase 1 + Phase 2 stacked)*
