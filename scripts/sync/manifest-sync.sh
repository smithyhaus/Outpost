#!/usr/bin/env bash
# =============================================================================
# scripts/sync/manifest-sync.sh — the entire CD engine (~glue, not a product).
# -----------------------------------------------------------------------------
# Payload of the manifest-sync CronJob (core/k8s/03-ci/cronjob.template.yaml,
# ns outpost-ci, every MANIFEST_SYNC_INTERVAL min, concurrencyPolicy=Forbid →
# SINGLE WRITER by construction). Mounted via the sync-scripts ConfigMap and
# executed in alpine/k8s:1.31.0 (ships bash+git+kubectl+yq — no runtime
# installs, the same pin as the old update-manifest task).
#
# Semantics per run:
#   1. clone-or-fetch the manifest repo into $SYNC_STATE_DIR/manifest (PVC —
#      warm across runs; fetch+hard-reset, a consumer never merges)
#   2. compare HEAD vs applied_head in the sync-heartbeat ConfigMap
#      - unchanged and no FORCE_SYNC=1 → heartbeat + one log line, done
#   3. changed → for each apps/<dir> touched between applied_head and HEAD
#      (ALL dirs on first run / unknown applied_head / FORCE_SYNC=1):
#      kubectl apply -k (kustomization present) else apply -f, then wait:
#      Deployment → rollout status; Rollout → poll .status.phase (the canary
#      plugin works controller-only, no ArgoCD needed)
#   4. per-app failure → deploy-failed notify, CONTINUE with other apps
#      (one broken app must not freeze the fleet)
#   5. any successes → ONE deploy-succeeded summary notify (no per-app spam)
#   6. ALWAYS write the heartbeat CM (last_sync_ts / applied_head /
#      last_result) — even on failure paths. verify.sh alarms on heartbeat
#      age, so a crashed run that still wrote "error:…" is a LOUD signal,
#      and a run that wrote nothing trips the age check. Every run logs at
#      least one line: silence is a signal.
#
# The deploy/rollback hot path is fully domestic: gitee manifest repo + local
# cluster. github/proxy outages do not affect it.
#
# The manifest repo's legacy argocd-apps/ dir is IGNORED (only apps/ is
# consulted); leave it in place for history, or delete it at leisure.
# =============================================================================
set -euo pipefail

# ---- config (sync-config ConfigMap via envFrom; defaults for tests) ---------
: "${MANIFEST_REPO_URL:?env MANIFEST_REPO_URL is required}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-main}"
SYNC_STATE_DIR="${SYNC_STATE_DIR:-/var/lib/outpost}"
SYNC_NAMESPACE="${SYNC_NAMESPACE:-outpost-ci}"
HEARTBEAT_CM="${HEARTBEAT_CM:-sync-heartbeat}"
SYNC_ROLLOUT_TIMEOUT="${SYNC_ROLLOUT_TIMEOUT:-300}"
SYNC_ROLLOUT_POLL="${SYNC_ROLLOUT_POLL:-5}"
GIT_CRED_FILE="${GIT_CRED_FILE:-/etc/outpost/git-credentials/.git-credentials}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-outpost-sync@local}"
GIT_USER_NAME="${GIT_USER_NAME:-Outpost Sync}"
NOTIFY_FANOUT="${NOTIFY_FANOUT:-/scripts/notify-fanout.sh}"
OUTPOST_ENV="${OUTPOST_ENV:-dev}"

REPO_DIR="$SYNC_STATE_DIR/manifest"

log() { echo "[sync] $*"; }

# ---- heartbeat (ALWAYS written — anti-silence layer 2 reads it) -------------
write_heartbeat() {
  # $1 = applied head sha (may be empty early on), $2 = "ok" | "error:<detail>"
  local head="$1" result="$2"
  if ! kubectl create configmap "$HEARTBEAT_CM" -n "$SYNC_NAMESPACE" \
      --from-literal=last_sync_ts="$(date +%s)" \
      --from-literal=applied_head="$head" \
      --from-literal=last_result="$result" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
    # Heartbeat write failure must not mask the run's own result, but it must
    # be visible: verify.sh will flag the stale heartbeat age.
    log "WARN: heartbeat ConfigMap write failed (RBAC? API down?)"
  fi
}

