#!/usr/bin/env bats
# =============================================================================
# Tests for scripts/sync/manifest-sync.sh — the in-cluster CD glue.
#
# Real git (bare manifest remote, like update-manifest.bats); kubectl is a
# PATH-shim stub that records every call and plays back heartbeat/rollout
# state. The stub captures the heartbeat `create cm --dry-run | apply -f -`
# pipe so tests can assert applied_head / last_result without a cluster.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${INFRA_ROOT}/scripts/sync/manifest-sync.sh"
  [ -x "$SCRIPT" ] || skip "manifest-sync.sh not executable"
  command -v git >/dev/null 2>&1 || skip "git not available"
  command -v yq  >/dev/null 2>&1 || skip "yq not available (install mikefarah/yq)"

  TMP="$(mktemp -d)"
  REMOTE="$TMP/remote.git"
  SEED="$TMP/seed"
  BIN="$TMP/bin"
  mkdir -p "$BIN" "$TMP/home"

  export KUBECTL_LOG="$TMP/kubectl.log"
  export MOCK_APPLIED_FILE="$TMP/applied-head"      # playback: applied_head
  export MOCK_HEARTBEAT_FILE="$TMP/heartbeat"       # capture: heartbeat write
  export MOCK_FAIL_DIR=""
  export MOCK_ROLLOUT_PHASE="Healthy"

  # NOTE: kubectl arg order varies (`kubectl get cm ... -n ns` vs
  # `kubectl -n ns get rollout ...`) — match on the FULL argv string.
  cat > "$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$KUBECTL_LOG"
case "$args" in
  "get configmap"*)
    [ -f "$MOCK_APPLIED_FILE" ] && { cat "$MOCK_APPLIED_FILE"; exit 0; }
    exit 1 ;;
  *"get rollout"*)
    printf '%s' "$MOCK_ROLLOUT_PHASE"; exit 0 ;;
  "create "*)
    # heartbeat: emit argv so the downstream `apply -f -` captures it
    printf '%s\n' "$args"; exit 0 ;;
  "apply -f -")
    cat > "$MOCK_HEARTBEAT_FILE"; exit 0 ;;
  "apply "*)
    if [ -n "$MOCK_FAIL_DIR" ]; then
      case "$args" in *"$MOCK_FAIL_DIR"*) exit 1 ;; esac
    fi
    exit 0 ;;
  "kustomize "*)
    # app1's kustomization renders one Deployment
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app1\n  namespace: apps\n'
    exit 0 ;;
  *"rollout status"*) exit 0 ;;   # instant success
esac
exit 0
STUB
  chmod +x "$BIN/kubectl"
  export PATH="$BIN:$PATH"

  # Bare manifest remote with two apps: app1 (kustomize) + app2 (legacy).
  git init --bare -q --initial-branch=main "$REMOTE"
  git clone -q "$REMOTE" "$SEED"
  ( cd "$SEED"
    git config user.email t@l; git config user.name T
    git config commit.gpgsign false
    mkdir -p apps/app1 apps/app2 argocd-apps
    printf 'resources:\n  - deployment.yaml\n' > apps/app1/kustomization.yaml
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app1\n  namespace: apps\n' > apps/app1/deployment.yaml
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: app2\n  namespace: apps\n' > apps/app2/deployment.yaml
    printf 'legacy\n' > argocd-apps/app1.yaml
    git add .; git commit -q -m seed; git push -q origin main )

  export HOME="$TMP/home"
  export MANIFEST_REPO_URL="file://$REMOTE"
  export MANIFEST_BRANCH="main"
  export SYNC_STATE_DIR="$TMP/state"
  export GIT_CRED_FILE="$TMP/no-such-cred-file"
  export SYNC_ROLLOUT_TIMEOUT=10
  export SYNC_ROLLOUT_POLL=1
  unset FORCE_SYNC NOTIFY_WEBHOOK_URL NOTIFY_PROVIDERS 2>/dev/null || true
}

teardown() {
  rm -rf "$TMP"
}

_head() { git --git-dir="$REMOTE" rev-parse main; }

# Commit a change to one app through the seed clone.
_touch_app() {
  ( cd "$SEED"
    printf '# rev %s\n' "$RANDOM" >> "apps/$1/deployment.yaml"
    git add .; git commit -q -m "touch $1"; git push -q origin main )
}

# ---- first run / heartbeat --------------------------------------------------

