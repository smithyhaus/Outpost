# shellcheck shell=bash
# =============================================================================
# Phase 8 — CI/CD engine (v0.3.0): buildkitd + NodePorts + manifest-sync
#           CronJob + GitHub Actions self-hosted runner + verify timer.
# -----------------------------------------------------------------------------
# Replaces 08-argocd-tekton.sh. ArgoCD, Tekton (CRDs/controllers/webhooks/
# dashboard/EventListener), dashboard BasicAuth and inbound webhook
# registration are GONE — CI is a GitHub Actions workflow on the host runner
# calling scripts/ci/*, CD is the manifest-sync CronJob (ns outpost-ci). See
# docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md.
# The CoreDNS host.docker.internal bridge is RETAINED (v0.3.1): stateful data
# services stay in host Compose by owner decision, so pods still reach them
# through the infra-bridges ExternalName Services + CoreDNS custom hosts.
# =============================================================================
phase "Phase 8 / 10 CI engine (buildkit, manifest-sync, GitHub runner)"

# -----------------------------------------------------------------------------
# Cleanup: orphans from earlier bootstrap versions.
#
# Scope is intentionally narrow — each entry is a resource THIS bootstrap
# created in a previous version and no longer creates. We only touch exact
# (kind, namespace, name) tuples we know we own. Every command is
# ignore-not-found so this is a no-op on a clean cluster.
# -----------------------------------------------------------------------------
log "Cleaning orphans from earlier bootstrap versions (narrow, no wildcards)..."

# (a) The retired engines' namespaces. Pre-v0.3 bootstraps created `argocd`
#     and `tekton-pipelines` (via 00-namespaces + the vendored installs) and
#     everything inside them was exclusively ours. Deleting the namespace
#     removes controllers, CRD workloads, dashboards, EL, pruner in one shot.
#     CRDs themselves are cluster-scoped and left behind (harmless, and a
#     wipe-redo install never has them); remove by hand if desired.
#     ⚠️ ArgoCD Applications created by a v0.2 install carry
#     `resources-finalizer.argocd.argoproj.io`. That finalizer means "when
#     this Application is deleted, CASCADE-DELETE everything it manages" —
#     i.e. every Deployment/Service/IngressRoute the app owns in ns `apps`.
#     Deleting the argocd namespace deletes the Application objects, so on
#     a live v0.2 box the naive `delete ns argocd` can take the entire
#     running application fleet down with it. Strip the finalizers FIRST so
#     the Applications are removed WITHOUT pruning their workloads; those
#     workloads keep running untouched until manifest-sync adopts them.
if kubectl get ns argocd >/dev/null 2>&1 \
   && kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  _apps=$(kubectl -n argocd get applications -o name 2>/dev/null || true)
  if [[ -n "$_apps" ]]; then
    log "  stripping ArgoCD cascade finalizers (keeps ns/apps workloads alive)"
    while IFS= read -r _app; do
      [[ -n "$_app" ]] || continue
      kubectl -n argocd patch "$_app" --type merge \
        -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done <<< "$_apps"
  fi
  unset _apps _app
fi

for _ns in argocd tekton-pipelines; do
  if kubectl get ns "$_ns" >/dev/null 2>&1; then
    log "  removing namespace/$_ns (ArgoCD/Tekton retired in v0.3)"
    kubectl delete ns "$_ns" --ignore-not-found --wait=false >/dev/null
  fi
done

# (b) v0.3.0's in-cluster data layer (StatefulSets in infra-bridges) —
#     reverted in v0.3.1 before any real box deployed it; the data layer is
#     host Compose again. Remove the workloads/config so the ExternalName
#     bridge Services below can apply cleanly. PVCs are deliberately NOT
#     touched: if a v0.3.0 install does exist, its data must be dumped and
#     migrated by hand, never deleted by a cleanup pass.
for _res in statefulset/postgres deployment/redis statefulset/rabbitmq \
            statefulset/manticore configmap/postgres-init \
            configmap/manticore-confd secret/infra-bridges-auth; do
  kubectl -n infra-bridges delete "$_res" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
