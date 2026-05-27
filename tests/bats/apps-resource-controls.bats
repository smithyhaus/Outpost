#!/usr/bin/env bats
# =============================================================================
# Apps namespace ResourceQuota + LimitRange template.
#
# Guards the multi-tenant sizing that prevents two medium apps from choking
# each other in the shared `apps` ns. The pre-fix numbers (limits.cpu=8,
# defaultRequest.cpu=100m) hit 100% quota with a 2-app combo even though
# actual request usage was at 23% — the quota model was over-reserving on
# limits where CPU should overcommit cleanly.
#
# Since numbers are now host-dynamic (platform/lib/host-capacity.sh), these
# tests verify (a) the template carries every ${OUTPOST_APPS_*} placeholder,
# (b) it renders cleanly with a 32GB/8-CPU fixture and produces the expected
# numbers, (c) the strict-render check catches missing vars, and (d) the
# header documents the overcommit philosophy so a future maintainer doesn't
# undo the design.
#
# The math itself (different host sizes → different numbers) is covered by
# tests/bats/host-capacity.bats.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEMPLATE="${INFRA_ROOT}/core/k8s/02-apps-resource-controls.template.yaml"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  command -v yq       >/dev/null 2>&1 || skip "yq (mikefarah v4+) required"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

# ---- Template shape (host-independent invariants) ---------------------------

@test "template carries every OUTPOST_APPS_ placeholder" {
  [ -r "$TEMPLATE" ]
  for v in PODS_MAX REQUESTS_CPU LIMITS_CPU REQUESTS_MEMORY LIMITS_MEMORY \
           DEFAULT_REQUEST_CPU DEFAULT_REQUEST_MEMORY \
           DEFAULT_LIMIT_CPU   DEFAULT_LIMIT_MEMORY \
           MAX_CPU MAX_MEMORY; do
    grep -qE "\\\$\\{OUTPOST_APPS_${v}\\}" "$TEMPLATE" \
      || { echo "missing placeholder OUTPOST_APPS_${v}"; return 1; }
  done
}

@test "template strict-render rejects when any OUTPOST_APPS_* is unset" {
  # Set 10 of 11; unset the 11th (limits.cpu) — strict check must fire.
  export OUTPOST_APPS_PODS_MAX=50
  export OUTPOST_APPS_REQUESTS_CPU=4
  unset  OUTPOST_APPS_LIMITS_CPU
  export OUTPOST_APPS_REQUESTS_MEMORY=8Gi
  export OUTPOST_APPS_LIMITS_MEMORY=24Gi
  export OUTPOST_APPS_DEFAULT_REQUEST_CPU=50m
  export OUTPOST_APPS_DEFAULT_REQUEST_MEMORY=64Mi
  export OUTPOST_APPS_DEFAULT_LIMIT_CPU=500m
  export OUTPOST_APPS_DEFAULT_LIMIT_MEMORY=512Mi
  export OUTPOST_APPS_MAX_CPU=4
  export OUTPOST_APPS_MAX_MEMORY=8Gi
  run render_template "$TEMPLATE" "$TMP/should-not-exist.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "OUTPOST_APPS_LIMITS_CPU" ]]
}

# ---- Renders correctly with a 32GB / 8-CPU fixture --------------------------

@test "renders with 32GB/8-CPU fixture → limits.cpu=16, limits.memory=24Gi" {
  export OUTPOST_APPS_PODS_MAX=50
  export OUTPOST_APPS_REQUESTS_CPU=4
  export OUTPOST_APPS_LIMITS_CPU=16
  export OUTPOST_APPS_REQUESTS_MEMORY=8Gi
  export OUTPOST_APPS_LIMITS_MEMORY=24Gi
  export OUTPOST_APPS_DEFAULT_REQUEST_CPU=50m
  export OUTPOST_APPS_DEFAULT_REQUEST_MEMORY=64Mi
  export OUTPOST_APPS_DEFAULT_LIMIT_CPU=500m
  export OUTPOST_APPS_DEFAULT_LIMIT_MEMORY=512Mi
  export OUTPOST_APPS_MAX_CPU=4
  export OUTPOST_APPS_MAX_MEMORY=8Gi

  out="$TMP/rendered.yaml"
  run render_template "$TEMPLATE" "$out"
  [ "$status" -eq 0 ]
  # Compare via yq so quoting variations don't matter.
  [ "$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard["limits.cpu"]'    "$out")" = "16" ]
  [ "$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard["limits.memory"]' "$out")" = "24Gi" ]
  [ "$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard.pods'             "$out")" = "50" ]
  [ "$(yq eval '. | select(.kind=="LimitRange")    | .spec.limits[0].defaultRequest.cpu' "$out")" = "50m" ]
  [ "$(yq eval '. | select(.kind=="LimitRange")    | .spec.limits[0].default.cpu'        "$out")" = "500m" ]
  [ "$(yq eval '. | select(.kind=="LimitRange")    | .spec.limits[0].max.cpu'            "$out")" = "4" ]
}

# ---- Documentation guard ----------------------------------------------------

@test "template header explains CPU overcommit + dynamic-per-host philosophy" {
  # If a future maintainer sees the placeholders and tries to revert to
  # hardcoded numbers, the header must steer them toward the right answer.
  grep -qE 'overcommit|shared.*ns' "$TEMPLATE" \
    || fail "template header missing CPU-overcommit philosophy"
  grep -qE 'Dynamic per host|sysctl|nproc' "$TEMPLATE" \
    || fail "template header missing dynamic-host explanation"
}

@test "phase 2 sources host-capacity lib + sets all 11 OUTPOST_APPS_* defaults" {
  PHASE2="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  grep -q 'apps_quota_defaults' "$PHASE2" \
    || fail "phase 2 doesn't invoke apps_quota_defaults"
  for v in PODS_MAX REQUESTS_CPU LIMITS_CPU REQUESTS_MEMORY LIMITS_MEMORY \
           DEFAULT_REQUEST_CPU DEFAULT_REQUEST_MEMORY \
           DEFAULT_LIMIT_CPU   DEFAULT_LIMIT_MEMORY \
           MAX_CPU MAX_MEMORY; do
    grep -qE "^OUTPOST_APPS_${v}=" "$PHASE2" \
      || { echo "phase 2 missing default for OUTPOST_APPS_${v}"; return 1; }
  done
}

@test "phase 5 renders the template (not the obsolete static .yaml)" {
  PHASE5="${INFRA_ROOT}/bootstrap.d/05-k3s.sh"
  grep -q 'render_apply.*02-apps-resource-controls.template.yaml' "$PHASE5"
  # The pre-fix used `kubectl apply -f .../02-apps-resource-controls.yaml`
  # (static) — re-introducing that would hardcode 32GB numbers on every host.
  ! grep -qE '^kubectl apply -f core/k8s/02-apps-resource-controls\.yaml' "$PHASE5"
}