# ---- notifications ----------------------------------------------------------
# Preferred path: scripts/notify-fanout.sh (packed into the sync-scripts CM by
# bootstrap alongside this file) with the /secrets + /templates layout mounted.
# Fallback: a plain POST to NOTIFY_WEBHOOK_URL (generic receiver). Last
# resort: log-only — the deploy result is still visible in Job logs and the
# heartbeat CM, and verify.sh reconciliation catches outcome drift anyway.
notify() {
  # $1 event, $2 level, $3 app (may be ""), $4 text
  local event="$1" level="$2" app="$3" text="$4" payload
  payload=$(printf '{"event":"%s","level":"%s","app":"%s","env":"%s","commit":"%s","ref":"%s","url":"","text":"%s"}' \
    "$event" "$level" "$app" "$OUTPOST_ENV" "${HEAD_SHORT:-}" "$MANIFEST_BRANCH" "$text")
  # notify-fanout resolves provider config file-first with env-var fallback
  # (the notify-secrets Secret arrives via envFrom) — no /secrets mount needed.
  if [[ -x "$NOTIFY_FANOUT" && -n "${NOTIFY_PROVIDERS:-}" ]]; then
    PAYLOAD="$payload" PROVIDERS="$NOTIFY_PROVIDERS" "$NOTIFY_FANOUT" \
      || log "WARN: notify-fanout failed (continuing)"
  elif [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]; then
    curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" \
      -d "$payload" "$NOTIFY_WEBHOOK_URL" >/dev/null \
      || log "WARN: webhook notify failed (continuing)"
  else
    log "notify(log-only): event=$event level=$level app=$app text=$text"
  fi
}

# Unexpected abort (set -e) still leaves a heartbeat + a log line behind.
on_err() {
  local rc=$?
  log "ERROR: unexpected failure (rc=$rc)"
  write_heartbeat "${APPLIED_HEAD:-}" "error:unexpected-rc=$rc"
  exit "$rc"
}
trap on_err ERR

log "start ts=$(date +%s) repo=$MANIFEST_REPO_URL branch=$MANIFEST_BRANCH"

# ---- git credentials (same pattern as update-manifest.sh) -------------------
if [[ -f "$GIT_CRED_FILE" ]]; then
  cp "$GIT_CRED_FILE" "$HOME/.git-credentials"
  git config --global credential.helper store
elif [[ -n "${GIT_USER:-}" && -n "${GIT_TOKEN:-}" ]]; then
  # Env-shaped credentials (Secret via envFrom): synthesize the store entry
  # for the manifest host. NEVER echo the token.
  _host=$(printf '%s' "$MANIFEST_REPO_URL" | sed -E 's|^[a-z+]+://([^/]+)/.*$|\1|')
  printf 'https://%s:%s@%s\n' "$GIT_USER" "$GIT_TOKEN" "$_host" > "$HOME/.git-credentials"
  git config --global credential.helper store
fi
git config --global user.email "$GIT_USER_EMAIL"
git config --global user.name  "$GIT_USER_NAME"
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

# ---- clone-or-fetch (PVC-warm; consumer never merges → hard reset) ----------
mkdir -p "$SYNC_STATE_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  if ! git -C "$REPO_DIR" fetch origin "$MANIFEST_BRANCH" 2>&1; then
    log "ERROR: git fetch failed (network? credentials?)"
    write_heartbeat "${APPLIED_HEAD:-}" "error:git-fetch"
    notify deploy-failed error "" "manifest-sync: git fetch failed for $MANIFEST_REPO_URL"
    exit 1
  fi
  git -C "$REPO_DIR" reset --hard "origin/$MANIFEST_BRANCH" >/dev/null
else
  rm -rf "$REPO_DIR"
  if ! git clone --branch "$MANIFEST_BRANCH" "$MANIFEST_REPO_URL" "$REPO_DIR" 2>&1; then
    log "ERROR: git clone failed (network? credentials?)"
    write_heartbeat "" "error:git-clone"
    notify deploy-failed error "" "manifest-sync: git clone failed for $MANIFEST_REPO_URL"
    exit 1
  fi
fi

HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
HEAD_SHORT=$(git -C "$REPO_DIR" rev-parse --short=7 HEAD)

# ---- applied_head from the heartbeat CM -------------------------------------
APPLIED_HEAD=$(kubectl get configmap "$HEARTBEAT_CM" -n "$SYNC_NAMESPACE" \
  -o jsonpath='{.data.applied_head}' 2>/dev/null || true)

if [[ "$HEAD" == "$APPLIED_HEAD" && "${FORCE_SYNC:-0}" != "1" ]]; then
  log "no change (HEAD=$HEAD_SHORT already applied)"
  write_heartbeat "$HEAD" "ok"
  exit 0
fi

# ---- changed-app set --------------------------------------------------------
# First run / unknown applied sha (history rewrite, fresh PVC) / FORCE_SYNC →
# apply ALL apps: converging on the full desired state is the safe direction.
APP_DIRS=""
if [[ -z "$APPLIED_HEAD" || "${FORCE_SYNC:-0}" == "1" ]] \
   || ! git -C "$REPO_DIR" cat-file -e "${APPLIED_HEAD}^{commit}" 2>/dev/null; then
  log "full sync (applied_head='${APPLIED_HEAD:-<none>}' force=${FORCE_SYNC:-0})"
  APP_DIRS=$(cd "$REPO_DIR" && find apps -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true)
else
  APP_DIRS=$(git -C "$REPO_DIR" diff --name-only "$APPLIED_HEAD" "$HEAD" -- apps/ \
    | awk -F/ 'NF>=2 {print $1"/"$2}' | sort -u)
fi

