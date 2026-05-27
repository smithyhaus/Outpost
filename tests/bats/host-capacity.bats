#!/usr/bin/env bats
# =============================================================================
# Host capacity detection + apps-quota auto-sizing math.
#
# Guards platform/lib/host-capacity.sh — the formulas that turn raw host
# vCPU/RAM into ResourceQuota numbers must not silently drift. Override
# env vars (OUTPOST_HOST_CPU_OVERRIDE + OUTPOST_HOST_MEM_GB_OVERRIDE)
# pin the inputs so the formula is exercised deterministically across
# CI runners with different host specs.
#
# Reference outputs encoded here (per the formula in host-capacity.sh):
#   8GB  / 4-CPU      → pods=50  req_cpu=2  lim_cpu=8   req_mem=2 lim_mem=6
#   16GB / 8-CPU      → pods=50  req_cpu=4  lim_cpu=16  req_mem=4 lim_mem=12
#   32GB / 8-CPU      → pods=50  req_cpu=4  lim_cpu=16  req_mem=8 lim_mem=24
#   64GB / 16-CPU     → pods=50  req_cpu=8  lim_cpu=32  req_mem=16 lim_mem=48
#   2GB  / 1-CPU      → pods=50  req_cpu=1  lim_cpu=2   req_mem=1 lim_mem=3
#                       (floors kick in — never zero, never <3Gi limit)
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/host-capacity.sh
  source "${INFRA_ROOT}/platform/lib/host-capacity.sh"
}

# ---- Detection paths --------------------------------------------------------

@test "host_cpu_count honors OUTPOST_HOST_CPU_OVERRIDE" {
  OUTPOST_HOST_CPU_OVERRIDE=12 run host_cpu_count
  [ "$status" -eq 0 ]
  [ "$output" = "12" ]
}

@test "host_mem_gb honors OUTPOST_HOST_MEM_GB_OVERRIDE" {
  OUTPOST_HOST_MEM_GB_OVERRIDE=64 run host_mem_gb
  [ "$status" -eq 0 ]
  [ "$output" = "64" ]
}

@test "host_cpu_count without override returns a positive integer" {
  unset OUTPOST_HOST_CPU_OVERRIDE
  run host_cpu_count
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]
}

@test "host_mem_gb without override returns a positive integer >= 1" {
  unset OUTPOST_HOST_MEM_GB_OVERRIDE
  run host_mem_gb
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]
}

# ---- apps_quota_defaults — small laptop -------------------------------------

@test "apps_quota_defaults: 8GB / 4-CPU laptop → 50 2 8 2 6" {
  OUTPOST_HOST_CPU_OVERRIDE=4 OUTPOST_HOST_MEM_GB_OVERRIDE=8 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 2 8 2 6" ]
}

@test "apps_quota_defaults: 16GB / 8-CPU laptop → 50 4 16 4 12" {
  OUTPOST_HOST_CPU_OVERRIDE=8 OUTPOST_HOST_MEM_GB_OVERRIDE=16 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 4 16 4 12" ]
}

@test "apps_quota_defaults: 32GB / 8-CPU desktop → 50 4 16 8 24" {
  OUTPOST_HOST_CPU_OVERRIDE=8 OUTPOST_HOST_MEM_GB_OVERRIDE=32 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 4 16 8 24" ]
}

@test "apps_quota_defaults: 64GB / 16-CPU rig → 50 8 32 16 48" {
  OUTPOST_HOST_CPU_OVERRIDE=16 OUTPOST_HOST_MEM_GB_OVERRIDE=64 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 8 32 16 48" ]
}

# ---- Floor guarantees on very small hosts -----------------------------------

@test "apps_quota_defaults: 2GB / 1-CPU floors at requests.cpu=1, limits.memory=3" {
  # Without floors, integer math would give req_cpu=0, lim_mem=1 — both
  # unusable. host-capacity.sh's _max guards must keep the quota functional.
  OUTPOST_HOST_CPU_OVERRIDE=1 OUTPOST_HOST_MEM_GB_OVERRIDE=2 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 1 2 1 3" ]
}

@test "apps_quota_defaults: 4GB / 2-CPU stays above all floors" {
  OUTPOST_HOST_CPU_OVERRIDE=2 OUTPOST_HOST_MEM_GB_OVERRIDE=4 run apps_quota_defaults
  [ "$status" -eq 0 ]
  [ "$output" = "50 1 4 1 3" ]
}

# ---- Invariants -------------------------------------------------------------

@test "apps_quota_defaults: limits.cpu is always 2× host_cpu (overcommit allowed)" {
  for cpu in 4 6 8 12 16 24; do
    OUTPOST_HOST_CPU_OVERRIDE=$cpu OUTPOST_HOST_MEM_GB_OVERRIDE=32 run apps_quota_defaults
    [ "$status" -eq 0 ]
    # 3rd word = lim_cpu
    lim_cpu="$(echo "$output" | awk '{print $3}')"
    [ "$lim_cpu" -eq $(( cpu * 2 )) ] \
      || fail "host_cpu=$cpu → lim_cpu=$lim_cpu (expected $(( cpu * 2 )))"
  done
}

@test "apps_quota_defaults: requests.cpu is always <= limits.cpu" {
  for cpu in 1 2 4 8 16 32; do
    OUTPOST_HOST_CPU_OVERRIDE=$cpu OUTPOST_HOST_MEM_GB_OVERRIDE=32 run apps_quota_defaults
    [ "$status" -eq 0 ]
    req_cpu="$(echo "$output" | awk '{print $2}')"
    lim_cpu="$(echo "$output" | awk '{print $3}')"
    [ "$req_cpu" -le "$lim_cpu" ] \
      || fail "host_cpu=$cpu → req_cpu=$req_cpu > lim_cpu=$lim_cpu (invariant broken)"
  done
}

@test "apps_quota_defaults: requests.memory <= limits.memory (memory cannot overcommit)" {
  for mem in 2 4 8 16 32 64 128; do
    OUTPOST_HOST_CPU_OVERRIDE=8 OUTPOST_HOST_MEM_GB_OVERRIDE=$mem run apps_quota_defaults
    [ "$status" -eq 0 ]
    req_mem="$(echo "$output" | awk '{print $4}')"
    lim_mem="$(echo "$output" | awk '{print $5}')"
    [ "$req_mem" -le "$lim_mem" ] \
      || fail "host_mem=$mem → req_mem=$req_mem > lim_mem=$lim_mem (invariant broken)"
  done
}
