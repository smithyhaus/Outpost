#!/usr/bin/env bats
# =============================================================================
# Caddyfile env-driven routing + fragment loading.
#
# Guards three invariants introduced by the env-ify refactor (v0.5):
#   1. The main Caddyfile contains no hardcoded subdomain prefixes or upstream
#      container:port pairs for built-in services — they must be {$VAR:default}.
#   2. The main Caddyfile imports per-app fragments from Caddyfile.d/*.caddy.
#   3. The compose caddy service mounts Caddyfile.d/ and exports the override
#      env vars (so Caddy's {$VAR:default} resolution sees them).
#
# These prevent regression back to the per-app-edit anti-pattern documented in
# ADR 0002 (docs/decisions/0002-onboarding-primitives-in-platform.md).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CADDYFILE="${INFRA_ROOT}/core/compose/Caddyfile"
  COMPOSE="${INFRA_ROOT}/core/compose/docker-compose.yml"
  FRAG_DIR="${INFRA_ROOT}/core/compose/Caddyfile.d"
  [ -r "$CADDYFILE" ] || skip "core/compose/Caddyfile missing"
}

@test "Caddyfile: built-in routes use {\$VAR:default} for host prefix" {
  # Hardcoded `host search.{\$ROOT_DOMAIN}` or `host mq.{\$ROOT_DOMAIN}` is the
  # anti-pattern. The new form is `host {\$SEARCH_HOST:search}.{\$ROOT_DOMAIN}`.
  run grep -E '^\s*@search\s+host\s+\{\$SEARCH_HOST:' "$CADDYFILE"
  [ "$status" -eq 0 ]
  run grep -E '^\s*@mq\s+host\s+\{\$MQ_HOST:' "$CADDYFILE"
  [ "$status" -eq 0 ]
}

@test "Caddyfile: built-in routes use {\$VAR:default} for upstream" {
  run grep -E 'reverse_proxy\s+\{\$SEARCH_UPSTREAM:' "$CADDYFILE"
  [ "$status" -eq 0 ]
  run grep -E 'reverse_proxy\s+\{\$MQ_UPSTREAM:' "$CADDYFILE"
  [ "$status" -eq 0 ]
}

@test "Caddyfile: imports per-app fragments from Caddyfile.d/" {
  run grep -E '^\s*import\s+/etc/caddy/Caddyfile\.d/\*\.caddy' "$CADDYFILE"
  [ "$status" -eq 0 ]
}

@test "Caddyfile: no hardcoded SCM-MCP / per-app routes leaked back in" {
  # Application-specific upstream container names belong in the app's own
  # repo, never in core/compose/Caddyfile. Block reintroduction of the
  # specific anti-pattern that triggered the v0.5 refactor.
  run grep -E 'scm-mcp-app|reverse_proxy scm-mcp' "$CADDYFILE"
  [ "$status" -ne 0 ]
}

@test "Caddyfile.d/: directory exists and is committed (has .gitkeep)" {
  [ -d "$FRAG_DIR" ]
  [ -e "$FRAG_DIR/.gitkeep" ]
}

@test "Caddyfile.d/: README documents the contract" {
  [ -r "$FRAG_DIR/README.md" ]
  run grep -E 'outpost onboard|Caddyfile\.d' "$FRAG_DIR/README.md"
  [ "$status" -eq 0 ]
}

@test "docker-compose: caddy service mounts Caddyfile.d/ readonly" {
  run grep -E '\./Caddyfile\.d:/etc/caddy/Caddyfile\.d:ro' "$COMPOSE"
  [ "$status" -eq 0 ]
}

@test "docker-compose: caddy exports override env with defaults" {
  # The ${VAR:-default} compose syntax ensures Caddy sees the var even when
  # the operator hasn't set it in .env. Without these, Caddy's
  # {\$VAR:default} would still work (Caddy falls back to its own default),
  # but explicit passthrough makes the override surface discoverable.
  run grep -E 'SEARCH_HOST:\s*\$\{SEARCH_HOST:-search\}' "$COMPOSE"
  [ "$status" -eq 0 ]
  run grep -E 'MQ_HOST:\s*\$\{MQ_HOST:-mq\}' "$COMPOSE"
  [ "$status" -eq 0 ]
  run grep -E 'SEARCH_UPSTREAM:\s*\$\{SEARCH_UPSTREAM:-manticore:9308\}' "$COMPOSE"
  [ "$status" -eq 0 ]
  run grep -E 'MQ_UPSTREAM:\s*\$\{MQ_UPSTREAM:-rabbitmq:15672\}' "$COMPOSE"
  [ "$status" -eq 0 ]
}

@test ".env.example: documents the optional overrides (commented)" {
  ENV_EXAMPLE="${INFRA_ROOT}/.env.example"
  [ -r "$ENV_EXAMPLE" ] || skip "no .env.example"
  # The vars appear as commented examples — not active assignments — so
  # operators see them when scanning the file but defaults still apply.
  run grep -E '^#\s*SEARCH_HOST=' "$ENV_EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -E '^#\s*MQ_HOST=' "$ENV_EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -E '^#\s*SEARCH_UPSTREAM=' "$ENV_EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -E '^#\s*MQ_UPSTREAM=' "$ENV_EXAMPLE"
  [ "$status" -eq 0 ]
}

@test "Caddyfile syntax: caddy validate against rendered fragment dir" {
  # If docker is available, run Caddy's own validator inside the official image
  # against the actual config + an empty Caddyfile.d/. Skips cleanly in CI
  # environments without Docker.
  command -v docker >/dev/null 2>&1 || skip "docker not available"
  docker info >/dev/null 2>&1 || skip "docker daemon not running"

  local tmpdir
  tmpdir="$(mktemp -d)"
  cp "$CADDYFILE" "$tmpdir/Caddyfile"
  mkdir "$tmpdir/Caddyfile.d"
  # Drop a minimal valid fragment to exercise the import path.
  cat > "$tmpdir/Caddyfile.d/test.caddy" <<'EOF'
@_bats_test host test.example.com
handle @_bats_test {
    respond "ok" 200
}
EOF

  run docker run --rm \
    -e ROOT_DOMAIN=example.com \
    -v "$tmpdir/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$tmpdir/Caddyfile.d:/etc/caddy/Caddyfile.d:ro" \
    caddy:2-alpine \
    caddy validate --config /etc/caddy/Caddyfile

  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}