if [[ -z "$APP_DIRS" ]]; then
  log "commit $HEAD_SHORT touches no apps/<dir> (docs/argocd-apps legacy?) — nothing to apply"
  write_heartbeat "$HEAD" "ok"
  exit 0
fi

# ---- rollout wait helpers ---------------------------------------------------
# Rendered docs decide the wait strategy: Deployment → rollout status;
# Rollout (Argo Rollouts CRD, controller-only plugin) → poll .status.phase.
render_app() {
  local dir="$1"
  if [[ -f "$dir/kustomization.yaml" ]]; then
    kubectl kustomize "$dir"
  else
    local f
    for f in "$dir"/*.yaml "$dir"/*.yml; do
      [[ -f "$f" ]] || continue
      cat "$f"; printf '\n---\n'
    done
  fi
}

wait_for_app() {
  local dir="$1" kind ns name phase waited
  # yq walks every doc in the multi-doc stream; one line per workload.
  while IFS='|' read -r kind ns name; do
    [[ -z "$kind" ]] && continue
    ns="${ns:-${APPS_NAMESPACE:-apps}}"
    if [[ "$kind" == "Deployment" ]]; then
      log "  waiting: deployment/$name (ns=$ns, timeout=${SYNC_ROLLOUT_TIMEOUT}s)"
      kubectl -n "$ns" rollout status "deployment/$name" \
        --timeout="${SYNC_ROLLOUT_TIMEOUT}s" || return 1
    elif [[ "$kind" == "Rollout" ]]; then
      log "  waiting: rollout/$name (ns=$ns, poll .status.phase)"
      waited=0
      while :; do
        phase=$(kubectl -n "$ns" get rollout "$name" \
          -o jsonpath='{.status.phase}' 2>/dev/null || true)
        case "$phase" in
          Healthy) log "  rollout/$name Healthy"; break ;;
          Degraded) log "  rollout/$name Degraded"; return 1 ;;
          *) : ;;  # Progressing / Paused / not-reported-yet
        esac
        if [[ "$waited" -ge "$SYNC_ROLLOUT_TIMEOUT" ]]; then
          log "  rollout/$name timed out after ${SYNC_ROLLOUT_TIMEOUT}s (phase=${phase:-<none>})"
          return 1
        fi
        sleep "$SYNC_ROLLOUT_POLL"
        waited=$((waited + SYNC_ROLLOUT_POLL))
      done
    fi
  done < <(render_app "$dir" \
    | yq e -N 'select(.kind == "Deployment" or .kind == "Rollout")
               | .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name' - 2>/dev/null)
  return 0
}

deploy_app() {
  local dir="$1"
  if [[ -f "$dir/kustomization.yaml" ]]; then
    log "  kubectl apply -k $dir"
    kubectl apply -k "$dir" || return 1
  else
    log "  kubectl apply -f $dir"
    kubectl apply -f "$dir" || return 1
  fi
  wait_for_app "$dir"
}

# ---- apply changed apps (per-app failure isolation) -------------------------
OK_APPS=""
FAILED_APPS=""
cd "$REPO_DIR"
for rel in $APP_DIRS; do
  app="${rel#apps/}"
  if [[ ! -d "$rel" ]]; then
    # App dir deleted between applied_head and HEAD — sync applies, it never
    # prunes (deliberate: `outpost decommission` owns deletion).
    log "skip $app: apps/$app no longer exists at $HEAD_SHORT (decommissioned?)"
    continue
  fi
  log "app $app: applying"
  if deploy_app "$rel"; then
    log "app $app: OK"
    OK_APPS="${OK_APPS:+$OK_APPS, }$app"
  else
    log "app $app: FAILED (continuing with remaining apps)"
    FAILED_APPS="${FAILED_APPS:+$FAILED_APPS, }$app"
    notify deploy-failed error "$app" \
      "deploy failed for $app at manifest $HEAD_SHORT — see manifest-sync Job logs"
  fi
done

# ---- summarize + heartbeat --------------------------------------------------
if [[ -n "$FAILED_APPS" ]]; then
  # Do NOT advance applied_head past a failure: leaving it at the previous
  # value keeps HEAD != applied_head, so the next cron tick RETRIES the whole
  # changed set (applies are idempotent). Advancing it here would let the
  # idle fast-path stamp last_result=ok on the very next tick and bury the
  # failure — the exact fake-OK class this engine exists to kill.
  write_heartbeat "${APPLIED_HEAD:-}" "error:deploy-failed:${FAILED_APPS// /}"
  log "done: FAILED=[$FAILED_APPS] OK=[${OK_APPS:-none}] head=$HEAD_SHORT (applied_head NOT advanced — next tick retries)"
  # Non-zero → the Job is red in `kubectl get jobs` and `outpost logs`.
  exit 1
fi

if [[ -n "$OK_APPS" ]]; then
  notify deploy-succeeded info "" "deployed [$OK_APPS] at manifest $HEAD_SHORT"
fi
write_heartbeat "$HEAD" "ok"
log "done: OK=[${OK_APPS:-none}] head=$HEAD_SHORT"
