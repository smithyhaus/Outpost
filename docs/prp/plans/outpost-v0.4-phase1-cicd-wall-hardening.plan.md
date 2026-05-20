# Plan: CI/CD Wall Regression Hardening + Deploy-Branch Pin (Outpost v0.4 Phase 1)

## Summary

Phase 1 of the Outpost v0.4 PRD was written assuming 6 CI/CD onboarding walls (B1, B2, B3, B5, B6, C3) were all unfixed. Codebase exploration (git log + source) found **5 of 6 already fixed during the v0.3 cycle** — only **C3 (webhook fires on any branch)** is genuinely open. This re-scoped Phase 1 therefore does two things: **(1)** fix C3 by pinning the webhook trigger to a configurable deploy branch (default `main`) across all 3 git-provider plugins, and **(2)** add a bats regression-lock test file so none of the 6 walls can silently regress again.

## User Story

As the **Outpost maintainer onboarding real projects**, I want **webhook pushes to trigger the pipeline only on the deploy branch, and every previously-fixed CI/CD wall locked by an automated test**, so that **a dev-branch push never races a half-baked commit into production, and a future refactor cannot silently re-open a wall I already paid to close**.

## Problem → Solution

**Current state**: All 3 git-provider trigger plugins (`gitee`, `github`, `gitlab`) use the CEL filter `body.ref.startsWith('refs/heads/')` — *any* branch push triggers a build + `update-manifest` push to the manifests repo `main`, which ArgoCD then deploys. A dev pushing a feature branch silently deploys it to prod (documented as issue #5 in `SCM MCP/ONBOARDING-CICD.md`). Separately, walls B1/B2/B3/B5/B6 are fixed in source but have **zero regression coverage** — a refactor could revert any of them with no test failure.

**Desired state**: The CEL ref filter pins to `refs/heads/${OUTPOST_DEPLOY_BRANCH}` (new env var, default `main`, configurable for `master`-branch repos). A new `tests/bats/cicd-walls.bats` asserts the fixed state of all 6 walls via static-file greps — CI fails loudly if any fix is reverted.

## Metadata

- **Complexity**: Medium (7 files, follows existing patterns, ~1 new concept: a config env var)
- **Source PRD**: `docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md`
- **PRD Phase**: Phase 1 — Foundation hardening (re-scoped after exploration; see "Notes")
- **Estimated Files**: 7 (3 UPDATE trigger plugins, 2 UPDATE config, 1 UPDATE existing bats, 1 CREATE bats)

---

## UX Design

### Before
```
dev pushes feature/login-fix  ──► Gitee/GitHub/GitLab webhook
                                       │  CEL: startsWith('refs/heads/')  ── matches ANY branch
                                       ▼
                              PipelineRun build ──► update-manifest pushes to manifests/main
                                       ▼
                              ArgoCD syncs ──► feature/login-fix DEPLOYED TO PROD  ❌
```

### After
```
dev pushes feature/login-fix  ──► webhook ──► CEL: ref == 'refs/heads/${OUTPOST_DEPLOY_BRANCH}'
                                       │  default OUTPOST_DEPLOY_BRANCH=main
                                       ▼
                              non-main branch ──► rejected (200 OK, no PipelineRun)  ✓

dev pushes main  ──────────────► webhook ──► CEL matches ──► build ──► deploy  ✓
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| Webhook on feature-branch push | Builds + deploys | No-op (filtered) | Intended behavior; PR-preview envs are a separate v0.5 PRD item |
| `.env` / `.env.example` | No deploy-branch knob | New `OUTPOST_DEPLOY_BRANCH=main` | Repos using `master` set it once |
| Re-running `bootstrap.sh` | — | Re-assembles EventListener with the pinned filter | Existing clusters need a re-bootstrap (or `upgrade.sh`) to pick up the change |
| `bats tests/bats/` | 16 test files | 17 — new `cicd-walls.bats` locks 6 walls | CI gate |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `plugins/git-provider/gitee/trigger.yaml` | all (47) | Primary C3 fix target; CEL ref filter at line 35 |
| P0 | `plugins/git-provider/github/trigger.yaml` | all (46) | C3 fix target; CEL ref filter at line 34 |
| P0 | `plugins/git-provider/gitlab/trigger.yaml` | all (48) | C3 fix target; CEL ref filter at line 36 |
| P0 | `tests/bats/eventlistener-assemble.bats` | 1-32, 81-128 | Pattern to mirror for new bats file; setup() MUST be updated (see GOTCHA) |
| P0 | `bootstrap.d/02-config.sh` | 65-72, 156-205 | Where to add the `OUTPOST_DEPLOY_BRANCH` default + `.env` persist line |
| P1 | `platform/lib/eventlistener-assemble.sh` | 1-69 | Explains why trigger.yaml goes through `render_template` (residue check) — the GOTCHA source |
| P1 | `.env.example` | 76-84 | Where to document `OUTPOST_DEPLOY_BRANCH` (after `MANIFEST_REPO_BRANCH`, line 79) |
| P1 | `core/k8s/05-tekton/pipeline-build.yaml` | 31-78, 155-184 | B1/B2 regression assertions target this file |
| P1 | `core/k8s/05-tekton/triggertemplate.yaml` | 30-55 | B3 regression assertion targets `timeouts:` block |
| P1 | `core/k8s/05-tekton/secrets.template.yaml` | 30-37 | B5 regression assertion targets `.gitconfig` block |
| P1 | `bootstrap.d/08-argocd-tekton.sh` | 90-98 | B6 regression assertion targets the PSA label line |
| P2 | `tests/README.md` | all | How the 3 test layers run + CI wiring |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| Tekton Triggers CEL interceptor | tekton.dev/docs/triggers/cel_expressions | `body.ref` is the full ref string (`refs/heads/main`); `==` is exact match. No external lookup needed — the codebase already uses CEL filters extensively. |

No further external research needed — feature uses established internal patterns (CEL filters, `render_template` envsubst, bats static-file assertions).

---

## Patterns to Mirror

### BATS_SETUP_AND_TEST_STRUCTURE
```bash
# SOURCE: tests/bats/eventlistener-assemble.bats:10-31, 81-99
setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # ... source libs, export env ...
  BASE="${INFRA_ROOT}/core/k8s/05-tekton/eventlistener-base.yaml"
}

