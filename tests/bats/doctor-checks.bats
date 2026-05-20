#!/usr/bin/env bats
# =============================================================================
# Unit tests for platform/lib/doctor-checks.sh — the synthetic-failure suite.
# Each pure check function is exercised on its free/busy, valid/invalid paths.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/doctor-checks.sh
  source "${INFRA_ROOT}/platform/lib/doctor-checks.sh"
}

# ---- doctor_port_state ------------------------------------------------------
@test "doctor_port_state: a free high port reports free" {
  [ "$(doctor_port_state 49231)" = "free" ]
}

@test "doctor_port_state: an occupied port reports busy" {
  command -v nc >/dev/null || skip "nc not available"
  nc -l 49232 >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  run doctor_port_state 49232
  kill "$pid" 2>/dev/null || true
  [ "$output" = "busy" ]
}

# ---- doctor_cf_token_state (synthetic: bad CF token → invalid) --------------
@test "doctor_cf_token_state: empty token is invalid" {
  [ "$(doctor_cf_token_state '')" = "invalid" ]
}

@test "doctor_cf_token_state: short junk is invalid" {
  [ "$(doctor_cf_token_state 'not-a-token')" = "invalid" ]
}

@test "doctor_cf_token_state: a long base64url string is valid" {
  local tok
  tok=$(printf 'A%.0s' {1..120})
  [ "$(doctor_cf_token_state "$tok")" = "valid" ]
}

# ---- doctor_dns_state -------------------------------------------------------
@test "doctor_dns_state: a bogus .invalid domain is nxdomain" {
  [ "$(doctor_dns_state 'no-such-host.invalid')" = "nxdomain" ]
}

# ---- doctor_port_holder degrades gracefully ---------------------------------
@test "doctor_port_holder: returns without error (string may be empty)" {
  run doctor_port_holder 49233
  [ "$status" -eq 0 ]
}
