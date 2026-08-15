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

# Self-verify before declaring success. Several waits earlier in the run
# deliberately degrade to `warn` to keep the bootstrap moving (buildkitd,
# tekton rollouts, sealed-secrets) — an unconditional "complete" banner then
# papers over a half-broken stack. verify.sh is the ground truth: exit 0 =
# all PASS, 2 = warnings only, 1 = at least one FAIL.
echo ""
echo "Running post-bootstrap verification (./verify.sh)..."
VERIFY_STATUS=0
bash verify.sh || VERIFY_STATUS=$?

echo ""
echo "═══════════════════════════════════════════════════════════════"
case "$VERIFY_STATUS" in
  0) echo "  Outpost bootstrap complete (full mode) — verify: ALL PASS" ;;
  2) echo "  Outpost bootstrap complete (full mode) — verify: PASS with WARNINGS (see above)" ;;
  *) echo "  Outpost bootstrap FINISHED WITH FAILURES — verify found broken components (see above)"
     echo "  The stack is NOT fully healthy. Fix the FAIL items, then re-run ./verify.sh" ;;
esac
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  CI (GitHub Actions self-hosted runner):"
if [[ -n "${GITHUB_RUNNER_PAT:-}" ]]; then
  echo "    Registered at:  ${GITHUB_RUNNER_URL}  (labels: ${GITHUB_RUNNER_LABELS:-outpost})"
  echo "    Service:        systemctl status 'actions.runner.*'"
  echo "    Journal:        journalctl -u 'actions.runner.*' -n 200"
else
  echo "    NOT INSTALLED — GITHUB_RUNNER_PAT is empty (no CI builds will"
  echo "    trigger). Set GITHUB_RUNNER_URL + GITHUB_RUNNER_PAT in .env and"
  echo "    re-run bootstrap."
fi
echo ""
echo "  CD (manifest-sync CronJob, ns outpost-ci, every ${MANIFEST_SYNC_INTERVAL} min):"
echo "    Heartbeat:      kubectl -n outpost-ci get cm sync-heartbeat -o yaml"
echo "    Logs:           bash scripts/outpost logs sync"
echo "    Status:         bash scripts/outpost status"
echo ""
echo "  Onboard an app:   bash scripts/outpost onboard <clone-url>"
echo "                    (registers in OUTPOST_REPOS + prints the workflow"
echo "                     template + dual-push setup — templates/github/)"
echo ""
echo "  Public endpoints: search.${ROOT_DOMAIN} / mq.${ROOT_DOMAIN} / registry.${ROOT_DOMAIN}"
echo "  Test runner:      ${TEST_RUNNER}  (mode: ${TESTKUBE_MODE})"
echo "  Rollout plugin:   ${ROLLOUT_PLUGIN}"
echo "  Notifications:    ${NOTIFICATION_PROVIDERS:-(none)}"
echo ""
echo "  Read INFRA.md for the full credential vault."
echo "  Run ./verify.sh anytime to check stack health (the systemd timer"
echo "  outpost-verify.timer already runs it every 30 min and notifies on FAIL)."
echo ""
echo "  First-time setup verification (Phase F of the quickstart):"
echo "    bash verify.sh"
echo "    docker logs cloudflared --tail 50 | grep 'Registered tunnel connection'"
echo "    systemctl status 'actions.runner.*'   # runner online"
echo ""
echo "  Step-by-step walkthrough (incl. autostart, dev workstation TCP,"
echo "  onboarding apps): i18n/<lang>/docs/00-quickstart.md"
echo ""

# Propagate verify's verdict as bootstrap's own exit code — the banner alone
# isn't machine-readable, and scripted callers (install.sh, CI) trust $?.
# WARN-only (2) still counts as success; FAIL (1 or anything else) must not.
if [[ "$VERIFY_STATUS" -ne 0 && "$VERIFY_STATUS" -ne 2 ]]; then
  exit 1
fi
