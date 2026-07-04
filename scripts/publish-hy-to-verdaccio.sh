#!/usr/bin/env bash
# =============================================================================
# Publish foundation's private @hy/* packages into the in-cluster Verdaccio.
# -----------------------------------------------------------------------------
# The app Dockerfiles fetch @hy/* at build time from the Verdaccio deployed by
# core/k8s/07-verdaccio/verdaccio.yaml. This script seeds/refreshes those
# packages so the cluster is self-contained (no host Verdaccio dependency).
#
# Run on the WSL host (needs kubectl + pnpm + the foundation repo):
#   bash scripts/publish-hy-to-verdaccio.sh /path/to/fst-foundation
#
# Re-run after bumping any @hy/* version. Verdaccio rejects re-publishing an
# EXISTING version (immutable) — the per-package fallback tolerates that, so
# only new/bumped versions land. To force, bump the version in foundation.
# =============================================================================
set -euo pipefail

FOUNDATION_DIR="${1:?usage: publish-hy-to-verdaccio.sh <path-to-foundation-repo>}"
NS="${VERDACCIO_NS:-registry}"
PORT="${VERDACCIO_LOCAL_PORT:-4873}"
REG="http://localhost:${PORT}/"

command -v kubectl >/dev/null || { echo "[ERR] kubectl not found"; exit 1; }
command -v pnpm    >/dev/null || { echo "[ERR] pnpm not found";    exit 1; }
[[ -f "$FOUNDATION_DIR/pnpm-workspace.yaml" ]] || { echo "[ERR] $FOUNDATION_DIR is not the foundation repo"; exit 1; }

echo ">> waiting for Verdaccio to be ready in ns/$NS"
kubectl -n "$NS" rollout status deploy/verdaccio --timeout=180s

echo ">> port-forward svc/verdaccio -> localhost:${PORT}"
kubectl -n "$NS" port-forward svc/verdaccio "${PORT}:4873" >/tmp/verdaccio-pf.log 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -fsS "${REG}-/ping" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "${REG}-/ping" >/dev/null 2>&1 || { echo "[ERR] Verdaccio not reachable at ${REG}"; exit 1; }

# @hy/* ACL grants anonymous publish, but the npm client still requires SOME
# token to be present — a dummy satisfies it for a ClusterIP-internal registry.
npm config set "//localhost:${PORT}/:_authToken" "anonymous" >/dev/null 2>&1 || true

cd "$FOUNDATION_DIR"
echo ">> build @hy/* (pnpm -r build)"
pnpm install --frozen-lockfile || pnpm install
pnpm -r build

echo ">> publish @hy/* -> ${REG}"
# Per-package publish so an already-present version doesn't abort the rest.
published=0; skipped=0; failed=0
for d in packages/*/ ; do
  [[ -f "$d/package.json" ]] || continue
  name=$(node -p "require('./$d/package.json').name" 2>/dev/null || echo "?")
  priv=$(node -p "!!require('./$d/package.json').private" 2>/dev/null || echo false)
  [[ "$priv" == "true" ]] && { echo "  skip (private): $name"; continue; }
  # Trust npm's exit code, not output text — the notice lists tarball contents,
  # so grepping for "error" false-matches filenames like error-codes.ts.
  if out=$( (cd "$d" && npm publish --registry "${REG}") 2>&1 ); then
    echo "  published: $name"; published=$((published+1))
  elif grep -qiE 'cannot publish over|EPUBLISHCONFLICT|already .*present|409' <<<"$out"; then
    echo "  exists   : $name (version already present — bump to republish)"; skipped=$((skipped+1))
  else
    echo "  FAILED   : $name"; echo "$out" | tail -4 | sed 's/^/      /'; failed=$((failed+1))
  fi
done

echo ""
echo "==== published=$published exists=$skipped failed=$failed ===="
echo ">> verify: curl -s ${REG}@hy/common | head"
[[ "$failed" -eq 0 ]] || { echo "[WARN] some packages failed to publish"; exit 1; }