@test "first run (no applied_head): applies ALL app dirs, heartbeat ok" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"full sync"* ]]
  grep -q "apply -k apps/app1" "$KUBECTL_LOG"
  grep -q "apply -f apps/app2" "$KUBECTL_LOG"
  # argocd-apps/ is ignored entirely
  ! grep -q "argocd-apps" "$KUBECTL_LOG"
  grep -q -- "--from-literal=applied_head=$(_head)" "$MOCK_HEARTBEAT_FILE"
  grep -q -- "--from-literal=last_result=ok" "$MOCK_HEARTBEAT_FILE"
  grep -q -- "--from-literal=last_sync_ts=" "$MOCK_HEARTBEAT_FILE"
}

@test "no change: logs a line + heartbeat, applies nothing" {
  _head > "$MOCK_APPLIED_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no change"* ]]
  ! grep -q "apply -k" "$KUBECTL_LOG"
  ! grep -q "apply -f apps/" "$KUBECTL_LOG"
  grep -q -- "--from-literal=last_result=ok" "$MOCK_HEARTBEAT_FILE"
}

@test "FORCE_SYNC=1 with unchanged head applies everything" {
  _head > "$MOCK_APPLIED_FILE"
  FORCE_SYNC=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "apply -k apps/app1" "$KUBECTL_LOG"
  grep -q "apply -f apps/app2" "$KUBECTL_LOG"
}

# ---- changed-dir detection --------------------------------------------------

@test "changed-dir detection: only the app touched between shas is applied" {
  _head > "$MOCK_APPLIED_FILE"    # applied = current head
  _touch_app app2                 # new head touches ONLY app2
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "apply -f apps/app2" "$KUBECTL_LOG"
  ! grep -q "apply -k apps/app1" "$KUBECTL_LOG"
  grep -q -- "--from-literal=applied_head=$(_head)" "$MOCK_HEARTBEAT_FILE"
}

@test "unknown applied_head (history rewrite / fresh PVC) falls back to full sync" {
  echo "0000000000000000000000000000000000000000" > "$MOCK_APPLIED_FILE"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"full sync"* ]]
  grep -q "apply -k apps/app1" "$KUBECTL_LOG"
}

# ---- rollout-wait selection -------------------------------------------------

@test "Deployment waits via 'kubectl rollout status'" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "rollout status deployment/app1" "$KUBECTL_LOG"
  grep -q "rollout status deployment/app2" "$KUBECTL_LOG"
}

@test "kind Rollout waits via .status.phase polling, not rollout status" {
  ( cd "$SEED"
    mkdir -p apps/app3
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata:\n  name: app3\n  namespace: apps\n' > apps/app3/rollout.yaml
    git add .; git commit -q -m "add app3"; git push -q origin main )
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "get rollout app3" "$KUBECTL_LOG"
  ! grep -q "rollout status deployment/app3" "$KUBECTL_LOG"
}

@test "Degraded Rollout fails that app" {
  ( cd "$SEED"
    mkdir -p apps/app3
    printf 'apiVersion: argoproj.io/v1alpha1\nkind: Rollout\nmetadata:\n  name: app3\n  namespace: apps\n' > apps/app3/rollout.yaml
    git add .; git commit -q -m "add app3"; git push -q origin main )
  MOCK_ROLLOUT_PHASE=Degraded run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"app3: FAILED"* ]]
  grep -q -- "--from-literal=last_result=error:deploy-failed:app3" "$MOCK_HEARTBEAT_FILE"
}

# ---- per-app failure isolation ----------------------------------------------

@test "one failing app does not block the others; heartbeat says error" {
  MOCK_FAIL_DIR="apps/app1" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"app1: FAILED (continuing with remaining apps)"* ]]
  [[ "$output" == *"app app2: OK"* ]]
  grep -q "apply -f apps/app2" "$KUBECTL_LOG"
  grep -q -- "--from-literal=last_result=error:deploy-failed:app1" "$MOCK_HEARTBEAT_FILE"
  # applied_head must NOT advance past a failure: keeping the old value means
  # HEAD != applied_head next tick, so the changed set is RETRIED (applies are
  # idempotent). Advancing it would let the idle fast-path stamp last_result=ok
  # on the very next tick and bury the failure — the fake-OK class.
  ! grep -q -- "--from-literal=applied_head=$(_head)" "$MOCK_HEARTBEAT_FILE"
}

@test "log-only notify path emits deploy events when no webhook is wired" {
  MOCK_FAIL_DIR="apps/app2" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"notify(log-only): event=deploy-failed"* ]]
}

@test "successful run emits ONE deploy-succeeded summary (no per-app spam)" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local n
  n=$(printf '%s\n' "$output" | grep -c "event=deploy-succeeded")
  [ "$n" -eq 1 ]
  [[ "$output" == *"deployed [app1, app2]"* ]]
}
