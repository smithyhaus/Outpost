#!/usr/bin/env bash
# Quick health snapshot. In local mode shows Compose only; in full mode shows
# Compose (edge), the k3s layer, the manifest-sync heartbeat and the GitHub
# Actions runner service. Read-only; verify.sh is the judging counterpart.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUTPOST_MODE="local"
if [[ -f .env ]]; then
  # Reading .env defensively: only pick up OUTPOST_MODE; ignore the rest.
  while IFS='=' read -r key val; do
    [[ "$key" == "OUTPOST_MODE" ]] && OUTPOST_MODE="$val"
  done < .env
fi

echo "═══ Mode: $OUTPOST_MODE ═══"
echo ""
echo "═══ Compose ═══"
# Use --env-file so we don't emit "variable not set" warnings; the .env
# lives at the infra root, not next to docker-compose.yml. Pick up any
# onboarded-app overrides via the same convention as bootstrap.d/04-compose.sh.
COMPOSE_ARGS=(--env-file .env -f core/compose/docker-compose.yml)
shopt -s nullglob
for _override in core/compose/overrides/*.yml; do
  COMPOSE_ARGS+=(-f "$_override")
done
shopt -u nullglob
docker compose "${COMPOSE_ARGS[@]}" ps 2>/dev/null || echo "(compose not running)"

if [[ "$OUTPOST_MODE" != "full" ]]; then
  exit 0
fi

echo ""
echo "═══ K8s nodes ═══"
kubectl get nodes -o wide 2>/dev/null || echo "(k3s not reachable)"

echo ""
for ns in outpost-ci registry buildkit infra-bridges apps kube-system; do
  echo "--- ns: $ns ---"
  kubectl get pods -n "$ns" 2>/dev/null || echo "  (none)"
done

echo ""
echo "═══ manifest-sync heartbeat (CD liveness) ═══"
kubectl get configmap sync-heartbeat -n outpost-ci \
  -o jsonpath='last_sync_ts={.data.last_sync_ts}{"\n"}applied_head={.data.applied_head}{"\n"}last_result={.data.last_result}{"\n"}' \
  2>/dev/null || echo "(no sync-heartbeat ConfigMap — sync never ran; check: kubectl -n outpost-ci get cronjob)"

echo ""
echo "═══ Recent manifest-sync Jobs ═══"
kubectl get jobs -n outpost-ci --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5 || echo "(none)"

echo ""
echo "═══ GitHub Actions runner (CI trigger) ═══"
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-units --type=service 'actions.runner.*' --no-legend 2>/dev/null \
    | sed 's/^/  /' || true
  if ! systemctl list-units --type=service 'actions.runner.*' --no-legend 2>/dev/null | grep -q .; then
    echo "  (no actions.runner.* systemd unit — runner not installed?)"
  fi
else
  echo "  (no systemd — check ~/actions-runner/svc.sh status)"
fi
echo ""
echo "Judgement (PASS/WARN/FAIL): ./verify.sh"
