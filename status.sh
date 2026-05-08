#!/usr/bin/env bash
# Quick health snapshot. In local mode shows Compose only; in full mode shows
# both Compose and the k3s layer.
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
# lives at the infra root, not next to docker-compose.yml.
docker compose --env-file .env -f core/compose/docker-compose.yml ps 2>/dev/null || echo "(compose not running)"

if [[ "$OUTPOST_MODE" != "full" ]]; then
  exit 0
fi

echo ""
echo "═══ K8s nodes ═══"
kubectl get nodes -o wide 2>/dev/null || echo "(k3s not reachable)"

echo ""
for ns in argocd tekton-pipelines registry infra-bridges apps kube-system; do
  echo "--- ns: $ns ---"
  kubectl get pods -n "$ns" 2>/dev/null || echo "  (none)"
done

echo ""
echo "═══ ArgoCD Applications ═══"
kubectl get application -n argocd 2>/dev/null || echo "(none)"

echo ""
echo "═══ Recent PipelineRuns ═══"
kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -5