@test "assemble gitee: produces EventListener with gitee-push trigger + el-build-listener service" {
  OUT=$(mktemp)
  run assemble_eventlistener "..." "$BASE" "$OUT"
  [ "$status" -eq 0 ]
  grep -q "^kind: EventListener" "$OUT"
  grep -q "name: gitee-push" "$OUT"
}
```
Variables assigned in `setup()` without `local` are visible inside every `@test`. Assertions are plain `grep -q` / `[ ... ]`. `run <cmd>` captures `$status` + `$output`.

### CEL_REF_FILTER (the C3 target — current broken form)
```yaml
# SOURCE: plugins/git-provider/gitee/trigger.yaml:31-35
    - ref:
        name: cel
      params:
        - name: filter
          value: "body.ref.startsWith('refs/heads/') && body.after != '0000000000000000000000000000000000000000'"
```
Identical filter line exists in `github/trigger.yaml:34` and `gitlab/trigger.yaml:36`.

### ENVSUBST_PLACEHOLDER_IN_TRIGGER (how `${VAR}` is already used in trigger.yaml)
```yaml
# SOURCE: plugins/git-provider/gitee/trigger.yaml:24-25, 29-30
          value: "header['X-Gitee-Token'][0] == '${GIT_WEBHOOK_SECRET}'"
          value: "size(${CEL_WHITELIST_LIST}) == 0 || body.repository.git_http_url in ${CEL_WHITELIST_LIST}"
