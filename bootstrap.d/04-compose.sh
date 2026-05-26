# shellcheck shell=bash
# =============================================================================
# Phase 4 — Compose data services (PG / Redis / RabbitMQ / Manticore).
# In full mode also brings up cloudflared + caddy via the `tunnel` profile.
# =============================================================================
phase "Phase 4 / 10 Compose data services"

# Always invoke `docker compose` with explicit --env-file and -f so that
# any caller (this script, the launchd agent, status.sh, reset.sh) gets
# the same canonical view, regardless of CWD or shell environment.
# The .env file lives at the infra root, not next to docker-compose.yml.
COMPOSE_ARGS=(--env-file "${INFRA_ROOT}/.env" -f "${INFRA_ROOT}/core/compose/docker-compose.yml")

# Auto-include any onboarded-app overrides. `outpost onboard <name>` for
# tier=compose drops one core/compose/overrides/<name>.yml file; this glob
# picks them all up so a fresh bootstrap (or restart) brings up the app
# alongside the data services. Convention over explicit registration:
# nothing in .env to maintain, no list to drift.
shopt -s nullglob
for _override in "${INFRA_ROOT}/core/compose/overrides/"*.yml; do
  COMPOSE_ARGS+=(-f "$_override")
done
shopt -u nullglob

HEALTH_SERVICES=("postgres" "redis" "rabbitmq" "manticore")
if [[ "$OUTPOST_MODE" == "full" ]]; then
  COMPOSE_ARGS+=(--profile tunnel)
fi

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
