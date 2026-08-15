#!/usr/bin/env bats
# ===========================================================================
# Regression locks for the CI/CD walls that SURVIVED the v0.3.0 engine swap
# (Tekton+ArgoCD → GitHub Actions runner + manifest-sync). The original
# B1-B6/C3 walls died with the Tekton pipeline files; what must never
# silently regress now is the FAIL-not-WARN discipline the 9-day
# gitee-webhook incident bought:
#   W1  buildkitd readiness is a FAIL-level gate in verify.sh
#   W2  bootstrap keeps the 420s buildkitd wait (startupProbe budget)
#   W3  templated manifests go through render_template (no raw envsubst/cp)
#   W4  bootstrap's exit code is verify.sh's verdict (honest exit)
#   W5  sync heartbeat staleness / error is FAIL, never WARN
#   W6  reconciliation FAILs NAMING the repo (the ultimate judge)
#   W7  PAT-set + GitHub unreachable = FAIL; PAT-empty = WARN (documented)
#   W8  manifest-sync stays a single writer (concurrencyPolicy: Forbid)
#   W9  reset.sh preserves the local-path data dir unless --hard
#   W10 secrets (PAT / registration token) are never echoed by phase 8
#
# All assertions are static-file greps — no cluster required, CI-safe.
# ===========================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  VERIFY="${INFRA_ROOT}/verify.sh"
  PHASE8="${INFRA_ROOT}/bootstrap.d/08-ci.sh"
  SUMMARY="${INFRA_ROOT}/bootstrap.d/10-summary-full.sh"
  CRONJOB="${INFRA_ROOT}/core/k8s/03-ci/cronjob.template.yaml"
  RESET="${INFRA_ROOT}/reset.sh"
}

# ---- W1: buildkit gate stays FAIL-level in verify.sh ------------------------
@test "W1: verify.sh carries a FAIL-level buildkit.daemon check" {
  grep -qF 'record FAIL "buildkit.daemon"' "$VERIFY"
}
@test "W1: the old phase file is gone; 08-ci.sh replaced it" {
  [ ! -f "${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh" ]
  [ -f "$PHASE8" ]
}

# ---- W2: 420s buildkitd wait preserved in bootstrap -------------------------
@test "W2: phase 8 waits 420s for buildkitd Availability" {
  grep -qE 'kubectl wait .*deployment/buildkitd -n buildkit --timeout=420s' "$PHASE8"
}

# ---- W3: templates rendered via render_template, not raw apply --------------
@test "W3: cronjob template is applied via render_apply (strict residue check)" {
  grep -qF 'render_apply "core/k8s/03-ci/cronjob.template.yaml"' "$PHASE8"
  # and never applied raw (a raw apply would ship literal \${MANIFEST_SYNC_INTERVAL})
  ! grep -qE 'kubectl apply -f core/k8s/03-ci/cronjob.template.yaml' "$PHASE8"
}
@test "W3: outpost-verify.service is rendered, not copied raw" {
  grep -qF 'render_template "platform/systemd/outpost-verify.service"' "$PHASE8"
}

# ---- W4: honest exits --------------------------------------------------------
@test "W4: full-mode summary propagates verify.sh's verdict as bootstrap's exit code" {
  grep -qF 'bash verify.sh || VERIFY_STATUS=$?' "$SUMMARY"
  grep -qE 'VERIFY_STATUS.*-ne 0.*-ne 2' "$SUMMARY"
  grep -qE '^\s*exit 1' "$SUMMARY"
}
@test "W4: phase 8 first-sync heartbeat timeout is a hard exit, not a warn" {
  # the wait loop must terminate in `exit 1` on timeout AND on last_result error
  grep -qF 'manifest-sync first run produced no heartbeat' "$PHASE8"
  n=$(grep -cE '^\s*exit 1' "$PHASE8")
  [ "$n" -ge 2 ]
}

# ---- W5: heartbeat staleness/error = FAIL -----------------------------------
@test "W5: verify.sh FAILs on stale sync heartbeat" {
  grep -qF 'record FAIL "sync.heartbeat"' "$VERIFY"
  # staleness threshold is 3x the sync interval, in seconds
  grep -qE 'MANIFEST_SYNC_INTERVAL \* 60 \* 3' "$VERIFY"
}
@test "W5: verify.sh FAILs on last_result != ok and on missing CronJob" {
  grep -qF 'record FAIL "sync.result"' "$VERIFY"
  grep -qF 'record FAIL "sync.cronjob"' "$VERIFY"
}

# ---- W6: reconciliation names the repo --------------------------------------
@test "W6: verify.sh reconciliation exists and FAILs per-repo past the threshold" {
  grep -qF 'reconcile.$_id' "$VERIFY"
  grep -qF 'OUTPOST_STALENESS_THRESHOLD' "$VERIFY"
  grep -qE 'record FAIL "reconcile\.\$_id"' "$VERIFY"
}
@test "W6: reconciliation shares the manifest-map lib with update-manifest" {
  grep -qF 'scripts/lib/manifest-map.sh' "$VERIFY"
  grep -qF 'resolve_manifest_app_dir' "$VERIFY"
}

# ---- W7: CI trigger path asymmetry (PAT set vs empty) -----------------------
@test "W7: PAT set + api.github.com unreachable = FAIL 'CI trigger path down'" {
  grep -qF 'CI trigger path down' "$VERIFY"
  grep -qE 'record FAIL "ci\.runner\.online"' "$VERIFY"
}
@test "W7: PAT empty = WARN runner-not-configured (documented CI/e2e mode)" {
  grep -qE 'record WARN "ci\.runner" .*runner not configured' "$VERIFY"
}

# ---- W8: single-writer CD ----------------------------------------------------
@test "W8: manifest-sync CronJob keeps concurrencyPolicy Forbid" {
  grep -qE 'concurrencyPolicy:\s*Forbid' "$CRONJOB"
}

# ---- W9: reset data guardrail ------------------------------------------------
@test "W9: reset.sh preserves the local-path storage dir without --hard" {
  grep -qF '/var/lib/rancher/k3s/storage' "$RESET"
  grep -qF 'PRESERVE_DIR' "$RESET"
  # and carries the dump-first reminder
  grep -qiF 'DUMP FIRST' "$RESET"
}

# ---- W10: secret hygiene in phase 8 -----------------------------------------
@test "W10: phase 8 never echoes the PAT or a registration token" {
  # No echo/log/ok/warn line may interpolate the PAT or minted token.
  ! grep -nE '(echo|log |ok |warn ).*\$\{?GITHUB_RUNNER_PAT' "$PHASE8"
  ! grep -nE '(echo|log |ok |warn ).*\$\{?_REG_TOKEN' "$PHASE8"
}
@test "W10: notify-secrets creation pipes values into kubectl without logging" {
  grep -qF 'kubectl create secret generic notify-secrets' "$PHASE8"
  # the secret apply is silenced (no rendered secret ever hits stdout)
  grep -A3 'kubectl create secret generic notify-secrets' "$PHASE8" | grep -qF '>/dev/null'
}
