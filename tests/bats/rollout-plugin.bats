#!/usr/bin/env bats
# =============================================================================
# Tests for plugins/rollout/argo-rollouts
#
# v0.3: controller-only, default OFF (ROLLOUT_PLUGIN=none). No dashboard, no
# ingressroute.yaml, no ROLLOUTS_DASHBOARD_HOST — those retired with
# ArgoCD/Tekton's shared BasicAuth dashboard tier.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN_DIR="${INFRA_ROOT}/plugins/rollout/argo-rollouts"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

@test "argo-rollouts plugin has the expected file shape" {
  [ -f "${PLUGIN_DIR}/plugin.yaml" ]
  [ -f "${PLUGIN_DIR}/manifest.yaml" ]
  [ -f "${PLUGIN_DIR}/analysistemplate-default.yaml" ]
  [ -f "${PLUGIN_DIR}/analysistemplate-smoke.yaml" ]
  [ -x "${PLUGIN_DIR}/preflight.sh" ]
  [ -f "${PLUGIN_DIR}/README.md" ]
  grep -q '^kind: rollout' "${PLUGIN_DIR}/plugin.yaml"
}

@test "ingressroute.yaml was removed (dashboard retired in v0.3)" {
  [ ! -f "${PLUGIN_DIR}/ingressroute.yaml" ]
}

@test "preflight passes with no env" {
  run env -i bash "${PLUGIN_DIR}/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "manifest renders cleanly with no env (controller-only, no placeholders)" {
  out="${TMP}/manifest.yaml"
  render_template "${PLUGIN_DIR}/manifest.yaml" "$out"
  ! grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out"
}

@test "manifest's ConfigMap targets the argo-rollouts namespace (tekton-pipelines is gone in v0.3)" {
  grep -q 'namespace: argo-rollouts' "${PLUGIN_DIR}/manifest.yaml"
  ! grep -qE '^\s*namespace:\s*tekton-pipelines' "${PLUGIN_DIR}/manifest.yaml"
}

@test "analysistemplate-default uses locked thresholds (failureLimit=2, consecutiveErrorLimit=3)" {
  grep -q 'failureLimit: 2' "${PLUGIN_DIR}/analysistemplate-default.yaml"
  grep -q 'consecutiveErrorLimit: 3' "${PLUGIN_DIR}/analysistemplate-default.yaml"
}

@test "analysistemplate-smoke uses Job provider with testkube CLI" {
  grep -q 'provider:' "${PLUGIN_DIR}/analysistemplate-smoke.yaml"
  grep -q 'job:' "${PLUGIN_DIR}/analysistemplate-smoke.yaml"
  grep -q 'kubeshop/testkube-cli' "${PLUGIN_DIR}/analysistemplate-smoke.yaml"
}

@test "plugin.yaml documents default OFF (ROLLOUT_PLUGIN=none)" {
  grep -q 'Default OFF' "${PLUGIN_DIR}/plugin.yaml"
}

@test "plugin.yaml no longer declares ROLLOUTS_DASHBOARD_HOST as optional_env (removed var)" {
  ! grep -q 'ROLLOUTS_DASHBOARD_HOST' "${PLUGIN_DIR}/plugin.yaml"
}
