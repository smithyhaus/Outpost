# shellcheck shell=bash
# =============================================================================
# Phase 4 — Compose profile selection, by OUTPOST_MODE.
# -----------------------------------------------------------------------------
#   local : `local-data` profile — Postgres / Redis / RabbitMQ / Manticore.
#           This IS the data layer (no k3s at all in local mode).
#   full  : `edge` profile — cloudflared + caddy only. The data layer moved
#           in-cluster (core/k8s/06-bridges/, applied in a later phase); in
#           full mode Compose's only job is the public ingress path.
# See core/compose/docker-compose.yml's header comment for the full
# local-data/edge profile contract.
# =============================================================================
phase "Phase 4 / 10 Compose"

# Always invoke `docker compose` with explicit --env-file and -f so that
# any caller (this script, the launchd agent, status.sh, reset.sh) gets
# the same canonical view, regardless of CWD or shell environment.
# The .env file lives at the infra root, not next to docker-compose.yml.
COMPOSE_ARGS=(--env-file "${INFRA_ROOT}/.env" -f "${INFRA_ROOT}/core/compose/docker-compose.yml")

# Auto-include any onboarded-app overrides. `outpost onboard <name>` for
# tier=compose drops one core/compose/overrides/<name>.yml file; this glob
# picks them all up so a fresh bootstrap (or restart) brings up the app
# alongside the active profile's services. Convention over explicit
# registration: nothing in .env to maintain, no list to drift.
shopt -s nullglob
for _override in "${INFRA_ROOT}/core/compose/overrides/"*.yml; do
  COMPOSE_ARGS+=(-f "$_override")
done
shopt -u nullglob

if [[ "$OUTPOST_MODE" == "full" ]]; then
  COMPOSE_ARGS+=(--profile edge)
  HEALTH_SERVICES=("caddy" "cloudflared")
else
  COMPOSE_ARGS+=(--profile local-data)
  HEALTH_SERVICES=("postgres" "redis" "rabbitmq" "manticore")
fi

# SEARCH_HOST / MQ_HOST defaults — exported here (not just left to Caddy's own
# {$VAR:default} syntax) because core/k8s/06-bridges/ingressroutes.template.yaml
# (full mode's replacement for the old Caddy @search/@mq routes) renders these
# via render_template/envsubst, which has no built-in defaulting. Exporting
# early (phase 4) means the value is already in the environment by the time a
# later phase applies core/k8s/06-bridges/. Harmless no-op in local mode
# (nothing consumes them there).
export SEARCH_HOST="${SEARCH_HOST:-search}"
export MQ_HOST="${MQ_HOST:-mq}"

log "Pulling images..."
docker compose "${COMPOSE_ARGS[@]}" pull
log "Bringing up services..."
docker compose "${COMPOSE_ARGS[@]}" up -d
log "Waiting for health..."
for svc in "${HEALTH_SERVICES[@]}"; do
  healthy=0
  for _ in {1..30}; do
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "starting")
    if [[ "$state" == "healthy" ]]; then
      ok "$svc healthy"; healthy=1; break
    fi
    sleep 2
  done
  if [[ "$healthy" -eq 0 ]]; then
    err "$svc did not reach healthy state — check: docker logs $svc --tail 50"
    exit 1
  fi
done
