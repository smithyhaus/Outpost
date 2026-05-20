# Implementation Report: CI/CD Wall Regression Hardening + Deploy-Branch Pin

## Summary

Implemented Outpost v0.4 Phase 1 (re-scoped): fixed wall **C3** by pinning the
EventListener CEL ref filter to a configurable `OUTPOST_DEPLOY_BRANCH` (default
`main`) across all 3 git-provider trigger plugins, and added `tests/bats/cicd-walls.bats`
— a regression-lock suite covering all 6 CI/CD onboarding walls (B1/B2/B3/B5/B6/C3).
Webhook pushes to non-deploy branches no longer build + deploy to production.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Medium | Medium — accurate |
| Confidence | 9/10 | 9/10 — single-pass, zero rework |
| Files Changed | 7 | 7 (6 updated, 1 created) |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | `OUTPOST_DEPLOY_BRANCH` config default + `.env` persist | Complete | `02-config.sh` shared-modes block + persist block |
| 2 | Document `OUTPOST_DEPLOY_BRANCH` in `.env.example` | Complete | Placed after `MANIFEST_REPO_BRANCH` with distinguishing comment |
| 3 | Pin CEL ref filter — `gitee/trigger.yaml` | Complete | Filter + header comment updated |
| 4 | Pin CEL ref filter — `github/trigger.yaml` | Complete | Filter + header comment updated |
| 5 | Pin CEL ref filter — `gitlab/trigger.yaml` | Complete | Filter + header comment updated |
| 6 | Fix `eventlistener-assemble.bats` setup() + add C3 assertions | Complete | setup() exports the new var (the critical GOTCHA); C3 assertions added to 3 happy-path tests |
| 7 | Create `tests/bats/cicd-walls.bats` | Complete | 11 regression-lock tests |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Static Analysis | Pass | `bash tests/lint.sh` → `[ OK ] lint passed`; only pre-existing `examples/` yaml warnings, none in changed files |
| Unit Tests | Pass | `cicd-walls.bats` 11/11; `eventlistener-assemble.bats` 10/10 |
| Full Suite | Pass | `bats tests/bats/ tests/regression/` → 154/154, **0 failures** |
| Build | N/A | bash project — no build step |
| Integration | N/A | static config change — no server / cluster |
| Edge Cases | Pass | unset-var residue check (eventlistener-assemble test 10); tag/branch-deletion rejection inherent in the pinned CEL filter; configurability exercised by setup() |

## Files Changed

| File | Action | Lines |
|---|---|---|
| `bootstrap.d/02-config.sh` | UPDATED | +5 |
| `.env.example` | UPDATED | +7 |
| `plugins/git-provider/gitee/trigger.yaml` | UPDATED | +3 / -2 |
| `plugins/git-provider/github/trigger.yaml` | UPDATED | +3 / -2 |
| `plugins/git-provider/gitlab/trigger.yaml` | UPDATED | +3 / -2 |
| `tests/bats/eventlistener-assemble.bats` | UPDATED | +12 |
| `tests/bats/cicd-walls.bats` | CREATED | +84 |

## Deviations from Plan

- **Test counts off in the plan (cosmetic).** Plan predicted `cicd-walls.bats`
  = 12 tests and `eventlistener-assemble.bats` = 9 tests. Actual: 11 and 10.
  The plan miscounted; wall coverage is complete (B1×3, B2×2, B3×2, B5×1,
  B6×1, C3×2 = 11) and all pre-existing eventlistener tests (10) still pass.
  No implementation impact.

## Issues Encountered

None. The plan's critical GOTCHA (adding `${OUTPOST_DEPLOY_BRANCH}` to
`trigger.yaml` would abort all `eventlistener-assemble.bats` tests via the
`render_template` residue check unless setup() exports the var) was addressed
proactively in Task 6 — `eventlistener-assemble.bats` stayed 10/10 green.

## Tests Written

| Test File | Tests | Coverage |
|---|---|---|
| `tests/bats/cicd-walls.bats` | 11 | Static-file regression locks for walls B1/B2/B3/B5/B6/C3 |
| `tests/bats/eventlistener-assemble.bats` | +3 assertions | C3 verified against the assembled EventListener for gitee/github/gitlab |

**Negative proof**: confirmed `grep -qF "startsWith('refs/heads/')"` matches an
old-style filter line — i.e. the C3 regression test would catch a revert.

## Behavior Change

- Webhook push to a non-deploy branch → filtered (200 OK, no PipelineRun).
- Webhook push to `${OUTPOST_DEPLOY_BRANCH}` (default `main`) → builds + deploys.
- Repos using `master` set `OUTPOST_DEPLOY_BRANCH=master` in `.env`.
- Existing running clusters pick up the pinned filter on the next
  `bootstrap.sh` run (Phase 8 always re-assembles the EventListener).

## Next Steps

- [ ] Code review via `/code-review`
- [ ] Commit + PR via `/prp-pr`
- [ ] PRD Phase 2 — `outpost doctor` ex-ante preflight (next pending phase)
- [ ] Before PRD Phase 3/5: investigate commit `c1e1050 revert: 把 onboarding 编排移出 infras`

---

*Generated: 2026-05-20*
*Branch: feat/outpost-v0.4-phase1-cicd-wall-hardening*
