# shellcheck shell=bash
# =============================================================================
# Phase 10 (full mode) — Health summary + credentials echo.
# =============================================================================
phase "Phase 10 / 10 Summary"

echo ""
echo "Compose:"
docker compose -f core/compose/docker-compose.yml ps
echo ""
echo "K8s pods:"
kubectl get pods -A 2>/dev/null | head -40

# Platform-specific tail notes
sk_print_post_install_notes

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Outpost bootstrap complete (full mode)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ArgoCD UI:        https://argocd.${ROOT_DOMAIN}"
echo "  username:         admin"
echo "  password:         ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo "  Tekton Dashboard: https://tekton.${ROOT_DOMAIN}"
echo "                    (PipelineRuns / TaskRuns / logs)"
echo "  Rollouts UI:      https://${ROLLOUTS_DASHBOARD_HOST}"
echo "                    (canary progress / abort / promote)"
echo "  Dashboard auth:   user ${OUTPOST_DASHBOARD_USER} / pass ${OUTPOST_DASHBOARD_PASSWORD}"
echo "                    (shared BasicAuth in front of BOTH dashboards;"
echo "                     upgrade to Cloudflare Access for SSO/IdP)"
echo ""
echo "  Test runner:      ${TEST_RUNNER}  (mode: ${TESTKUBE_MODE})"
echo "  Notifications:    ${NOTIFICATION_PROVIDERS:-(none)}"
echo ""
echo "  App-repo webhook  (Tekton — every onboarded app needs this):"
echo "    URL:            https://hooks.${ROOT_DOMAIN}"
echo "    Secret:         ${GIT_WEBHOOK_SECRET}"
echo ""
echo "  Manifest-repo webhook  (ArgoCD instant-sync — configure ONCE per cluster):"
echo "    URL:            https://argocd.${ROOT_DOMAIN}/api/webhook"
echo "    Secret:         ${ARGOCD_WEBHOOK_SECRET}"
echo "    (re-print:      bash scripts/outpost setup-argocd-webhook)"
echo ""
echo "  Read INFRA.md for the full credential vault."
echo "  Run ./verify.sh anytime to check stack health."
echo ""
echo "  First-time setup verification (Phase F of the quickstart):"
echo "    bash verify.sh"
echo "    docker logs cloudflared --tail 50 | grep 'Registered tunnel connection'"
echo "    open https://argocd.${ROOT_DOMAIN}   # or curl"
echo ""
echo "  Step-by-step walkthrough (incl. autostart, dev workstation TCP,"
echo "  onboarding apps): i18n/<lang>/docs/00-quickstart.md"
echo ""
