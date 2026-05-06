#!/usr/bin/env bash
# Quick health snapshot across both layers
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "═══ Compose ═══"
docker compose -f core/compose/docker-compose.yml ps 2>/dev/null || echo "(compose not running)"

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