```
`trigger.yaml` is rendered through `render_template` (envsubst + strict residue check). Any `${VAR}` it contains MUST be exported when the file is rendered, or `render_template` aborts. This is why a new `${OUTPOST_DEPLOY_BRANCH}` requires a default in `02-config.sh` AND an export in the bats setup().

### CONFIG_DEFAULT (shared-by-both-modes default pattern)
```bash
# SOURCE: bootstrap.d/02-config.sh:65-68
# Defaults shared by both modes
REGISTRY_PLUGIN="${REGISTRY_PLUGIN:-self-hosted}"
GIT_PROVIDER_PLUGIN="${GIT_PROVIDER_PLUGIN:-gitee}"
MANIFEST_REPO_BRANCH="${MANIFEST_REPO_BRANCH:-main}"
```

### CONFIG_PERSIST (canonical `.env` rewrite block)
```bash
# SOURCE: bootstrap.d/02-config.sh:175-176 (inside the `{ ... } > .env` block)
  echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
  echo "MANIFEST_REPO_BRANCH=${MANIFEST_REPO_BRANCH}"
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `plugins/git-provider/gitee/trigger.yaml` | UPDATE | C3 fix — pin CEL ref filter; update header comment |
| `plugins/git-provider/github/trigger.yaml` | UPDATE | C3 fix — pin CEL ref filter; update header comment |
| `plugins/git-provider/gitlab/trigger.yaml` | UPDATE | C3 fix — pin CEL ref filter; update header comment |
| `bootstrap.d/02-config.sh` | UPDATE | Add `OUTPOST_DEPLOY_BRANCH` default (shared-modes block) + `.env` persist line |
| `.env.example` | UPDATE | Document the new `OUTPOST_DEPLOY_BRANCH` knob |
| `tests/bats/eventlistener-assemble.bats` | UPDATE | setup() must export `OUTPOST_DEPLOY_BRANCH` or all 9 tests break (GOTCHA); add C3 assertion to the 3 happy-path tests |
| `tests/bats/cicd-walls.bats` | CREATE | New regression-lock file covering all 6 walls (B1/B2/B3/B5/B6/C3) |

## NOT Building

- **B1/B2/B3/B5/B6 source fixes** — already shipped in the v0.3 cycle (commits `890032f`, `06b2fbe`, `6a1cba1`/`d9736fa`, `eb5fdc7`, `7e32c13`). This plan only adds regression *locks* for them, not new fixes.
- **PR / branch preview environments** — routing non-main branches to ephemeral deploys is a deferred v0.5 PRD item; Phase 1 only *rejects* non-deploy-branch pushes.
- **i18n doc updates** (`i18n/en|zh-CN/docs/*`) for the new env var — consolidated into PRD Phase 9 (docs/i18n/CHANGELOG). `.env.example` is not i18n'd, so it is in scope.
- **CHANGELOG.md entry** — consolidated into PRD Phase 9.
- **Migrating already-running clusters** — the pinned filter takes effect on the next `bootstrap.sh` / `upgrade.sh` run; no live-cluster migration tooling.
- **`outpost doctor`** — that is PRD Phase 2.

---

## Step-by-Step Tasks

### Task 1: Add `OUTPOST_DEPLOY_BRANCH` config default + persist
- **ACTION**: Edit `bootstrap.d/02-config.sh`.
- **IMPLEMENT**:
  1. In the "Defaults shared by both modes" block (after line 68, `MANIFEST_REPO_BRANCH=...`), add:
     ```bash
     OUTPOST_DEPLOY_BRANCH="${OUTPOST_DEPLOY_BRANCH:-main}"
     ```
  2. In the canonical `.env` rewrite block (after line 176, `echo "MANIFEST_REPO_BRANCH=..."`), add:
     ```bash
     echo "OUTPOST_DEPLOY_BRANCH=${OUTPOST_DEPLOY_BRANCH}"
     ```
