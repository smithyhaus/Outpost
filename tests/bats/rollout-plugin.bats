#!/usr/bin/env bats
# =============================================================================
# Tests for plugins/rollout/argo-rollouts
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
  [ -f "${PLUGIN_DIR}/ingressroute.yaml" ]
  [ -x "${PLUGIN_DIR}/preflight.sh" ]
  [ -f "${PLUGIN_DIR}/README.md" ]
  grep -q '^kind: rollout' "${PLUGIN_DIR}/plugin.yaml"
}

@test "preflight passes with no env" {
  run env -i bash "${PLUGIN_DIR}/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "manifest renders cleanly" {
  out="${TMP}/manifest.yaml"
  render_template "${PLUGIN_DIR}/manifest.yaml" "$out"
  ! grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out"
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

@test "ingressroute uses ROLLOUTS_DASHBOARD_HOST" {
  grep -q 'ROLLOUTS_DASHBOARD_HOST' "${PLUGIN_DIR}/ingressroute.yaml"
}

@test "ingressroute renders cleanly with sample env" {
  export ROOT_DOMAIN="smoke.example.test"
  export ROLLOUTS_DASHBOARD_HOST="rollouts.smoke.example.test"
  out="${TMP}/ingressroute.yaml"
  render_template "${PLUGIN_DIR}/ingressroute.yaml" "$out"
  ! grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out"
}
