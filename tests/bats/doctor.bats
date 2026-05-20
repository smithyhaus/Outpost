#!/usr/bin/env bats
# =============================================================================
# End-to-end tests for doctor.sh — JSON shape (the AI contract), exit codes,
# fix_hint presence, and CLI wiring.
#
# doctor.sh has top-level executable code, so these run it as a subprocess
# (never `source` it).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  DOCTOR="${INFRA_ROOT}/doctor.sh"
  CLI="${INFRA_ROOT}/scripts/outpost"
}

@test "doctor.sh: bash syntax is valid" {
  run bash -n "$DOCTOR"
  [ "$status" -eq 0 ]
}

@test "doctor.sh: human run prints a Summary and exits 0/1/2" {
  run bash "$DOCTOR"
  [[ "$output" =~ "Summary" ]]
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
}

@test "doctor.sh --json: valid JSON conforming to the locked schema shape" {
  command -v jq >/dev/null || skip "jq not available"
  out=$(cd "$INFRA_ROOT" && bash doctor.sh --json 2>/dev/null || true)

  # 1. Valid JSON + top-level shape
  echo "$out" | jq -e . >/dev/null
  echo "$out" | jq -e '.schema_version == "1"' >/dev/null
  echo "$out" | jq -e '.summary | has("pass") and has("warn") and has("fail") and has("os")' >/dev/null
  echo "$out" | jq -e '.checks | type == "array"' >/dev/null

  # 2. Every check carries all 4 fields incl. fix_hint, with a valid status
  echo "$out" | jq -e '.checks | all(has("status") and has("id") and has("detail") and has("fix_hint"))' >/dev/null
  echo "$out" | jq -e '.checks | all(.status as $s | (["PASS","WARN","FAIL"]|index($s)) != null)' >/dev/null
  echo "$out" | jq -e '.checks | all(.fix_hint | type == "string")' >/dev/null

  # 3. summary counts equal the grouping of checks
  [ "$(echo "$out" | jq '[.checks[]|select(.status=="PASS")]|length')" = "$(echo "$out" | jq '.summary.pass')" ]
  [ "$(echo "$out" | jq '[.checks[]|select(.status=="FAIL")]|length')" = "$(echo "$out" | jq '.summary.fail')" ]
}

@test "doctor.sh --egress <bogus>: forces a FAIL check carrying a non-empty fix_hint" {
  command -v jq >/dev/null || skip "jq not available"
  # --egress is a CLI arg (immune to .env), so this reliably drives the full
  # doctor.sh pipeline end-to-end into a FAIL + fix_hint.
  out=$(cd "$INFRA_ROOT" && bash doctor.sh --json --egress no-such-host.invalid 2>/dev/null || true)
  echo "$out" | jq -e '.checks[] | select(.id | startswith("egress.")) | select(.status == "FAIL") | .fix_hint | length > 0' >/dev/null
}

@test "doctor.sh --egress with no value terminates (no arg-parser loop)" {
  # Regression lock: `--egress` as the last arg once hung forever — `shift 2`
  # was a no-op when only one positional remained, so the parse loop spun.
  bash "$DOCTOR" --quiet --egress >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "doctor.sh --egress (no value) did not terminate within ${waited}s"
    return 1
  fi
}

@test "outpost CLI: doctor subcommand is wired and runs" {
  run bash "$CLI" doctor --json
  [[ "$status" -eq 0 || "$status" -eq 1 || "$status" -eq 2 ]]
  [[ "$output" =~ "schema_version" ]]
}