- **MIRROR**: CONFIG_DEFAULT and CONFIG_PERSIST patterns above.
- **IMPORTS**: none (shell).
- **GOTCHA**: Must be in the *shared-by-both-modes* block, not inside the `if [[ "$OUTPOST_MODE" == "full" ]]` branch — `02-config.sh:74` comment explicitly says Phase-9-style vars are "read in both so `.env` is consistent". Same rule here.
- **VALIDATE**: `grep -n OUTPOST_DEPLOY_BRANCH bootstrap.d/02-config.sh` shows exactly 2 lines (default + echo). `bash tests/lint.sh` passes shellcheck.

### Task 2: Document `OUTPOST_DEPLOY_BRANCH` in `.env.example`
- **ACTION**: Edit `.env.example`.
- **IMPLEMENT**: After line 79 (`MANIFEST_REPO_BRANCH=main`), add a blank line then:
  ```
  # Branch of YOUR APP repo whose pushes trigger the CI/CD pipeline.
  # Pushes to any other branch are ignored by the webhook. Default: main.
  # Set to `master` (or your convention) for repos that don't use main.
  OUTPOST_DEPLOY_BRANCH=main
  ```
- **MIRROR**: the comment-then-`KEY=value` style of the surrounding `.env.example` entries (e.g. lines 76-79).
- **IMPORTS**: none.
- **GOTCHA**: `OUTPOST_DEPLOY_BRANCH` is the **app repo** branch — distinct from `MANIFEST_REPO_BRANCH` (the manifests repo branch ArgoCD watches). The comment must make that distinction so a reader doesn't conflate them.
- **VALIDATE**: `grep -c OUTPOST_DEPLOY_BRANCH .env.example` returns `1`.

### Task 3: Pin the CEL ref filter in `gitee/trigger.yaml`
- **ACTION**: Edit `plugins/git-provider/gitee/trigger.yaml`.
- **IMPLEMENT**:
  1. Line 35 — replace:
     ```yaml
           value: "body.ref.startsWith('refs/heads/') && body.after != '0000000000000000000000000000000000000000'"
     ```
     with:
     ```yaml
           value: "body.ref == 'refs/heads/${OUTPOST_DEPLOY_BRANCH}' && body.after != '0000000000000000000000000000000000000000'"
     ```
  2. Update the header comment line 11 from `4. Ref filter (rejects tag pushes + branch deletions)` to `4. Ref filter — deploy branch only (OUTPOST_DEPLOY_BRANCH, default main); also rejects tags + branch deletions`.
- **MIRROR**: ENVSUBST_PLACEHOLDER_IN_TRIGGER — `${OUTPOST_DEPLOY_BRANCH}` follows the exact form of the existing `${GIT_WEBHOOK_SECRET}` / `${CEL_WHITELIST_LIST}` placeholders in the same file.
- **IMPORTS**: none (YAML).
- **GOTCHA**: Keep the `&& body.after != '000...'` clause — it rejects branch *deletions* (a delete push has `after` = all-zeroes). Exact-matching `refs/heads/main` already rejects tag pushes (`refs/tags/...`), so the comment's "rejects tags" is still true.
- **VALIDATE**: `grep -F "body.ref == 'refs/heads/\${OUTPOST_DEPLOY_BRANCH}'" plugins/git-provider/gitee/trigger.yaml` matches; `grep -F "startsWith('refs/heads/')" plugins/git-provider/gitee/trigger.yaml` returns nothing.

### Task 4: Pin the CEL ref filter in `github/trigger.yaml`
- **ACTION**: Edit `plugins/git-provider/github/trigger.yaml`.
- **IMPLEMENT**: Same replacement as Task 3, but at **line 34**. Update the header comment line 11 (`3. Ref filter (rejects tag pushes + branch deletions)`) the same way.
- **MIRROR**: Task 3.
- **IMPORTS**: none.
- **GOTCHA**: GitHub's push payload also carries `body.ref` as `refs/heads/<branch>` — same field name as Gitee/GitLab, so the identical filter string is correct. (GitHub differs only in `clone_url` vs `git_http_url`, which is the *whitelist* filter, not this one.)
- **VALIDATE**: same grep pair as Task 3 against `github/trigger.yaml`.

