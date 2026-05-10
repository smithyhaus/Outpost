#!/usr/bin/env bats
# =============================================================================
# Smoke test for the outpost CLI (scripts/outpost).
# Exercise help / version / unknown-subcommand paths — no kubectl side effects.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLI="${INFRA_ROOT}/scripts/outpost"
  [ -x "$CLI" ] || skip "scripts/outpost not executable"
}

@test "outpost: bash syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "outpost help: prints usage with all advertised subcommands" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "outpost" ]]
  for sub in status verify open logs rollback seal new-app decommission; do
    [[ "$output" == *"$sub"* ]] || { echo "missing subcommand in help: $sub"; return 1; }
  done
}

@test "outpost (no args): defaults to help" {
  run bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "USAGE" ]]
}

@test "outpost --help / -h: equivalent to help" {
  run bash "$CLI" --help
  [ "$status" -eq 0 ]
  run bash "$CLI" -h
  [ "$status" -eq 0 ]
}

@test "outpost version: prints something" {
  run bash "$CLI" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "outpost CLI" ]]
}

@test "outpost <unknown>: exits non-zero with hint" {
  run bash "$CLI" no-such-command
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown" ]]
}

@test "outpost open: requires target arg" {
  run bash "$CLI" open
  [ "$status" -ne 0 ]
}

@test "outpost open <unknown>: rejects with hint" {
  run bash "$CLI" open mars-rover
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown" ]] || [[ "$output" =~ "argocd" ]]
}

@test "outpost new-app: requires --lang" {
  run bash "$CLI" new-app foo
  [ "$status" -ne 0 ]
  [[ "$output" =~ "lang" ]]
}

@test "outpost rollback: requires app name" {
  run bash "$CLI" rollback
  [ "$status" -ne 0 ]
}

@test "outpost decommission: requires app name" {
  run bash "$CLI" decommission
  [ "$status" -ne 0 ]
}
