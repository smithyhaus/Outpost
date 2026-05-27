#!/bin/sh
# =============================================================================
# Tekton PipelineRun auto-pruner — run by the tekton-pruner CronJob.
# -----------------------------------------------------------------------------
# POSIX sh — runs in alpine/k8s (busybox sh, busybox date, etc).
#
# What it does:
#   1. Compute UTC cutoff = now - ${OUTPOST_TEKTON_RETENTION_HOURS} hours.
#   2. List PipelineRuns whose status.completionTime is older than cutoff.
#      (Still-running PRs are excluded — empty completionTime, NF==1 in awk.)
#   3. Delete them. Owner-reference cascade collects their TaskRuns and pods,
#      releasing the ephemeral-storage held by completed kaniko containers.
#   4. Defensive sweep: kill any leftover Failed/Evicted pods that the
#      owner cascade missed (k3s/k3d sometimes leaves orphans).
#
# RFC3339 timestamps lex-compare correctly because they are zero-padded
# fixed-width — no date math needed in awk.
#
# Lives in scripts/ (not embedded in manifest) so the script gets mounted via
# kubectl-create-configmap-from-file at install time, sidestepping envsubst's
# strict ${VAR} check. Matches the project's existing pattern for
# notify-fanout.sh and update-manifest.sh.
# =============================================================================
set -eu

NS=tekton-pipelines
RETAIN_HOURS="${OUTPOST_TEKTON_RETENTION_HOURS:-24}"

# Compute UTC cutoff. We avoid `date -d "-Nh"` (GNU-only) and `date -v -NH`
# (BSD-only) because the production runtime is busybox `date` in alpine/k8s,
# which supports neither. Epoch math via `date -d @SECONDS` is POSIX-portable
# and works in busybox, GNU coreutils, and macOS BSD date alike.
now_s=$(date -u +%s)
cutoff_s=$(( now_s - RETAIN_HOURS * 3600 ))
cutoff="$(date -u -d "@${cutoff_s}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "${cutoff_s}" +%Y-%m-%dT%H:%M:%SZ)"

echo "[$(date -u +%FT%TZ)] prune: cutoff=${cutoff} (retain last ${RETAIN_HOURS}h)"

# PipelineRun sweep. jsonpath emits "name<TAB>completionTime" per item;
# empty completionTime (still running) → NF==1 in awk → skipped.
victims="$(
  kubectl -n "$NS" get pipelinerun \
    -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.completionTime}{"\n"}{end}' \
  | awk -F'\t' -v c="$cutoff" 'NF==2 && $2!="" && $2 < c {print $1}'
)"

if [ -n "$victims" ]; then
  count=$(echo "$victims" | wc -l | tr -d ' ')
  echo "[$(date -u +%FT%TZ)] prune: deleting ${count} PipelineRuns"
  echo "$victims" | xargs -r kubectl -n "$NS" delete pipelinerun --ignore-not-found
else
  echo "[$(date -u +%FT%TZ)] prune: no PipelineRuns past cutoff"
fi

# Defensive: kill leftover Evicted / Failed pods. The owner-reference
# cascade should normally handle them, but k3s/k3d sometimes leaves
# orphans (especially after a DiskPressure-triggered eviction storm).
orphans="$(kubectl -n "$NS" get pods --field-selector=status.phase=Failed -o name 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  count=$(echo "$orphans" | wc -l | tr -d ' ')
  echo "[$(date -u +%FT%TZ)] prune: removing ${count} Failed pods"
  echo "$orphans" | xargs -r kubectl -n "$NS" delete --ignore-not-found
fi

echo "[$(date -u +%FT%TZ)] prune: done"