### Task 5: Pin the CEL ref filter in `gitlab/trigger.yaml`
- **ACTION**: Edit `plugins/git-provider/gitlab/trigger.yaml`.
- **IMPLEMENT**: Same replacement as Task 3, but at **line 36**. Update the header comment line 12 (`4. Ref filter (rejects tag pushes + branch deletions)`) the same way.
- **MIRROR**: Task 3.
- **IMPORTS**: none.
- **GOTCHA**: GitLab push payload `body.ref` is also `refs/heads/<branch>` — identical filter is correct.
- **VALIDATE**: same grep pair as Task 3 against `gitlab/trigger.yaml`.

### Task 6: Fix `eventlistener-assemble.bats` setup() + add C3 assertions
- **ACTION**: Edit `tests/bats/eventlistener-assemble.bats`.
- **IMPLEMENT**:
  1. In `setup()` (after line 22, near the other `export` lines), add:
     ```bash
     export OUTPOST_DEPLOY_BRANCH="main"
     ```
  2. In each of the 3 happy-path tests (`assemble gitee`, `assemble github`, `assemble gitlab` — lines 81/101/117), add one assertion after the existing `grep`s:
     ```bash
       # C3: ref filter pins the deploy branch (no any-branch startsWith)
       grep -q "refs/heads/main" "$OUT"
       ! grep -qF "startsWith('refs/heads/')" "$OUT"
     ```
- **MIRROR**: BATS_SETUP_AND_TEST_STRUCTURE — the file already exports `ROOT_DOMAIN` / `GIT_WEBHOOK_SECRET` in setup(); this adds one more.
- **IMPORTS**: none.
- **GOTCHA**: **This is the critical GOTCHA of the whole plan.** After Tasks 3-5, `trigger.yaml` contains `${OUTPOST_DEPLOY_BRANCH}`. `assemble_eventlistener` → `render_template` runs envsubst then a strict unresolved-`${VAR}` residue check (`platform/lib/eventlistener-assemble.sh:62`, `platform/lib/portable.sh`). If `OUTPOST_DEPLOY_BRANCH` is unset when the bats suite runs, **all 9 existing tests in this file abort** ("unresolved placeholder"). The setup() export is mandatory, not optional.
- **VALIDATE**: `bats tests/bats/eventlistener-assemble.bats` — all tests pass (was 9, still 9, now with C3 assertions inside 3 of them).

