#!/usr/bin/env bash
# DANGEROUS — wipes all data and uninstalls k3s. Requires explicit confirmation.
#
# Default behaviour preserves `secrets-backup/sealed-secrets-master.key.yaml`
# so the next `bootstrap.sh` restores the SAME RSA keypair into the new
# cluster, keeping existing SealedSecrets in your manifest repos decryptable.
# Use `--hard` (or RESET_HARD=1) to also nuke that backup — every SealedSecret
# in every manifest repo will then have to be re-sealed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HARD=0
if [[ "${1:-}" == "--hard" || "${RESET_HARD:-}" == "1" ]]; then
  HARD=1
fi

cat <<EOF
WARNING — this will:
  1. docker compose down -v (drops PG/Redis/RabbitMQ/Manticore volumes + cloudflared + caddy)
  2. uninstall k3s / delete the k3d cluster (drops ArgoCD/Tekton/Registry/applications)
  3. delete .env, INFRA.md, INFRA.zh-CN.md, ~/.kube/config
EOF
if [[ $HARD -eq 1 ]]; then
  cat <<EOF
  4. delete secrets-backup/  ← --hard mode
       sealed-secrets master key WILL be lost; every SealedSecret in your
       manifest repos has to be re-sealed against the next bootstrap's new key.
EOF
else
  cat <<EOF
  4. KEEP secrets-backup/sealed-secrets-master.key.yaml
       (so the next bootstrap restores the same RSA keypair — existing
        SealedSecrets in your manifest repos still decrypt. Use --hard
        to also wipe this.)
EOF
fi

read -r -p "Type 'YES_DESTROY_EVERYTHING' to confirm: " ans
[[ "$ans" != "YES_DESTROY_EVERYTHING" ]] && { echo "Cancelled."; exit 0; }

echo "Stopping Compose..."
# .env lives at infra root; pass --env-file explicitly so the tunnel-profile
# services (cloudflared, caddy) and their named volumes are also torn down.
ENV_FLAG=""
[[ -f .env ]] && ENV_FLAG="--env-file=.env"
docker compose $ENV_FLAG -f core/compose/docker-compose.yml --profile tunnel down -v || true

echo "Uninstalling k3s..."
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  sudo /usr/local/bin/k3s-uninstall.sh
elif command -v k3d >/dev/null 2>&1; then
  k3d cluster delete selfhost || true
fi

echo "Cleaning local config..."
rm -f .env INFRA.md INFRA.zh-CN.md
rm -f ~/.kube/config

if [[ $HARD -eq 1 ]]; then
  echo "  --hard: removing secrets-backup/ (sealed-secrets master key gone)"
  rm -rf secrets-backup
else
  # Keep the master-key backup. Trim the public cert (regenerated next run).
  rm -f secrets-backup/sealed-secrets-pub.pem
  if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
    echo "  preserved: secrets-backup/sealed-secrets-master.key.yaml"
  fi
fi

echo "Done. Re-run bootstrap.sh to rebuild."
