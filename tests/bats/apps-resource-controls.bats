#!/usr/bin/env bats
# =============================================================================
# Apps namespace ResourceQuota + LimitRange.
#
# Guards the multi-tenant sizing that prevents two medium apps from choking
# each other in the shared `apps` ns. The pre-fix numbers (limits.cpu=8,
# defaultRequest.cpu=100m) hit 100% quota with a 2-app combo (omnipost +
# scm-mcp) even though actual request usage was only 23% — the quota
# model was over-reserving on limits where CPU should overcommit cleanly.
#
# Any future "tightening" of these numbers without bumping limits.cpu in
# tandem will re-introduce the same failure. These tests lock in the
# rationale via assertions on the actual values, with the manifest comment
# documenting WHY each one is what it is.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MANIFEST="${INFRA_ROOT}/core/k8s/02-apps-resource-controls.yaml"
  command -v yq >/dev/null 2>&1 || skip "yq (mikefarah v4+) required"
}

# ---- ResourceQuota: limits.cpu must allow >= 2 medium-app coexistence ----

@test "apps-quota limits.cpu >= 16 (two 5-deployment apps must coexist)" {
  v="$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard["limits.cpu"]' "$MANIFEST")"
  # Strip optional quotes and the optional 'm' suffix; treat as integer cores.
  v="${v//\"/}"
  [ -n "$v" ] || fail "limits.cpu missing from quota"
  # The pre-fix was 8 — anything <= 8 reintroduces the SCM MCP failure.
  [ "$v" -ge 16 ] || fail "limits.cpu='$v' too low; need ≥16 for 2-app coexistence"
}

@test "apps-quota requests.cpu >= 8 (matches 8-vCPU dev host baseline)" {
  v="$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard["requests.cpu"]' "$MANIFEST")"
  v="${v//\"/}"
  [ "$v" -ge 8 ] || fail "requests.cpu='$v' below 8-vCPU baseline"
}

@test "apps-quota limits.memory <= host_capacity_safety (no overcommit)" {
  # Memory is the ONE resource we don't overcommit. On a 32GB host, after
  # reserving ~8GB for OS/Docker/control plane, 24Gi is the practical max.
  # Higher than this risks host OOM.
  v="$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard["limits.memory"]' "$MANIFEST")"
  v="${v//\"/}"
  case "$v" in
    16Gi|20Gi|24Gi) : ;;  # safe range for 32GB host
    *) fail "limits.memory='$v' outside safe range [16Gi, 24Gi] for 32GB host" ;;
  esac
}

@test "apps-quota pods >= 30 (multi-tenant capacity)" {
  v="$(yq eval '. | select(.kind=="ResourceQuota") | .spec.hard.pods' "$MANIFEST")"
  v="${v//\"/}"
  [ "$v" -ge 30 ] || fail "pods='$v' too low for multi-tenant ns"
}

# ---- LimitRange: cheap-schedule defaults ----

@test "apps-defaults defaultRequest.cpu <= 100m (cheap container scheduling)" {
  v="$(yq eval '. | select(.kind=="LimitRange") | .spec.limits[0].defaultRequest.cpu' "$MANIFEST")"
  v="${v//\"/}"
  # Strip 'm' suffix to compare as integer millicores.
  ms="${v%m}"
  [ "$ms" -le 100 ] || fail "defaultRequest.cpu='$v' too high — apps won't fit"
}

@test "apps-defaults default (limit) cpu <= 500m (no implicit full-CPU claim)" {
  v="$(yq eval '. | select(.kind=="LimitRange") | .spec.limits[0].default.cpu' "$MANIFEST")"
  v="${v//\"/}"
  # Accept either "500m" or "1" (legacy) — but flag if 1 (means an undeclared
  # container still claims a full CPU against limits.cpu, choking the ns).
  case "$v" in
    50m|100m|250m|500m) : ;;
    *) fail "default.cpu='$v' too high — undeclared containers eat too much quota" ;;
  esac
}

@test "apps-defaults max.cpu == 4 (single-pod blast-radius cap)" {
  # max is the hard ceiling per container. 4 is the project default for
  # 'one container can't claim more than half the apps quota'. Don't bump
  # without also bumping limits.cpu in tandem.
  v="$(yq eval '. | select(.kind=="LimitRange") | .spec.limits[0].max.cpu' "$MANIFEST")"
  v="${v//\"/}"
  [ "$v" = "4" ] || fail "max.cpu='$v'; expected '4' (blast-radius cap)"
}

# ---- Documentation guard ----

@test "manifest header explains CPU overcommit + shared-tenancy philosophy" {
  # If a future maintainer sees the numbers and tries to "tighten" them
  # without reading the why, they'll re-create the SCM MCP failure. The
  # header is the only place that explains it — keep it.
  grep -qE 'overcommit|shared.*ns' "$MANIFEST" \
    || fail "manifest header missing overcommit/shared-tenancy explanation"
}