kubectl -n infra-bridges delete ingressroute search mq --ignore-not-found >/dev/null 2>&1 || true
# v0.3.0's Services were selector-backed ClusterIP; applying an ExternalName
# Service over one is rejected (clusterIP is immutable) — delete them first.
for _svc in postgres redis rabbitmq manticore; do
  _svc_type=$(kubectl -n infra-bridges get svc "$_svc" -o jsonpath='{.spec.type}' 2>/dev/null || true)
  if [[ -n "$_svc_type" && "$_svc_type" != "ExternalName" ]]; then
    log "  removing infra-bridges/svc/$_svc (type=$_svc_type; replaced by ExternalName bridge)"
    kubectl -n infra-bridges delete svc "$_svc" >/dev/null
  fi
done
if kubectl -n infra-bridges get pvc -o name 2>/dev/null | grep -q .; then
  warn "infra-bridges still has PVCs from a v0.3.0 install — data NOT deleted; dump + migrate manually (kubectl -n infra-bridges get pvc)"
fi
unset _res _svc _svc_type

# (c) Argo Rollouts dashboard — controller-only in v0.3 (plugin default off).
if kubectl -n argo-rollouts get deployment argo-rollouts-dashboard >/dev/null 2>&1; then
  log "  removing argo-rollouts/deployment/argo-rollouts-dashboard (dashboard tier retired)"
  kubectl -n argo-rollouts delete deployment argo-rollouts-dashboard --ignore-not-found >/dev/null
fi

unset _ns
ok "Orphan cleanup done"

# -----------------------------------------------------------------------------
# Data-layer bridge (v0.3.1 — host Compose is the data layer in BOTH modes,
# owner decision; see the 修订记录 in
# docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md). Pods resolve
# postgres/redis/rabbitmq/manticore.infra-bridges.svc → ExternalName
# host.docker.internal → CoreDNS custom hosts entry (node InternalIP). The
# coredns-hosts-reconciler CronJob (part of the directory apply below)
# rewrites that entry within ~2min whenever a WSL restart hands the VM a new
# IP — the self-heal for what used to be the #1 whole-site outage mode.
# Ordering: the first manifest-sync run below deploys the app fleet, which
# needs a LIVE data path — bridge DNS must be up before that gate.
# -----------------------------------------------------------------------------
log "Applying data-layer bridge Services (infra-bridges → host Compose)..."
kubectl apply -f core/k8s/06-bridges/

# containerd does NOT hand pods the Docker Desktop-ism host.docker.internal —
# inject a CoreDNS custom server block resolving it to the node's InternalIP.
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
if [[ -n "$NODE_IP" ]]; then
  kubectl -n kube-system create configmap coredns-custom \
    --from-literal=hostdockerinternal.server="host.docker.internal:53 {
    hosts {
        ${NODE_IP} host.docker.internal
    }
}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  ok "CoreDNS host.docker.internal → ${NODE_IP} (bridge DNS live; reconciler self-heals drift)"
else
  err "node InternalIP not found — bridge DNS cannot be set and every app pod would CrashLoop."
  err "Inspect: kubectl get nodes -o wide"
  exit 1
fi

# Belt-and-braces: Phase 4's Compose health gate already proved the data
# services are up; re-check the host-side ports because the first
# manifest-sync below immediately deploys apps that depend on them.
for _port in 5432 6379 5672 9308; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/${_port}") 2>/dev/null; then
    err "data service port ${_port} not reachable on 127.0.0.1 — check: docker compose ps"
    exit 1
  fi
done
unset _port
ok "Data layer live on host (5432/6379/5672/9308) + bridge Services applied"

