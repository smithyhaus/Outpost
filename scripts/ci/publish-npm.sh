#!/usr/bin/env bash
# =============================================================================
# scripts/ci/publish-npm.sh — publish @hy/* workspace packages to Verdaccio.
# -----------------------------------------------------------------------------
# Host-side port of core/k8s/05-tekton/task-npm-publish.yaml, used for
# LIBRARY repos (e.g. fst-foundation) that ship no deployable image.
# `pnpm -r publish` publishes only packages whose version is NOT already on
# the registry and skips the rest (not an error), so the flow is: a dev bumps
# a package's version -> push -> CI publishes it -> consumers pinned to
# ^x.y.z pick it up on their next build. No commit-back, no trigger loop.
#
# Registry reachability (host → in-cluster Verdaccio):
#   HY_REGISTRY points at the ClusterIP name, which the HOST cannot resolve.
#   Set HY_REGISTRY_PUBLISH_URL to a host-reachable URL to use it directly;
#   otherwise this script port-forwards svc/verdaccio to localhost — the same
#   pattern as scripts/publish-hy-to-verdaccio.sh (proven on this host).
#
# Judgement is EXIT-CODE based (set -e): a real publish error fails the step
# (notify fires); "version already exists → skipped" does not.
#
# Usage: publish-npm.sh [<workspace>]   (default: $GITHUB_WORKSPACE)
# bash-3.2 compatible.
# =============================================================================
set -euo pipefail

WORKSPACE="${1:-${GITHUB_WORKSPACE:-}}"
[[ -n "$WORKSPACE" ]] || { echo "[ERR] usage: publish-npm.sh <workspace> (or set GITHUB_WORKSPACE)" >&2; exit 2; }
[[ -d "$WORKSPACE" ]] || { echo "[ERR] workspace not a directory: $WORKSPACE" >&2; exit 2; }

PACKAGES_FILTER="${PACKAGES_FILTER:-./packages/*}"

# pnpm: prefer an installed binary; fall back to activating it via corepack
# (the old task's `corepack enable` — routed through the registry so it never
# hits registry.npmjs.org over flaky CN egress).
if ! command -v pnpm >/dev/null 2>&1 && command -v corepack >/dev/null 2>&1; then
  corepack enable >/dev/null 2>&1 || true
fi
command -v pnpm >/dev/null 2>&1 || { echo "[ERR] pnpm not found on the runner host (install pnpm or corepack)" >&2; exit 2; }

# ---- resolve a host-reachable registry URL ----------------------------------
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -n "${HY_REGISTRY_PUBLISH_URL:-}" ]]; then
  REG="$HY_REGISTRY_PUBLISH_URL"
else
  command -v kubectl >/dev/null 2>&1 || { echo "[ERR] kubectl required to port-forward Verdaccio (or set HY_REGISTRY_PUBLISH_URL)" >&2; exit 2; }
  NS="${VERDACCIO_NS:-registry}"
  PORT="${VERDACCIO_LOCAL_PORT:-4873}"
  REG="http://localhost:${PORT}/"
  echo "[INFO] port-forward svc/verdaccio (ns/$NS) -> localhost:${PORT}"
  kubectl -n "$NS" port-forward svc/verdaccio "${PORT}:4873" >/dev/null 2>&1 &
  PF_PID=$!
  _up=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if curl -fsS --max-time 5 "${REG%/}/-/ping" >/dev/null 2>&1; then _up=1; break; fi
    sleep 1
  done
  [[ "$_up" -eq 1 ]] || { echo "[ERR] Verdaccio not reachable at ${REG}" >&2; exit 1; }
fi

# corepack fetches the pnpm tarball itself and does NOT read .npmrc — without
# this it goes straight to registry.npmjs.org (flaky CN egress). Route it
# through Verdaccio like everything else (uplink -> npmmirror).
export COREPACK_NPM_REGISTRY="${REG%/}"
echo "[publish] registry = ${REG}"

cd "$WORKSPACE"

# Scope @hy to Verdaccio and route all installs through it (Verdaccio uplinks
# to npmjs for public deps, same as the app Docker builds).
printf '@hy:registry=%s\nregistry=%s\n' "${REG}" "${REG}" > .npmrc
# npm/pnpm refuse to publish with no credential at all (client-side
# ENEEDAUTH) even though Verdaccio's '@hy/*' ACL grants publish to $all
# (verified live: unauthenticated PUT returns 201). A dummy token satisfies
# the client; the server does not validate it.
_reg_host="${REG#*://}"; _reg_host="${_reg_host%/}"
printf '//%s/:_authToken=anonymous\n' "${_reg_host}" >> .npmrc

pnpm install --frozen-lockfile=false
pnpm -r build
# -r publish skips versions already on the registry and publishes only
# newly-bumped ones. A real publish error fails the step (notify fires).
pnpm -r --filter "$PACKAGES_FILTER" publish \
  --registry "${REG}" --no-git-checks

echo "[OK] publish-npm done"
