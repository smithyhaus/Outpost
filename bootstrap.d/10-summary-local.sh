# shellcheck shell=bash
# =============================================================================
# Phase 10 (local mode) — Summary. Reached when OUTPOST_MODE=local.
# =============================================================================
phase "Phase 10 / 10 Summary (local mode)"

echo ""
echo "Compose:"
docker compose -f core/compose/docker-compose.yml ps
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Outpost bootstrap complete (local mode)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  PostgreSQL : postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"
echo "  Redis      : redis://default:${REDIS_PASSWORD}@localhost:6379/0"
echo "  RabbitMQ   : amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@localhost:5672/  (UI: http://localhost:15672)"
echo "  Meilisearch: http://localhost:7700  (Bearer ${MEILI_MASTER_KEY})"
echo ""
echo "  Read INFRA.md for full credential vault."
echo "  Run ./verify.sh anytime to check stack health."
echo ""
echo "  To upgrade to full mode (CF Tunnel + k3s + GitOps), follow the"
echo "  quickstart full-mode walkthrough:"
echo "    i18n/en/docs/00-quickstart.md      (Phase A through I)"
echo "    i18n/zh-CN/docs/00-quickstart.md   (Chinese version)"
echo ""
