#!/usr/bin/env bats
# =============================================================================
# `outpost off-board <name>` — inverse of onboard.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLI="${INFRA_ROOT}/scripts/outpost"
  [ -x "$CLI" ] || skip "scripts/outpost not executable"
  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"

  FRAG_DIR="${INFRA_ROOT}/core/compose/Caddyfile.d"
  OV_DIR="${INFRA_ROOT}/core/compose/overrides"
  STAGED_FRAG="${FRAG_DIR}/bats-offboard.caddy"
  STAGED_OV="${OV_DIR}/bats-offboard.yml"
}

teardown() {
  rm -f "$STAGED_FRAG" "$STAGED_OV"
}

@test "outpost off-board: no args → usage error" {
  run bash "$CLI" off-board
  [ "$status" -ne 0 ]
  [[ "$output" =~ "off-board" ]]
}

@test "outpost off-board: nonexistent name → no-op message, exit 0" {
  run bash "$CLI" off-board no-such-app-$$
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing to off-board" ]]
}

@test "outpost off-board: removes staged Caddy fragment + compose override" {
  mkdir -p "$FRAG_DIR" "$OV_DIR"
  # Stage a fake onboarded app's artefacts directly (skip the onboard
  # roundtrip — keeps this test fast + isolated).
  cat > "$STAGED_FRAG" <<'EOF'
# fake fragment for bats off-board test
@bats_offboard host bats.example.com
handle @bats_offboard { respond "x" 200 }
EOF
  cat > "$STAGED_OV" <<'EOF'
name: infra
services:
  bats-offboard:
    image: nginx:alpine
EOF
  [ -f "$STAGED_FRAG" ]
  [ -f "$STAGED_OV" ]

  run bash "$CLI" off-board bats-offboard --keep-running
  [ "$status" -eq 0 ]
  [ ! -f "$STAGED_FRAG" ]
  [ ! -f "$STAGED_OV" ]
}

@test "outpost off-board: --keep-running skips the docker compose stop step" {
  mkdir -p "$FRAG_DIR" "$OV_DIR"
  cat > "$STAGED_FRAG" <<'EOF'
# bats fragment
EOF
  cat > "$STAGED_OV" <<'EOF'
services: { bats-offboard: { image: nginx } }
EOF
  run bash "$CLI" off-board bats-offboard --keep-running
  [ "$status" -eq 0 ]
  # No "stopped + removed container" line when --keep-running is set.
  ! [[ "$output" =~ "stopped + removed container" ]]
}

@test "outpost off-board: idempotent — second invocation also exit 0" {
  mkdir -p "$FRAG_DIR" "$OV_DIR"
  echo "# x" > "$STAGED_FRAG"
  echo "services: { bats-offboard: { image: nginx } }" > "$STAGED_OV"
  run bash "$CLI" off-board bats-offboard --keep-running
  [ "$status" -eq 0 ]
  # Second run finds nothing to do — still exit 0, no error.
  run bash "$CLI" off-board bats-offboard --keep-running
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing to off-board" ]]
}

@test "outpost help: advertises off-board subcommand" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "off-board" ]]
}
