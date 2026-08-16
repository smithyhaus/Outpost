#!/usr/bin/env bash
# DANGEROUS — wipes all data and uninstalls k3s. Requires explicit confirmation.
#
# ⚠️ v0.3.1 — your DATABASES ARE NOT PRESERVED by ANY mode of this script.
#    ADR-0005 put the data layer back in host Compose, so Postgres / Redis /
#    RabbitMQ / Manticore live in Compose NAMED VOLUMES, and the
#    `docker compose ... down -v` below deletes them. A logical dump taken
#    BEFORE running this is the only restore path — see the banner.
#
# Default behaviour PRESERVES two things across the wipe:
#   1. secrets-backup/sealed-secrets-master.key.yaml — so the next bootstrap
#      restores the SAME RSA keypair and existing SealedSecrets still decrypt.
#   2. the k3s local-path storage dir — moved aside to
#      /var/lib/outpost-preserved-<ts> BEFORE k3s-uninstall.sh nukes
#      /var/lib/rancher/k3s. In v0.3.1 that dir holds the registry PVC and
#      buildkit cache, NOT the databases (see the warning above) — this
#      guardrail saves you a rebuild, not your data.
# Use `--hard` (or RESET_HARD=1) to wipe BOTH — every SealedSecret must then
# be re-sealed and the registry starts empty.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HARD=0
if [[ "${1:-}" == "--hard" || "${RESET_HARD:-}" == "1" ]]; then
  HARD=1
fi

# k3s local-path provisioner default. k3d (macOS) keeps volumes inside the
# node container — no host dir to preserve there.
K3S_STORAGE_DIR="${K3S_STORAGE_DIR:-/var/lib/rancher/k3s/storage}"
PRESERVE_DIR="/var/lib/outpost-preserved-$(date +%Y%m%d-%H%M%S)"

cat <<EOF
WARNING — this will:
  1. docker compose down -v — DESTROYS the local-data volumes: every byte in
     Postgres / Redis / RabbitMQ / Manticore, plus cloudflared + caddy
  2. uninstall k3s / delete the k3d cluster (drops registry/buildkit/manifest-sync)
  3. unregister + remove the GitHub Actions runner service
  4. delete .env, INFRA.md, INFRA.zh-CN.md, ~/.kube/config

★ DUMP FIRST. The only reliable restore is a dump taken BEFORE the reset.
  The data layer is host Compose (ADR-0005), so dump through docker. The
  single quotes make \$POSTGRES_USER expand INSIDE the container, keeping the
  credential off your shell history and off the host command line:
    docker exec postgres sh -c 'pg_dumpall -U "\$POSTGRES_USER"' > pg-\$(date +%F).sql
    docker exec rabbitmq rabbitmqctl export_definitions /tmp/definitions.json
    docker cp rabbitmq:/tmp/definitions.json ./rabbitmq-definitions-\$(date +%F).json
  Do it now if you have not.
EOF
if [[ $HARD -eq 1 ]]; then
  cat <<EOF
  5. delete secrets-backup/           ← --hard mode
  6. DELETE the local-path storage dir ($K3S_STORAGE_DIR) ← --hard mode
       the registry PVC + buildkit cache are gone for good. (Your databases
       are already gone via step 1 — that happens in BOTH modes.)
EOF
else
  cat <<EOF
  5. KEEP secrets-backup/sealed-secrets-master.key.yaml
       (next bootstrap restores the same RSA keypair — existing
        SealedSecrets still decrypt. --hard wipes it.)
  6. PRESERVE the local-path storage dir:
       $K3S_STORAGE_DIR → $PRESERVE_DIR
       (in v0.3.1 this is the registry PVC + buildkit cache, NOT your
        databases — those go with step 1. A fresh cluster provisions NEW
        empty PVs; restoring means copying payloads back per-volume.
        --hard skips preservation and lets k3s-uninstall delete it.)
EOF
fi

read -r -p "Type 'YES_DESTROY_EVERYTHING' to confirm: " ans
[[ "$ans" != "YES_DESTROY_EVERYTHING" ]] && { echo "Cancelled."; exit 0; }