### Task 7: Create `tests/bats/cicd-walls.bats` regression-lock file
- **ACTION**: Create new file `tests/bats/cicd-walls.bats`.
- **IMPLEMENT**: Write the file exactly as below:
  ```bash
  #!/usr/bin/env bats
  # ===========================================================================
  # Regression locks for the 6 CI/CD onboarding walls hit during the first
  # real-project onboarding (SCM MCP, Apr–May 2026). B1/B2/B3/B5/B6 were fixed
  # in the v0.3 cycle; C3 in Outpost v0.4 Phase 1. These tests fail loudly if a
  # fix is ever silently reverted.
  #
  # Wall catalog: docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md
  # All assertions are static-file greps — no cluster required, CI-safe.
  # ===========================================================================

  setup() {
    INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    PIPELINE="${INFRA_ROOT}/core/k8s/05-tekton/pipeline-build.yaml"
    TRIGGERTPL="${INFRA_ROOT}/core/k8s/05-tekton/triggertemplate.yaml"
    SECRETS="${INFRA_ROOT}/core/k8s/05-tekton/secrets.template.yaml"
    PHASE8="${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
    TRIGGERS=(
      "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml"
      "${INFRA_ROOT}/plugins/git-provider/github/trigger.yaml"
      "${INFRA_ROOT}/plugins/git-provider/gitlab/trigger.yaml"
    )
  }

  # ---- B1: pipeline params present ------------------------------------------
  @test "B1: pipeline-build.yaml declares the registry-push param" {
    grep -qE '^[[:space:]]*- name: registry-push' "$PIPELINE"
  }
  @test "B1: pipeline-build.yaml declares the pusher param" {
    grep -qE '^[[:space:]]*- name: pusher' "$PIPELINE"
  }
  @test "B1: triggertemplate passes image-tag into the PipelineRun" {
    grep -qE '^[[:space:]]*- name: image-tag' "$TRIGGERTPL"
  }

  # ---- B2: kaniko pushes to registry-push host (in-cluster Service) ---------
  @test "B2: build-and-push IMAGE uses params.registry-push" {
    grep -qF '$(params.registry-push)/$(params.repo-name)' "$PIPELINE"
  }
  @test "B2: registry-push param defaults to REGISTRY_PUSH_HOST" {
    grep -qF 'default: ${REGISTRY_PUSH_HOST}' "$PIPELINE"
  }

  # ---- B3: PipelineRun + per-task timeouts bumped ---------------------------
  @test "B3: triggertemplate sets a pipeline-level timeout in hours" {
    grep -qE 'pipeline:[[:space:]]*"[0-9]+h' "$TRIGGERTPL"
  }
  @test "B3: build-and-push task carries an explicit timeout" {
    grep -qE 'timeout:[[:space:]]*"[0-9]+m"' "$PIPELINE"
  }

  # ---- B5: git-credentials secret carries .gitconfig ------------------------
  @test "B5: secrets template ships .gitconfig with a credential helper" {
    grep -qF '.gitconfig:' "$SECRETS"
    grep -qF 'helper = store' "$SECRETS"
  }

  # ---- B6: tekton-pipelines namespace PSA downgraded to baseline ------------
  @test "B6: phase 8 labels tekton-pipelines ns PSA enforce=baseline" {
    grep -qF 'pod-security.kubernetes.io/enforce=baseline' "$PHASE8"
  }

  # ---- C3: webhook triggers only the deploy branch --------------------------
  @test "C3: no trigger.yaml accepts arbitrary branches via startsWith" {
    for f in "${TRIGGERS[@]}"; do
      if grep -qF "startsWith('refs/heads/')" "$f"; then
        echo "wall C3 regressed: $f still matches any branch" >&2
        return 1
      fi
    done
  }
  @test "C3: every trigger.yaml pins to OUTPOST_DEPLOY_BRANCH" {
    for f in "${TRIGGERS[@]}"; do
      if ! grep -qF "body.ref == 'refs/heads/\${OUTPOST_DEPLOY_BRANCH}'" "$f"; then
        echo "wall C3: $f does not pin the deploy branch" >&2
        return 1
      fi
    done
  }
  ```
- **MIRROR**: BATS_SETUP_AND_TEST_STRUCTURE. The file is intentionally self-contained — no `source` of any `platform/lib/*`, because every assertion is a static-file grep.
- **IMPORTS**: none.
- **GOTCHA**: Use `grep -F` (fixed string) for every pattern containing `$(...)` or `${...}` so shell-metacharacters are not interpreted as regex. Use `grep -E` only for the genuine regexes (param-name lines, timeout values). The C3 `${OUTPOST_DEPLOY_BRANCH}` literal inside a double-quoted string needs `\$` so bash does not expand it before `grep -F` sees it.
- **VALIDATE**: `bats tests/bats/cicd-walls.bats` — all 12 tests pass. Sanity-check the file actually fails on regression: temporarily revert one trigger.yaml line and confirm the C3 test goes red, then restore.

---

## Testing Strategy

