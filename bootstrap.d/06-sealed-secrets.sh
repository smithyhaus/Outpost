# shellcheck shell=bash
# =============================================================================
# Phase 6 — sealed-secrets (full mode only).
# Master key persistence: backup file lives in secrets-backup/, preserved
# across reset.sh (unless --hard). See docs/08-seal-secret.md.
# =============================================================================
phase "Phase 6 / 10 sealed-secrets"

# -----------------------------------------------------------------------------
# Restore master key BEFORE installing the controller — otherwise the
# controller generates a brand-new RSA keypair and existing SealedSecrets
# in your manifest repos can never be decrypted again. Without this,
# every cluster reset is a Sealed-Secrets bankruptcy event.
# Backup file is gitignored (.gitignore covers secrets-backup/), preserved
# across resets by reset.sh's default behaviour.
# -----------------------------------------------------------------------------
if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
  log "Restoring sealed-secrets master key from secrets-backup/..."
  # The backup is `kubectl get -o yaml` output, which pins the server-managed
  # resourceVersion at export time. On a rerun where the key already exists the
  # live object has advanced past it, so a plain apply fails optimistic-lock
  # ("the object has been modified"). Strip resourceVersion so restore is
  # idempotent — apply then no-ops (key present) or recreates it (fresh reset).
  sed -E '/^[[:space:]]*resourceVersion:/d' secrets-backup/sealed-secrets-master.key.yaml \
    | kubectl apply -f - >/dev/null
  ok "  master key restored — old SealedSecrets will decrypt on this cluster"
fi

# Vendored (core/k8s/vendor/) instead of curl'd from github.com/.../latest/
# download/ at install time — that host is intermittently throttled/blocked
# in CN, and the old `latest` path floated (a re-bootstrap months apart
# could silently jump major versions). See the file header for upgrade
# instructions. Keep in lockstep with KS_VER below (same release).
kubectl apply -f core/k8s/vendor/sealed-secrets-controller-v0.38.4.yaml
kubectl wait --for=condition=Available --timeout=180s deployment -l name=sealed-secrets-controller -n kube-system 2>/dev/null || true

# If we restored a key, restart the controller so it picks up the restored
# Secret on its next leader election (controller caches keys at startup).
if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
  kubectl -n kube-system rollout restart deployment sealed-secrets-controller >/dev/null
  kubectl wait --for=condition=Available --timeout=180s deployment -l name=sealed-secrets-controller -n kube-system 2>/dev/null || true
fi

if ! command -v kubeseal >/dev/null 2>&1; then
  log "Downloading kubeseal CLI..."
  # Pin kubeseal to a known-good version. Bump as new releases are validated.
  # Kept in lockstep with the vendored controller version
  # (core/k8s/vendor/sealed-secrets-controller-v0.38.4.yaml) — client/server
  # skew across sealed-secrets minor versions is not guaranteed compatible.
  # https://github.com/bitnami-labs/sealed-secrets/releases
  KS_VER="0.38.4"
  case "$SK_OS" in
    macos)
      # Apple Silicon (M-series) needs darwin-arm64; Intel Macs darwin-amd64.
      if [[ "$(uname -m)" == "arm64" ]]; then
        ARCH="darwin-arm64"
      else
        ARCH="darwin-amd64"
      fi
      ;;
    *)
      if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        ARCH="linux-arm64"
      else
        ARCH="linux-amd64"
      fi
      ;;
  esac
  KS_URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS_VER}/kubeseal-${KS_VER}-${ARCH}.tar.gz"
  # github.com direct download is intermittently throttled/blocked from CN.
  # Try it first (fast path when egress is fine); on failure fall back to
  # ghfast.top, a third-party GitHub release accelerator (unaffiliated with
  # GitHub — best-effort mirror, not a guarantee). If both fail, install
  # manually: download kubeseal-${KS_VER}-${ARCH}.tar.gz from
  # https://github.com/bitnami-labs/sealed-secrets/releases and place the
  # `kubeseal` binary on PATH.
  if ! curl -fsSL --connect-timeout 15 "$KS_URL" | tar -xz kubeseal 2>/dev/null; then
    warn "kubeseal download from github.com timed out/failed — retrying via ghfast.top (CN accelerator)"
    curl -fsSL --connect-timeout 15 "https://ghfast.top/${KS_URL}" | tar -xz kubeseal
  fi
  sudo mv kubeseal /usr/local/bin/
  sudo chmod +x /usr/local/bin/kubeseal
fi
mkdir -p secrets-backup
chmod 700 secrets-backup
kubeseal --fetch-cert > secrets-backup/sealed-secrets-pub.pem 2>/dev/null || true

# Backup master private key (RSA) — restored on next bootstrap to keep
# existing SealedSecrets decryptable. Gitignored by .gitignore.
log "Backing up sealed-secrets master key for cross-reset continuity..."
if kubectl -n kube-system get secret \
     -l sealedsecrets.bitnami.com/sealed-secrets-key \
     -o yaml > secrets-backup/sealed-secrets-master.key.yaml.tmp 2>/dev/null \
   && grep -q 'kind: List' secrets-backup/sealed-secrets-master.key.yaml.tmp; then
  mv secrets-backup/sealed-secrets-master.key.yaml.tmp \
     secrets-backup/sealed-secrets-master.key.yaml
  chmod 600 secrets-backup/sealed-secrets-master.key.yaml
  ok "sealed-secrets ready (master key backed up to secrets-backup/)"
else
  rm -f secrets-backup/sealed-secrets-master.key.yaml.tmp
  warn "Could not back up sealed-secrets master key — re-run bootstrap to retry"
fi
