#!/usr/bin/env bats
# =============================================================================
# Caddyfile fragment loading + the data-service-UI migration off Caddy.
#
# Guards invariants introduced by the env-ify refactor (v0.5) that are still
# true after the v0.3.0 data-layer migration:
#   1. The main Caddyfile imports per-app fragments from Caddyfile.d/*.caddy.
#   2. The compose caddy service mounts Caddyfile.d/ read-only.
#
# v0.3.0 moved Postgres/Redis/RabbitMQ/Manticore in-cluster (full mode); the
# old @search/@mq reverse-proxy handlers (and their SEARCH_HOST/MQ_HOST/
# SEARCH_UPSTREAM/MQ_UPSTREAM env passthrough) are GONE from this file — the
# equivalent routes now live in
# core/k8s/06-bridges/ingressroutes.template.yaml as a Traefik IngressRoute.
# This file guards that migration stays clean (no regression back to Caddy
# proxying data services it no longer runs).
#
# These prevent regression back to the per-app-edit anti-pattern documented in
# ADR 0002 (docs/decisions/0002-onboarding-primitives-in-platform.md).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CADDYFILE="${INFRA_ROOT}/core/compose/Caddyfile"
  COMPOSE="${INFRA_ROOT}/core/compose/docker-compose.yml"
  FRAG_DIR="${INFRA_ROOT}/core/compose/Caddyfile.d"
  INGRESSROUTES="${INFRA_ROOT}/core/k8s/06-bridges/ingressroutes.template.yaml"
  [ -r "$CADDYFILE" ] || skip "core/compose/Caddyfile missing"
}

@test "Caddyfile: @search / @mq data-service UI handlers are gone (moved to k3s)" {
  # Regression guard for the v0.3.0 data-layer migration — these routes must
  # NOT come back to Caddy; Postgres/Redis/RabbitMQ/Manticore no longer run
  # as Compose containers in full mode. Checks active directives only (not
  # comment lines — the header comment above legitimately mentions the old
  # @search/@mq names while explaining where they moved).
  active_lines="$(grep -vE '^\s*#' "$CADDYFILE")"
  ! grep -E '@search|@mq|SEARCH_UPSTREAM|MQ_UPSTREAM' <<< "$active_lines"
}

@test "ingressroutes.template.yaml: carries the search/mq routes instead" {
  [ -r "$INGRESSROUTES" ]
  run grep -E 'Host\(`\$\{SEARCH_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -eq 0 ]
  run grep -E 'Host\(`\$\{MQ_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -eq 0 ]
}

@test "docker-compose: caddy service no longer exports SEARCH_HOST/MQ_HOST" {
  # Dead-env cleanup — Caddy has no consumer for these anymore.
  run grep -E 'SEARCH_HOST:|MQ_HOST:|SEARCH_UPSTREAM:|MQ_UPSTREAM:' "$COMPOSE"
  [ "$status" -ne 0 ]
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

@test ".env.example: documents the SEARCH_HOST/MQ_HOST subdomain overrides (commented)" {
  # SEARCH_UPSTREAM/MQ_UPSTREAM are NOT asserted here anymore — that
  # "swap the upstream container:port" knob only made sense when Caddy
  # proxied to a Compose container by name. The Traefik IngressRoute target
  # (core/k8s/06-bridges/ingressroutes.template.yaml) is a fixed in-cluster
  # Service name, not swappable via env.
  ENV_EXAMPLE="${INFRA_ROOT}/.env.example"
  [ -r "$ENV_EXAMPLE" ] || skip "no .env.example"
  run grep -E '^#\s*SEARCH_HOST=' "$ENV_EXAMPLE"
  [ "$status" -eq 0 ]
  run grep -E '^#\s*MQ_HOST=' "$ENV_EXAMPLE"
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