### Unit Tests (bats — the deliverable IS the tests)

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| `B1: ...registry-push param` | `pipeline-build.yaml` | param line present | no |
| `B2: ...IMAGE uses registry-push` | `pipeline-build.yaml` | fixed string present | no |
| `B3: ...pipeline-level timeout` | `triggertemplate.yaml` | `pipeline: "Nh"` matches | no |
| `B5: ....gitconfig present` | `secrets.template.yaml` | `.gitconfig:` + `helper = store` | no |
| `B6: PSA baseline` | `08-argocd-tekton.sh` | label string present | no |
| `C3: no startsWith` | 3 × `trigger.yaml` | none contain `startsWith('refs/heads/')` | regression guard |
| `C3: pins deploy branch` | 3 × `trigger.yaml` | all contain pinned filter | regression guard |
| `assemble gitee/github/gitlab` | rendered EventListener | contains `refs/heads/main`, no `startsWith` | envsubst residue |

### Edge Cases Checklist
- [x] **Unset env var** — `OUTPOST_DEPLOY_BRANCH` unset → `render_template` residue check aborts loudly (not silently). Covered by `02-config.sh` default + bats setup() export.
- [x] **Branch deletion push** — `body.after` all-zeroes → still rejected by the retained `&& body.after != '000...'` clause.
- [x] **Tag push** — `refs/tags/v1` → rejected, since `== 'refs/heads/main'` cannot match a tag ref.
- [x] **Non-main repo** (`master`) — set `OUTPOST_DEPLOY_BRANCH=master` in `.env`; filter follows.
- [N/A] Concurrent access — static config, no runtime concurrency.
- [N/A] Network failure — no network in this change.

---

## Validation Commands

### Static Analysis
```bash
bash tests/lint.sh
```
EXPECT: Zero shellcheck / yamllint errors. (Confirms `02-config.sh` edit is clean bash and the 3 `trigger.yaml` edits are valid YAML.)

### Unit Tests — new + affected files
```bash
bats tests/bats/cicd-walls.bats
bats tests/bats/eventlistener-assemble.bats
```
EXPECT: `cicd-walls.bats` — 12/12 pass. `eventlistener-assemble.bats` — 9/9 pass (would be 0/9 if Task 6 setup() fix is missed — that is the canary).

### Full Test Suite
```bash
bats tests/bats/ tests/regression/
```
EXPECT: No regressions. (`makefile.bats`, `outpost-cli.bats`, etc. unaffected; the only file at risk is `eventlistener-assemble.bats`, addressed by Task 6.)

### Cross-check no stray renderer breaks
```bash
grep -rln 'assemble_eventlistener\|trigger\.yaml' tests/ bootstrap.d/ platform/
```
EXPECT: Only `bootstrap.d/08-argocd-tekton.sh`, `platform/lib/eventlistener-assemble.sh`, and `tests/bats/eventlistener-assemble.bats` render trigger.yaml — all three accounted for. If grep surfaces another renderer, it also needs `OUTPOST_DEPLOY_BRANCH` in scope.

### Manual Validation
- [ ] Render an EventListener by hand and eyeball the filter:
  ```bash
  set -a; ROOT_DOMAIN=x.test GIT_WEBHOOK_SECRET=t OUTPOST_DEPLOY_BRANCH=main; set +a
  source platform/lib/portable.sh platform/lib/cel-helpers.sh platform/lib/eventlistener-assemble.sh
  build_cel_whitelist
  assemble_eventlistener plugins/git-provider/gitee/trigger.yaml \
    core/k8s/05-tekton/eventlistener-base.yaml /tmp/el.yaml
  grep -n "body.ref" /tmp/el.yaml   # → refs/heads/main, no startsWith
  ```
- [ ] Negative test: revert one `trigger.yaml` line, run `bats tests/bats/cicd-walls.bats`, confirm a C3 test fails, then restore.

---

## Acceptance Criteria
- [ ] All 7 tasks completed
- [ ] `bash tests/lint.sh` passes
- [ ] `bats tests/bats/ tests/regression/` — all green, no regressions
- [ ] `tests/bats/cicd-walls.bats` — 12 tests, all pass
- [ ] All 3 `trigger.yaml` files pin `refs/heads/${OUTPOST_DEPLOY_BRANCH}`; none contain `startsWith('refs/heads/')`
- [ ] `OUTPOST_DEPLOY_BRANCH` defaults to `main`, is persisted to `.env`, documented in `.env.example`
- [ ] No type errors — N/A (bash project)
- [ ] Matches UX design — feature-branch push no longer deploys

