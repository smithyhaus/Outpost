#!/bin/sh
# =============================================================================
# Registry GC outer-pod driver — runs in the CronJob's alpine/k8s pod.
# -----------------------------------------------------------------------------
# Architecture: this script runs in a sidecar-like pod (alpine/k8s, has
# kubectl + sh) in the `registry` namespace. It locates the running
# docker-registry pod by label, then exec's into it to run the actual GC
# script (registry-gc.sh, mounted alongside). The exec'd script has direct
# filesystem access to the registry storage PVC AND the `registry` binary
# for blob garbage-collect.
#
# Why a separate file instead of an inline `command:` in the YAML?
# Because envsubst processes the YAML at bootstrap time and would happily
# eat any bare `$VAR` reference (including bash-runtime vars like $POD)
# replacing them with empty strings. Putting the shell logic in a real
# script file mounted via ConfigMap-from-file sidesteps the entire
# envsubst layer — matches the project's existing pattern for
# tekton-prune.sh, notify-fanout.sh, and update-manifest.sh.
#
# Env (set by the CronJob's container spec):
#   OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO   forwarded to inner GC script
# =============================================================================
set -eu

NS=registry
LABEL=app=docker-registry

echo "[$(date -u +%FT%TZ)] registry-gc outer: locating docker-registry pod"
POD=$(kubectl -n "$NS" get pods -l "$LABEL" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "ERROR: no docker-registry pod found in ns=$NS with label=$LABEL"
  echo "  Is REGISTRY_PLUGIN=self-hosted? Check: kubectl -n $NS get pods"
  exit 1
fi

echo "[$(date -u +%FT%TZ)] registry-gc outer: exec into $POD"

# Pipe the inner GC script content into the registry pod's sh -s. The inner
# script reads OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO from its env; we forward
# our own value through `env` so the registry pod's shell sees it without
# us having to inline it.
cat /script/registry-gc.sh \
  | kubectl -n "$NS" exec -i "$POD" -- \
      env OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO="${OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO:-5}" \
      /bin/sh -s

echo "[$(date -u +%FT%TZ)] registry-gc outer: done"
