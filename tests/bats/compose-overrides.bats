#!/usr/bin/env bats
# =============================================================================
# Convention: core/compose/overrides/*.yml is auto-included by both the
# bootstrap pipeline and status.sh. Onboarded compose-tier apps drop a single
# YAML there; nothing else needs to be wired.
#
# These tests assert the convention is real (not just documented), so future
# refactors of 04-compose.sh / status.sh that drop the glob break the build
# instead of silently severing the auto-start path.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPOSE_PHASE="${INFRA_ROOT}/bootstrap.d/04-compose.sh"
  STATUS="${INFRA_ROOT}/status.sh"
}

@test "04-compose.sh: auto-includes overrides/*.yml via nullglob loop" {
  run grep -E 'core/compose/overrides/.*\.yml' "$COMPOSE_PHASE"
  [ "$status" -eq 0 ]
  run grep -E 'shopt -s nullglob' "$COMPOSE_PHASE"
  [ "$status" -eq 0 ]
  # The loop must call `COMPOSE_ARGS+=(-f ...)` so each override participates
  # in every `docker compose` invocation downstream.
  run grep -E 'COMPOSE_ARGS\+=\(-f "\$_override"\)' "$COMPOSE_PHASE"
  [ "$status" -eq 0 ]
}

@test "status.sh: auto-includes overrides/*.yml in the compose ps invocation" {
  run grep -E 'core/compose/overrides/.*\.yml' "$STATUS"
  [ "$status" -eq 0 ]
  run grep -E 'COMPOSE_ARGS\+=\(-f "\$_override"\)' "$STATUS"
  [ "$status" -eq 0 ]
}

@test "outpost onboard --no-up (tier=compose): skips compose up but still renders" {
  CLI="${INFRA_ROOT}/scripts/outpost"
  TEST_TMPDIR="$(mktemp -d)"
  trap '[[ -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"' EXIT

  mkdir -p "$TEST_TMPDIR/app"
  # --no-up is meaningful only for tier=compose (k3s doesn't run `compose up`
  # at all). Stateful-infra is the canonical tier=compose example after the
  # tier contract was enforced.
  cp "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example" "$TEST_TMPDIR/app/outpost.app.yaml"

  # --no-up exits cleanly even if docker isn't reachable in the test env.
  run bash "$CLI" onboard "$TEST_TMPDIR/app" --no-up --no-reload --force
  [ "$status" -eq 0 ]
  # Must NOT have tried to run `docker compose up`.
  ! [[ "$output" =~ "started service" ]]
  # Must have written the fragment + override (tier=compose path).
  [ -r "${INFRA_ROOT}/core/compose/Caddyfile.d/elasticsearch.caddy" ]
  [ -r "${INFRA_ROOT}/core/compose/overrides/elasticsearch.yml" ]
  # Cleanup the side effects (gitignored, but keeps the working tree clean).
  rm -f "${INFRA_ROOT}/core/compose/Caddyfile.d/elasticsearch.caddy"
  rm -f "${INFRA_ROOT}/core/compose/overrides/elasticsearch.yml"
}
