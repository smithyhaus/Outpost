#!/usr/bin/env bats
# =============================================================================
# Caddyfile fragment loading + the built-in data-service UI routes.
#
# Guards invariants introduced by the env-ify refactor (v0.5):
#   1. The main Caddyfile imports per-app fragments from Caddyfile.d/*.caddy.
#   2. The compose caddy service mounts Caddyfile.d/ read-only.
#   3. The @search/@mq UI handlers are env-driven ({$VAR:default}), never
#      hardcoded per-org values.
#
# History: v0.3.0 briefly moved the data layer in-cluster (handlers moved to
# a Traefik IngressRoute); v0.3.1 reverted that by owner decision — stateful
# services stay in host Compose, and the k3s side is an ExternalName bridge
# (core/k8s/06-bridges/). This file guards the restored shape.
#
# These prevent regression back to the per-app-edit anti-pattern documented in
# ADR 0002 (docs/decisions/0002-onboarding-primitives-in-platform.md).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CADDYFILE="${INFRA_ROOT}/core/compose/Caddyfile"
  COMPOSE="${INFRA_ROOT}/core/compose/docker-compose.yml"
  FRAG_DIR="${INFRA_ROOT}/core/compose/Caddyfile.d"
  BRIDGES_DIR="${INFRA_ROOT}/core/k8s/06-bridges"
  [ -r "$CADDYFILE" ] || skip "core/compose/Caddyfile missing"
}

@test "Caddyfile: @search / @mq data-service UI handlers present and env-driven" {
  # v0.3.1 host-data-layer shape: the UIs ride Caddy again, with env-driven
  # prefixes/upstreams ({$VAR:default}) so operators override via .env
  # without forking the file.
  run grep -E '@search host \{\$SEARCH_HOST:search\}\.\{\$ROOT_DOMAIN\}' "$CADDYFILE"
  [ "$status" -eq 0 ]
  run grep -E '@mq host \{\$MQ_HOST:mq\}\.\{\$ROOT_DOMAIN\}' "$CADDYFILE"
  [ "$status" -eq 0 ]
  run grep -E 'reverse_proxy \{\$SEARCH_UPSTREAM:manticore:9308\}' "$CADDYFILE"
  [ "$status" -eq 0 ]
  run grep -E 'reverse_proxy \{\$MQ_UPSTREAM:rabbitmq:15672\}' "$CADDYFILE"
  [ "$status" -eq 0 ]
}

@test "Caddyfile: admin API matches what the compose healthcheck probes" {
  # Regression guard for a real outage class: `admin off` (shipped since
  # v1.0.0) silently contradicted the caddy healthcheck added in d779e10,
  # which probes http://127.0.0.1:2019/config/. The probe can never pass,
  # so caddy is permanently `unhealthy` — and bootstrap.d/04-compose.sh
  # hard-gates on health (exit 1), so `bash bootstrap.sh` dies at Phase 4.
  # These two files must agree; assert the coupling, not just each side.
  if grep -qE 'test:.*127\.0\.0\.1:2019' "$COMPOSE"; then
    run grep -qE '^\s*admin\s+off\s*$' "$CADDYFILE"
    [ "$status" -ne 0 ]                       # `admin off` would break it
    run grep -E '^\s*admin\s+localhost:2019\s*$' "$CADDYFILE"
    [ "$status" -eq 0 ]                       # explicit, loopback-only
  fi
}

@test "06-bridges: ExternalName bridge Services only (no in-cluster data workloads)" {
  # The k3s side of the data path is ExternalName → host.docker.internal.
  # StatefulSets/Deployments must not come back without a new owner decision
  # (v0.3.0's in-cluster move was reverted in v0.3.1).
  for f in postgres redis rabbitmq manticore; do
    run grep -E 'type:\s*ExternalName' "$BRIDGES_DIR/$f.yaml"
    [ "$status" -eq 0 ]
  done
  run grep -rE '^kind:\s*(StatefulSet|Deployment)' "$BRIDGES_DIR"
  [ "$status" -ne 0 ]
  [ ! -e "$BRIDGES_DIR/ingressroutes.template.yaml" ]
}

@test "docker-compose: caddy service passes SEARCH/MQ host + upstream env through" {
  run grep -E 'SEARCH_HOST: \$\{SEARCH_HOST:-search\}' "$COMPOSE"
  [ "$status" -eq 0 ]
  run grep -E 'MQ_UPSTREAM: \$\{MQ_UPSTREAM:-rabbitmq:15672\}' "$COMPOSE"
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

@test ".env.example: documents the SEARCH/MQ subdomain + upstream overrides (commented)" {
  ENV_EXAMPLE="${INFRA_ROOT}/.env.example"
  [ -r "$ENV_EXAMPLE" ] || skip "no .env.example"
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
