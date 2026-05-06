#!/usr/bin/env bats
# Lock the JSON output shape of verify.sh against tests/schema/verify-output.schema.json
#
# This is the AI-contract test. If verify.sh ever drifts from the schema,
# every AI integration that parses its output silently breaks.

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "verify.sh --json produces shape conforming to the locked schema" {
  if ! command -v jq >/dev/null; then
    skip "jq not available"
  fi
  out=$(cd "$INFRA_ROOT" && bash verify.sh --json 2>/dev/null || true)

  # 1. Valid JSON
  echo "$out" | jq -e . >/dev/null

  # 2. Top-level required fields
  echo "$out" | jq -e '.schema_version == "1"' >/dev/null
  echo "$out" | jq -e '.summary | has("pass") and has("warn") and has("fail") and has("os")' >/dev/null
  echo "$out" | jq -e '.checks | type == "array"' >/dev/null

  # 3. Every check has the right shape
  echo "$out" | jq -e '.checks | all(.status as $s | (["PASS","WARN","FAIL"] | index($s)) != null)' >/dev/null
  echo "$out" | jq -e '.checks | all(.id | type == "string" and length > 0)' >/dev/null
  echo "$out" | jq -e '.checks | all(.detail | type == "string")' >/dev/null

  # 4. summary counts equal grouping of checks
  pass=$(echo "$out" | jq '[.checks[]|select(.status=="PASS")] | length')
  warn=$(echo "$out" | jq '[.checks[]|select(.status=="WARN")] | length')
  fail=$(echo "$out" | jq '[.checks[]|select(.status=="FAIL")] | length')
  s_pass=$(echo "$out" | jq '.summary.pass')
  s_warn=$(echo "$out" | jq '.summary.warn')
  s_fail=$(echo "$out" | jq '.summary.fail')
  [ "$pass" = "$s_pass" ]
  [ "$warn" = "$s_warn" ]
  [ "$fail" = "$s_fail" ]
}