# -----------------------------------------------------------------------------
# buildkitd — the quenched build daemon block, KEPT VERBATIM from the Tekton
# era (core/k8s/08-buildkit is a do-not-modify directory). The buildctl
# CLIENT moved from a Tekton Task to scripts/ci/build-image.sh on the host,
# talking through the buildkitd-nodeport Service applied below.
# -----------------------------------------------------------------------------
kubectl apply -f core/k8s/08-buildkit/
# When buildkit is the active engine, block until the daemon is Ready so a
# workflow that fires right after bootstrap doesn't hit a not-yet-listening
# buildkitd (the build-image.sh step would otherwise fail its first connect).
if [[ "${BUILD_ENGINE_TASK}" == "buildkit" ]]; then
  log "Waiting for buildkitd (active build engine) to be Ready..."
  # 420s aligns with the daemon's own startup budget: its startupProbe allows
  # up to 6min (36×10s) when recovering a dirty cache — a 180s wait here gave
  # up while the daemon was still legitimately starting, and the || warn then
  # buried the one signal that ALL builds were about to fail. verify.sh now
  # carries a FAIL-level buildkit.daemon check as the persistent backstop.
  kubectl wait --for=condition=Available deployment/buildkitd -n buildkit --timeout=420s \
    || warn "buildkitd not Ready within 420s — builds WILL fail until it is; run ./verify.sh and check 'kubectl -n buildkit get pods'"
fi

# -----------------------------------------------------------------------------
# outpost-ci namespace objects: RBAC (SA outpost-sync — apps-ns apply rights +
# heartbeat CM write, NO cluster-admin), manifest-cache PVC, NodePorts
# (buildkitd gRPC 30750 + registry API 30500 for the host-side runner/CLI).
# -----------------------------------------------------------------------------
kubectl apply -f core/k8s/03-ci/rbac.yaml
kubectl apply -f core/k8s/03-ci/pvc.yaml
kubectl apply -f core/k8s/03-ci/nodeports.yaml
ok "outpost-ci RBAC + PVC + NodePorts applied"

# sync-scripts ConfigMap — canonical sources live in the repo; packed fresh on
# every bootstrap so script edits take effect without ConfigMap surgery (same
# split pattern as the retired update-manifest-script CM). notify-fanout.sh
# expects sign-webhook.sh next to it at /scripts inside the sync pod.
kubectl create configmap sync-scripts \
  --from-file=manifest-sync.sh=scripts/sync/manifest-sync.sh \
  --from-file=notify-fanout.sh=scripts/notify-fanout.sh \
  --from-file=sign-webhook.sh=platform/lib/sign-webhook.sh \
  -n outpost-ci \
  --dry-run=client -o yaml | kubectl apply -f -

# sync-config ConfigMap — NON-secret sync-job configuration rendered from
# .env (envFrom in cronjob.template.yaml). Secrets go in notify-secrets below.
kubectl create configmap sync-config \
  --from-literal=MANIFEST_REPO_URL="${MANIFEST_REPO_URL}" \
  --from-literal=MANIFEST_BRANCH="${MANIFEST_REPO_BRANCH}" \
  --from-literal=APPS_NAMESPACE="apps" \
  --from-literal=SYNC_NAMESPACE="outpost-ci" \
  --from-literal=NOTIFY_PROVIDERS="${NOTIFICATION_PROVIDERS:-}" \
  --from-literal=OUTPOST_ENV="${OUTPOST_ENV:-dev}" \
  -n outpost-ci \
  --dry-run=client -o yaml | kubectl apply -f -

