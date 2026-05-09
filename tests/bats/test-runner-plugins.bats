#!/usr/bin/env bats
# =============================================================================
# Tests for plugins/test-runner/*
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN_DIR="${INFRA_ROOT}/plugins/test-runner"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

@test "every test-runner plugin has the expected file shape" {
  for p in testkube catalog-tasks; do
    [ -f "${PLUGIN_DIR}/${p}/plugin.yaml" ] || fail "${p}: plugin.yaml missing"
    [ -f "${PLUGIN_DIR}/${p}/manifest.yaml" ] || fail "${p}: manifest.yaml missing"
    [ -x "${PLUGIN_DIR}/${p}/preflight.sh" ] || fail "${p}: preflight.sh missing/not executable"
    [ -f "${PLUGIN_DIR}/${p}/README.md" ] || fail "${p}: README.md missing"
    grep -q '^kind: test-runner' "${PLUGIN_DIR}/${p}/plugin.yaml" || fail "${p}: kind is not 'test-runner'"
  done
}

@test "testkube preflight passes in oss mode without env" {
  run env -i bash "${PLUGIN_DIR}/testkube/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "testkube preflight fails in cloud mode without API key" {
  run env -i TESTKUBE_MODE=cloud bash "${PLUGIN_DIR}/testkube/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "TESTKUBE_CLOUD_API_KEY" ]]
}

@test "testkube preflight passes in cloud mode with API key" {
  run env -i TESTKUBE_MODE=cloud TESTKUBE_CLOUD_API_KEY=tkcapi_smoke \
    bash "${PLUGIN_DIR}/testkube/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "testkube preflight rejects unknown mode" {
  run env -i TESTKUBE_MODE=hybrid bash "${PLUGIN_DIR}/testkube/preflight.sh"
  [ "$status" -ne 0 ]
}

@test "catalog-tasks preflight passes with no env" {
  run env -i bash "${PLUGIN_DIR}/catalog-tasks/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "testkube manifest renders cleanly" {
  export TESTKUBE_MODE="oss"
  out="${TMP}/testkube.yaml"
  render_template "${PLUGIN_DIR}/testkube/manifest.yaml" "$out"
  ! grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out"
}

@test "catalog-tasks manifest renders cleanly (no env required)" {
  out="${TMP}/catalog-tasks.yaml"
  render_template "${PLUGIN_DIR}/catalog-tasks/manifest.yaml" "$out"
  ! grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out"
}