# ---- GitHub Actions runner unregistration -----------------------------------
# Must happen BEFORE .env is deleted (the PAT lives there) and before the
# runner dir could be lost. Every step is best-effort: a half-installed
# runner must not block the reset.
RUNNER_DIR="${GITHUB_RUNNER_DIR:-$HOME/actions-runner}"
if [[ -d "$RUNNER_DIR" ]]; then
  echo "Removing GitHub Actions runner..."
  GITHUB_RUNNER_PAT=""
  GITHUB_RUNNER_URL=""
  if [[ -f .env ]]; then
    # Source in a subshell-safe way: we only need the two runner vars.
    GITHUB_RUNNER_PAT=$(set -a; source ./.env >/dev/null 2>&1; printf '%s' "${GITHUB_RUNNER_PAT:-}")
    GITHUB_RUNNER_URL=$(set -a; source ./.env >/dev/null 2>&1; printf '%s' "${GITHUB_RUNNER_URL:-}")
  fi
  ( cd "$RUNNER_DIR"
    if [[ -x ./svc.sh ]]; then
      sudo ./svc.sh stop 2>/dev/null || ./svc.sh stop 2>/dev/null || true
      sudo ./svc.sh uninstall 2>/dev/null || ./svc.sh uninstall 2>/dev/null || true
    fi
    if [[ -x ./config.sh && -f .runner && -n "$GITHUB_RUNNER_PAT" && -n "$GITHUB_RUNNER_URL" ]]; then
      # Mint a short-lived REMOVE token via the API (PAT never echoed).
      _path="${GITHUB_RUNNER_URL#https://github.com/}"
      _path="${_path%/}"
      if [[ "$_path" == */* ]]; then _api="repos/${_path}"; else _api="orgs/${_path}"; fi
      _tok=$(curl -fsS --max-time 30 -X POST \
        -H "Authorization: Bearer ${GITHUB_RUNNER_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/${_api}/actions/runners/remove-token" 2>/dev/null \
        | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
      if [[ -n "$_tok" ]]; then
        ./config.sh remove --token "$_tok" || echo "  (config.sh remove failed — delete the runner in the GitHub UI)"
      else
        echo "  (could not mint a remove token — delete the runner in the GitHub UI)"
      fi
    else
      echo "  (no PAT/registration — skipping GitHub-side unregistration; remove stale runners in the GitHub UI)"
    fi
  ) || true
else
  echo "No runner dir at $RUNNER_DIR — skipping runner removal."
fi

# ---- verify timer ------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl disable --now outpost-verify.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/outpost-verify.timer /etc/systemd/system/outpost-verify.service
  sudo systemctl daemon-reload 2>/dev/null || true
fi

echo "Stopping Compose..."
# .env lives at infra root; pass --env-file explicitly. Tear down BOTH
# profiles so either mode's services + named volumes go.
ENV_FLAG=""
[[ -f .env ]] && ENV_FLAG="--env-file=.env"
docker compose $ENV_FLAG -f core/compose/docker-compose.yml --profile edge --profile local-data down -v || true

# ---- data-dir guardrail (BEFORE k3s-uninstall deletes /var/lib/rancher/k3s) --
if [[ $HARD -eq 0 && -d "$K3S_STORAGE_DIR" ]]; then
  echo "Preserving local-path storage: $K3S_STORAGE_DIR → $PRESERVE_DIR"
  if sudo mv "$K3S_STORAGE_DIR" "$PRESERVE_DIR"; then
    echo "  preserved. Restore per-volume by copying back, or replay your dump."
  else
    echo "  ERROR: could not move the storage dir — ABORTING before k3s-uninstall"
    echo "  (nothing has been uninstalled; your data is still in place)"
    exit 1
  fi
fi

echo "Uninstalling k3s..."
if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  sudo /usr/local/bin/k3s-uninstall.sh
elif command -v k3d >/dev/null 2>&1; then
  k3d cluster delete selfhost || true
fi

echo "Cleaning local config..."
rm -f .env INFRA.md INFRA.zh-CN.md
rm -f ~/.kube/config
rm -rf .outpost-state

if [[ $HARD -eq 1 ]]; then
  echo "  --hard: removing secrets-backup/ (sealed-secrets master key gone)"
  rm -rf secrets-backup
else
  # Keep the master-key backup. Trim the public cert (regenerated next run).
  rm -f secrets-backup/sealed-secrets-pub.pem
  if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
    echo "  preserved: secrets-backup/sealed-secrets-master.key.yaml"
  fi
  if [[ -d "$PRESERVE_DIR" ]]; then
    echo "  preserved: $PRESERVE_DIR (old PV payloads — clean up manually once restored/unneeded)"
  fi
fi

echo "Done. Re-run bootstrap.sh to rebuild."