# notify-secrets Secret — secret-shaped env for the sync job (envFrom):
# notification webhook URLs/secrets + the git credentials manifest-sync uses
# to pull the manifest repo (it synthesizes ~/.git-credentials from
# GIT_USER/GIT_TOKEN — see scripts/sync/manifest-sync.sh). Values are piped
# straight into kubectl and NEVER logged; do not add echo/log lines here.
_NS_ARGS=(
  --from-literal=GIT_USER="${GIT_USER}"
  --from-literal=GIT_TOKEN="${GIT_TOKEN}"
)
# Generic webhook doubles as manifest-sync's fallback NOTIFY_WEBHOOK_URL.
[[ -n "${GENERIC_WEBHOOK_URL:-}" ]]    && _NS_ARGS+=( --from-literal=NOTIFY_WEBHOOK_URL="${GENERIC_WEBHOOK_URL}" )
[[ -n "${DINGTALK_WEBHOOK_URL:-}" ]]   && _NS_ARGS+=( --from-literal=DINGTALK_WEBHOOK_URL="${DINGTALK_WEBHOOK_URL}" )
[[ -n "${DINGTALK_SIGN_SECRET:-}" ]]   && _NS_ARGS+=( --from-literal=DINGTALK_SIGN_SECRET="${DINGTALK_SIGN_SECRET}" )
[[ -n "${FEISHU_WEBHOOK_URL:-}" ]]     && _NS_ARGS+=( --from-literal=FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL}" )
[[ -n "${FEISHU_SIGN_SECRET:-}" ]]     && _NS_ARGS+=( --from-literal=FEISHU_SIGN_SECRET="${FEISHU_SIGN_SECRET}" )
[[ -n "${WECOM_WEBHOOK_URL:-}" ]]      && _NS_ARGS+=( --from-literal=WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL}" )
[[ -n "${GENERIC_WEBHOOK_BEARER:-}" ]] && _NS_ARGS+=( --from-literal=GENERIC_WEBHOOK_BEARER="${GENERIC_WEBHOOK_BEARER}" )
kubectl create secret generic notify-secrets \
  "${_NS_ARGS[@]}" \
  -n outpost-ci \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset _NS_ARGS
ok "sync-scripts / sync-config / notify-secrets applied"

# manifest-sync CronJob — rendered (render_template: ${MANIFEST_SYNC_INTERVAL}
# must be set, 02-config guarantees it) then applied.
render_apply "core/k8s/03-ci/cronjob.template.yaml"
ok "manifest-sync CronJob applied (every ${MANIFEST_SYNC_INTERVAL} min, concurrencyPolicy=Forbid)"

# -----------------------------------------------------------------------------
# First sync — trigger one Job off the CronJob NOW and wait for a FRESH
# heartbeat. A bootstrap that can't complete one sync run is NOT a working
# install; timing out here is an honest FAIL (exit 1), not a warn-and-move-on.
# -----------------------------------------------------------------------------
log "Triggering first manifest-sync run and waiting for its heartbeat..."
_SYNC_START_TS=$(date +%s)
kubectl -n outpost-ci delete job manifest-sync-bootstrap --ignore-not-found >/dev/null 2>&1
kubectl -n outpost-ci create job manifest-sync-bootstrap --from=cronjob/manifest-sync >/dev/null
_HB_OK=0
for _ in $(seq 1 60); do   # 60 × 5s = 300s budget
  _hb_ts=$(kubectl -n outpost-ci get configmap sync-heartbeat \
    -o jsonpath='{.data.last_sync_ts}' 2>/dev/null || true)
  if [[ -n "$_hb_ts" && "$_hb_ts" -ge "$_SYNC_START_TS" ]] 2>/dev/null; then
    _HB_OK=1
    break
  fi
  sleep 5
done
if [[ "$_HB_OK" -ne 1 ]]; then
  err "manifest-sync first run produced no heartbeat within 300s."
  err "The CD engine is NOT working. Inspect:"
  err "  kubectl -n outpost-ci logs job/manifest-sync-bootstrap"
  err "  kubectl -n outpost-ci get pods"
  exit 1
fi
_hb_result=$(kubectl -n outpost-ci get configmap sync-heartbeat \
  -o jsonpath='{.data.last_result}' 2>/dev/null || echo "")
if [[ "$_hb_result" == "ok" ]]; then
  ok "First manifest-sync run OK (heartbeat fresh, last_result=ok)"
else
  err "First manifest-sync run wrote heartbeat but last_result='${_hb_result}'."
  err "Fix the sync path (credentials? manifest repo URL?), then re-run bootstrap:"
  err "  kubectl -n outpost-ci logs job/manifest-sync-bootstrap"
  exit 1
fi
unset _SYNC_START_TS _HB_OK _hb_ts _hb_result