## Completion Checklist
- [ ] Code follows discovered patterns (CONFIG_DEFAULT, CONFIG_PERSIST, BATS structure, ENVSUBST placeholder)
- [ ] Error handling matches codebase style — `render_template` residue check is the loud-failure mechanism; no new error handling needed
- [ ] Logging follows conventions — N/A (no new log lines)
- [ ] Tests follow the `tests/bats/` pattern
- [ ] No hardcoded values — `main` is a configurable default, not a hardcode
- [ ] Documentation updated — `.env.example` done; i18n docs + CHANGELOG deferred to PRD Phase 9 (explicit in NOT Building)
- [ ] No unnecessary scope additions
- [ ] Self-contained — no codebase searching needed during implementation

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `eventlistener-assemble.bats` setup() not updated → 9 tests abort on unresolved `${OUTPOST_DEPLOY_BRANCH}` | M (easy to forget) | High (CI red) | Task 6 makes it explicit and flags it as THE critical GOTCHA; the full-suite validation catches it |
| Another (undiscovered) renderer of `trigger.yaml` exists without the var in scope | L | Med | "Cross-check" validation command greps for all renderers before sign-off |
| Existing running cluster keeps the old any-branch EventListener until re-bootstrap | M | Low | Documented in Interaction Changes; re-running `bootstrap.sh` re-assembles the EL (Phase 8 always re-applies). Full migration tooling is out of scope |
| User's app repo uses `master`, forgets to set the var → pushes silently ignored | L | Med | `.env.example` comment explicitly calls out the `master` case; webhook delivery log in the provider UI shows the 200-but-filtered response |
| `grep -F` vs `grep -E` mismatch makes a regression test always-pass (false green) | L | High | Negative test in Manual Validation: revert a line, confirm red |

## Notes

- **Re-scope rationale**: PRD Phase 1 assumed 6 unfixed walls. Exploration (git log `7e32c13`/`eb5fdc7`/`6a1cba1`/`06b2fbe`/`890032f` + reading `pipeline-build.yaml`, `triggertemplate.yaml`, `secrets.template.yaml`, `08-argocd-tekton.sh`) proved B1/B2/B3/B5/B6 already fixed in the v0.3 cycle. Only C3 remained. The PRD's guessed file `eventlistener-base.yaml` for the CEL fix was also wrong — the ref filter lives in the per-provider `plugins/git-provider/*/trigger.yaml`. The PRD should be updated to reflect this (see the PRD's Phase 1 row + a new note).
- **Design decision — configurable vs hardcoded branch**: chose a configurable `OUTPOST_DEPLOY_BRANCH` (default `main`) over hardcoding `'refs/heads/main'`. Cost is ~4 extra lines (config default + persist + `.env.example`); benefit is repos on `master` are not silently broken, and it matches Outpost's env-driven config philosophy (cf. `MANIFEST_REPO_BRANCH`). PR-preview routing for *other* branches remains a separate v0.5 item.
- **Why static-file greps, not a live-cluster test**: the 6 walls are all configuration/manifest content. A grep-based bats file runs in CI on ubuntu + macos with zero cluster, matching how `tests/README.md` describes the unit layer. A live e2e test belongs to PRD Phase 8 (acceptance gauntlet).
- **`c1e1050 revert: 把 onboarding 编排移出 infras`**: discovered during exploration — a prior attempt put onboarding orchestration into infras and was reverted. Not relevant to Phase 1, but **must be investigated before planning PRD Phase 3/5** (`outpost onboard`). Flagged here so it is not lost.

---

*Generated: 2026-05-20*
*Source PRD phase: Phase 1 (re-scoped) — outpost-v0.4-real-project-onboarding.prd.md*
