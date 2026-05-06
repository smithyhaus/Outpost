#!/usr/bin/env bats
# REGRESSION (mandated by plan-eng-review).
#
# Invariant: rendering plugins/registry/self-hosted/manifest.yaml through
# render_template yields the same Kubernetes object set as the legacy
# (pre-plugin-abstraction) k8s/03-registry/registry.yaml.
#
# We freeze a "golden" manifest under tests/regression/golden/ and diff
# the rendered output against it. Any difference is a regression in the
# default plugin's behaviour for existing users.

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  TMP=$(mktemp -d)
  export ROOT_DOMAIN="example.test"
}
teardown() { rm -rf "$TMP"; }

@test "self-hosted registry plugin renders to the locked golden manifest" {
  render_template \
    "${INFRA_ROOT}/plugins/registry/self-hosted/manifest.yaml" \
    "$TMP/rendered.yaml"

  golden="${BATS_TEST_DIRNAME}/golden/registry-self-hosted.yaml"
  [ -f "$golden" ] || skip "golden file missing — first run; copy $TMP/rendered.yaml into place to lock it"

  run diff -u "$golden" "$TMP/rendered.yaml"
  [ "$status" -eq 0 ] || {
    echo "Default plugin output drifted from the locked golden."
    echo "If intentional, review the diff carefully and update the golden:"
    echo "  cp '$TMP/rendered.yaml' '$golden'"
    return 1
  }
}