# -----------------------------------------------------------------------------
# Base-image prepull + retag into the in-cluster registry.
# The sync CronJob (alpine/k8s) and Gate A test containers (node:22-alpine)
# must NOT depend on foreign egress on the hot/restart path: seed the images
# into (a) the in-cluster registry via the 30500 NodePort (127.0.0.1 is
# auto-insecure for docker push) and (b) the k3s containerd store under the
# canonical name, so a node restart re-uses the local copy instead of
# re-pulling docker.io. Pull goes via the DaoCloud mirror first (docker.io
# direct as fallback — daocloud allowlists per-org, alpine/* is unverified
# there; see OUTPOST_TEKTON_PRUNER_IMAGE's old rationale). Best-effort: a
# miss degrades to the pre-v0.3 behaviour (pull-on-demand), never a bootstrap
# failure.
# -----------------------------------------------------------------------------
log "Prepulling base images (zero foreign egress on hot/restart paths)..."
for _img in "alpine/k8s:1.31.0" "node:22-alpine"; do
  _pulled=0
  if docker pull "m.daocloud.io/docker.io/${_img}" >/dev/null 2>&1; then
    docker tag "m.daocloud.io/docker.io/${_img}" "${_img}"
    _pulled=1
  elif docker pull "${_img}" >/dev/null 2>&1; then
    _pulled=1
  fi
  if [[ "$_pulled" -ne 1 ]]; then
    warn "could not prepull ${_img} (daocloud + docker.io both failed) — hot path will pull on demand"
    continue
  fi
  # (a) copy into the in-cluster registry (rollback depth + restart insurance)
  if docker tag "${_img}" "127.0.0.1:30500/${_img}" \
     && docker push "127.0.0.1:30500/${_img}" >/dev/null 2>&1; then
    ok "  ${_img} → in-cluster registry (127.0.0.1:30500)"
  else
    warn "  push of ${_img} to in-cluster registry failed (registry NodePort up?)"
  fi
  # (b) seed the k3s containerd image store under the canonical ref
  case "$SK_OS" in
    linux|wsl2)
      if docker save "${_img}" | sudo k3s ctr images import - >/dev/null 2>&1; then
        ok "  ${_img} seeded into k3s containerd"
      else
        warn "  containerd seed of ${_img} failed (non-fatal)"
      fi
      ;;
    macos)
      if command -v k3d >/dev/null 2>&1; then
        k3d image import "${_img}" -c "${OUTPOST_K3D_CLUSTER:-selfhost}" >/dev/null 2>&1 \
          && ok "  ${_img} imported into k3d" \
          || warn "  k3d image import of ${_img} failed (non-fatal)"
      fi
      ;;
  esac
done
unset _img _pulled

# -----------------------------------------------------------------------------
# GitHub Actions self-hosted runner — the CI trigger surface.
# GITHUB_RUNNER_PAT is used ONLY to mint a short-lived registration token via
# the GitHub API; it is never persisted into the runner and NEVER echoed.
# Empty PAT = supported CI/e2e mode: skip with a loud WARN block.
# -----------------------------------------------------------------------------
if [[ -z "${GITHUB_RUNNER_PAT:-}" ]]; then
  warn "════════════════════════════════════════════════════════════════════"
  warn " GITHUB_RUNNER_PAT is EMPTY — skipping GitHub Actions runner install."
  warn " NO CI builds will trigger until a runner is registered:"
  warn "   1. set GITHUB_RUNNER_URL (https://github.com/<org>) and"
  warn "      GITHUB_RUNNER_PAT (admin:org scope) in .env"
  warn "   2. re-run: bash bootstrap.sh"
  warn " This is the expected state ONLY for CI/e2e runs of this repo itself."
  warn "════════════════════════════════════════════════════════════════════"
