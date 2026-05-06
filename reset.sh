#!/usr/bin/env bash
# DANGEROUS — wipes all data and uninstalls k3s. Requires explicit confirmation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

cat <<'EOF'
WARNING — this will:
  1. docker compose down -v (drops all data volumes: PG/Redis/RabbitMQ/Meili)
  2. uninstall k3s (drops ArgoCD/Tekton/Registry/applications)
  3. delete .env, INFRA.md, INFRA.zh-CN.md, ~/.kube/config
EOF

read -r -p "Type 'YES_DESTROY_EVERYTHING' to confirm: " ans
[[ "$ans" != "YES_DESTROY_EVERYTHING" ]] && { echo "Cancelled."; exit 0; }

echo "Stopping Compose..."
(cd core/compose && docker compose down -v) || true

echo "Uninstalling k3s..."
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  sudo /usr/local/bin/k3s-uninstall.sh
elif command -v k3d >/dev/null 2>&1; then
  k3d cluster delete selfhost || true
fi

echo "Cleaning local config..."
rm -f .env INFRA.md INFRA.zh-CN.md
rm -f ~/.kube/config
rm -rf secrets-backup

echo "Done. Re-run bootstrap.sh to rebuild."