else
  RUNNER_DIR="${GITHUB_RUNNER_DIR:-$HOME/actions-runner}"
  RUNNER_VERSION="${GITHUB_RUNNER_VERSION:-2.328.0}"
  case "$SK_OS" in
    macos) _RUNNER_OS="osx" ;;
    *)     _RUNNER_OS="linux" ;;
  esac
  case "$(uname -m)" in
    aarch64|arm64) _RUNNER_ARCH="arm64" ;;
    *)             _RUNNER_ARCH="x64" ;;
  esac

  # --- download (github.com direct, ghfast.top CN-accelerator fallback —
  #     same pattern as the kubeseal download in 06-sealed-secrets.sh) ---
  if [[ ! -x "$RUNNER_DIR/config.sh" ]]; then
    log "Downloading actions-runner v${RUNNER_VERSION} (${_RUNNER_OS}-${_RUNNER_ARCH})..."
    mkdir -p "$RUNNER_DIR"
    _RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${_RUNNER_OS}-${_RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    if ! curl -fsSL --connect-timeout 15 --max-time 600 "$_RUNNER_URL" | tar -xz -C "$RUNNER_DIR" 2>/dev/null; then
      warn "runner download from github.com timed out/failed — retrying via ghfast.top (CN accelerator)"
      if ! curl -fsSL --connect-timeout 15 --max-time 600 "https://ghfast.top/${_RUNNER_URL}" | tar -xz -C "$RUNNER_DIR"; then
        err "actions-runner download failed (github.com + ghfast.top). Download manually:"
        err "  $_RUNNER_URL → extract into $RUNNER_DIR, then re-run bootstrap."
        exit 1
      fi
    fi
    unset _RUNNER_URL
  fi

  # --- register (idempotent: skip when .runner already binds this URL) ---
  if [[ -f "$RUNNER_DIR/.runner" ]] && grep -qF "${GITHUB_RUNNER_URL%/}" "$RUNNER_DIR/.runner"; then
    ok "Runner already registered against ${GITHUB_RUNNER_URL} — skipping config.sh"
  else
    # API path: org URL (no second path segment) → /orgs/<org>/…,
    # single-repo URL → /repos/<owner>/<repo>/….
    _GH_PATH="${GITHUB_RUNNER_URL#https://github.com/}"
    _GH_PATH="${_GH_PATH%/}"
    if [[ "$_GH_PATH" == */* ]]; then
      _GH_API="repos/${_GH_PATH}"
    else
      _GH_API="orgs/${_GH_PATH}"
    fi
    log "Minting runner registration token (PAT is masked — never logged)..."
    # SECURITY: token + PAT must never hit stdout/stderr. Extraction via sed
    # keeps everything in variables; no set -x in bootstrap.
    _REG_TOKEN=$(curl -fsS --max-time 30 -X POST \
      -H "Authorization: Bearer ${GITHUB_RUNNER_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/${_GH_API}/actions/runners/registration-token" 2>/dev/null \
      | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    if [[ -z "$_REG_TOKEN" ]]; then
      err "Could not mint a runner registration token from api.github.com."
      err "Check: GITHUB_RUNNER_PAT scope (admin:org for org URLs, repo admin"
      err "for repo URLs), GITHUB_RUNNER_URL (${GITHUB_RUNNER_URL}), and proxy/egress."
      exit 1
    fi
    _RUNNER_NAME="${GITHUB_RUNNER_NAME:-outpost-$(hostname)}"
    log "Registering runner '${_RUNNER_NAME}' (labels: ${GITHUB_RUNNER_LABELS:-outpost})..."
    ( cd "$RUNNER_DIR" && ./config.sh --unattended --replace \
        --url "$GITHUB_RUNNER_URL" \
        --token "$_REG_TOKEN" \
        --name "$_RUNNER_NAME" \
        --labels "${GITHUB_RUNNER_LABELS:-outpost}" )
    unset _REG_TOKEN _RUNNER_NAME _GH_PATH _GH_API
    ok "Runner registered against ${GITHUB_RUNNER_URL}"
  fi

  # --- runner env file: OUTPOST_ROOT + proxy (job env, read by the runner) ---
  # The workflow template resolves every script via $OUTPOST_ROOT; proxy vars
  # come from ~/.outpost-proxy.env when present (v2ray et al).
  _renv="$RUNNER_DIR/.env"
  touch "$_renv"
  _runner_env_set() {
    # replace-or-append KEY=VALUE in the runner .env (bash-3.2, portable awk)
    local key="$1" val="$2" tmp
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
      BEGIN { done = 0 }
      { if ($0 ~ "^" k "=") { printf "%s=%s\n", k, v; done = 1 } else { print } }
      END { if (!done) printf "%s=%s\n", k, v }
    ' "$_renv" > "$tmp"
    mv "$tmp" "$_renv"
  }
  _runner_env_set OUTPOST_ROOT "$INFRA_ROOT"
  if [[ -f "$HOME/.outpost-proxy.env" ]]; then
    log "Applying proxy config from ~/.outpost-proxy.env to the runner env..."
    # shellcheck disable=SC1091
    ( set -a; source "$HOME/.outpost-proxy.env"; set +a
      for _pv in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
        [[ -n "${!_pv:-}" ]] && _runner_env_set "$_pv" "${!_pv}"
      done )
  fi
  unset _renv

  # --- systemd/launchd service via the official svc.sh ---
  log "Installing runner service (svc.sh)..."
  case "$SK_OS" in
    linux|wsl2)
      ( cd "$RUNNER_DIR" \
        && { sudo ./svc.sh install "$USER" 2>/dev/null || true; } \
        && sudo ./svc.sh start ) \
        || warn "runner svc.sh install/start reported issues — check 'systemctl status actions.runner.*'"
      ;;
    macos)
      ( cd "$RUNNER_DIR" \
        && { ./svc.sh install 2>/dev/null || true; } \
        && ./svc.sh start ) \
        || warn "runner svc.sh install/start reported issues — check './svc.sh status' in $RUNNER_DIR"
      ;;
  esac
  ok "GitHub Actions runner service installed (dir: $RUNNER_DIR)"
  unset RUNNER_DIR RUNNER_VERSION _RUNNER_OS _RUNNER_ARCH
fi

# -----------------------------------------------------------------------------
# Dead-man switch: outpost-verify.timer runs verify.sh --quiet every 30min
# from the HOST's systemd (outside cluster + GitHub) and notifies on FAIL.
# linux/wsl2 only — macOS has no systemd (launchd users: run
# platform/systemd/outpost-verify-run.sh from a LaunchAgent).
# -----------------------------------------------------------------------------
case "$SK_OS" in
  linux|wsl2)
    log "Installing outpost-verify systemd timer (dead-man switch)..."
    export OUTPOST_ROOT="$INFRA_ROOT"
    # Render the unit to run as the OPERATOR (kubeconfig/docker/.env live in
    # this account) — root would miss ~/.kube/config and probe a dead API.
    export OUTPOST_UNIT_USER="$USER"
    export OUTPOST_UNIT_HOME="$HOME"
    _SVC_OUT=$(mktemp)
    # The .service is a render_template exception to *.template.yaml naming:
    # systemd requires the literal unit filename (see the file's header).
    if ! render_template "platform/systemd/outpost-verify.service" "$_SVC_OUT"; then
      rm -f "$_SVC_OUT"
      err "Failed to render outpost-verify.service"
      exit 1
    fi
    sudo cp "$_SVC_OUT" /etc/systemd/system/outpost-verify.service
    rm -f "$_SVC_OUT"; unset _SVC_OUT
    sudo cp platform/systemd/outpost-verify.timer /etc/systemd/system/outpost-verify.timer
    chmod +x platform/systemd/outpost-verify-run.sh
    sudo systemctl daemon-reload
    sudo systemctl enable --now outpost-verify.timer
    ok "outpost-verify.timer enabled (OnBootSec=5min, OnUnitActiveSec=30min, Persistent=true)"
    ;;
  macos)
    warn "macOS: outpost-verify.timer skipped (no systemd) — schedule platform/systemd/outpost-verify-run.sh via launchd if you want the dead-man switch"
    ;;
esac

ok "CI engine phase complete (buildkit + manifest-sync + runner + verify timer)"
