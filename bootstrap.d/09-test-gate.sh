# shellcheck shell=bash
# =============================================================================
# Phase 9 — CI/CD test gate + rollout plugin + notifications.
# v0.3: Gate A runs on the HOST (scripts/ci/run-tests.sh, called by the GHA
# workflow — nothing to install in-cluster for it); the rollout plugin is
# opt-in controller-only (ROLLOUT_PLUGIN=none default); notification plugin
# manifests land in ns outpost-ci (consumed by the manifest-sync CronJob and
# host-side notify-fanout callers). Idempotent: safe to re-run.
# =============================================================================
phase "Phase 9 / 10 Test gate, rollout plugin, notifications"

# ---- 9a. Test runner ----
log "Installing test-runner: ${TEST_RUNNER}"
case "${TEST_RUNNER}" in
  testkube)
    if [[ "${TESTKUBE_MODE}" == "skip" ]]; then
      log "TESTKUBE_MODE=skip — not installing the Testkube agent (run-tests evals outpost.test.yaml inline; set TESTKUBE_MODE=oss when Phase 2 adopts TestWorkflows)"
    elif [[ "${TESTKUBE_MODE}" == "oss" ]]; then
      # Auto-install helm if missing.
      # macOS path: prefer brew (no sudo prompt mid-bootstrap). Otherwise
      # fall back to the same tarball-and-sudo dance as kubeseal.
      if ! command -v helm >/dev/null 2>&1; then
        if [[ "$SK_OS" == "macos" ]] && command -v brew >/dev/null 2>&1; then
          log "Installing helm via brew (macOS)..."
          brew install helm 2>&1 | tail -3
        else
          log "Downloading helm v3.16..."
          HELM_VER="3.16.4"
          case "$SK_OS" in
            macos) HELM_OS="darwin" ;;
            *)     HELM_OS="linux" ;;
          esac
          if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
            HELM_ARCH="arm64"
          else
            HELM_ARCH="amd64"
          fi
          TMP_HELM=$(mktemp -d)
          curl -sSL "https://get.helm.sh/helm-v${HELM_VER}-${HELM_OS}-${HELM_ARCH}.tar.gz" \
            | tar -xz -C "$TMP_HELM"
          sudo mv "$TMP_HELM/${HELM_OS}-${HELM_ARCH}/helm" /usr/local/bin/
          sudo chmod +x /usr/local/bin/helm
          rm -rf "$TMP_HELM"
        fi
        ok "helm installed: $(helm version --short)"
      fi
      log "Installing Testkube via helm (oss mode)..."
      helm repo add kubeshop https://kubeshop.github.io/helm-charts >/dev/null 2>&1 || true
      helm repo update kubeshop >/dev/null 2>&1 || true
      helm upgrade --install testkube kubeshop/testkube \
        --namespace testkube \
        --create-namespace \
        --wait --timeout 300s \
        --set global.cloud.uiBaseUrl="" \
        2>&1 | tail -20 || warn "testkube helm install reported issues — check 'kubectl get pods -n testkube'"
    else
      log "TESTKUBE_MODE=cloud — skipping local agent install (configure CLI later)"
    fi
    ;;
esac
render_apply "plugins/test-runner/${TEST_RUNNER}/manifest.yaml"
# Gate A itself is host-side now: scripts/ci/run-tests.sh (called by the GHA
# workflow), opt-in per app via outpost.test.yaml — no in-cluster Task.
ok "Test runner ready (Gate A runs on the host via scripts/ci/run-tests.sh)"

# ---- 9b. Rollout plugin (opt-in, controller-only) ----
log "Rollout plugin: ${ROLLOUT_PLUGIN}"
if [[ "${ROLLOUT_PLUGIN}" == "argo-rollouts" ]]; then
  # Controller ONLY — the dashboard (and its BasicAuth IngressRoute) retired
  # with the ArgoCD/Tekton dashboard tier in v0.3. Server-side apply —
  # Rollouts CRDs are large. Vendored (core/k8s/vendor/) instead of curl'd
  # from github.com/.../latest/download/ at install time — that host is
  # intermittently throttled/blocked in CN, and a floating `latest` could
  # silently jump major versions. See the vendor file's header to upgrade.
  kubectl apply --server-side=true --force-conflicts -n argo-rollouts \
    -f core/k8s/vendor/argo-rollouts-install-v1.9.0.yaml
  kubectl wait --for=condition=Available --timeout=180s \
    deployment/argo-rollouts -n argo-rollouts 2>/dev/null || \
    warn "argo-rollouts controller still rolling — apply continues"

  render_apply "plugins/rollout/${ROLLOUT_PLUGIN}/manifest.yaml"
  render_apply "plugins/rollout/${ROLLOUT_PLUGIN}/analysistemplate-default.yaml"
  if [[ "${TEST_RUNNER}" == "testkube" ]]; then
    render_apply "plugins/rollout/${ROLLOUT_PLUGIN}/analysistemplate-smoke.yaml"
  else
    log "  Skipping smoke AnalysisTemplate (test-runner != testkube)"
  fi
  ok "Rollout plugin ready (controller-only; apps opt in via the Rollout CRD)"
else
  log "ROLLOUT_PLUGIN=none — canary/auto-rollback disabled (set argo-rollouts to enable)"
fi

# ---- 9c. Notifications ----
# v0.3: argocd-notifications is gone with ArgoCD. Notification events are
# emitted by three callers, all through scripts/notify-fanout.sh:
#   build-failed                    GHA workflow step (host)
#   deploy-succeeded/deploy-failed  manifest-sync CronJob (in-cluster)
#   verify-failed                   outpost-verify.timer (host)
# Each enabled plugin's manifest.yaml contributes its Secret (webhook-url /
# sign-secret) + body-template ConfigMap in ns outpost-ci.
if [[ -n "${NOTIFICATION_PROVIDERS}" ]]; then
  log "Wiring notifications: ${NOTIFICATION_PROVIDERS}"

  # Notification manifest.yaml mixes install-time vars (DINGTALK_WEBHOOK_URL
  # etc.) with runtime vars (${NOTIFY_*}) inside body.tmpl. Use targeted
  # substitution so the runtime placeholders survive into the ConfigMap.
  NOTIFY_ALLOWLIST="DINGTALK_WEBHOOK_URL DINGTALK_SIGN_SECRET FEISHU_WEBHOOK_URL FEISHU_SIGN_SECRET WECOM_WEBHOOK_URL GENERIC_WEBHOOK_URL GENERIC_WEBHOOK_BEARER ROOT_DOMAIN"

  IFS=',' read -ra _np <<< "${NOTIFICATION_PROVIDERS}"
  for _p in "${_np[@]}"; do
    _p="${_p// /}"
    [[ -z "$_p" ]] && continue
    log "  notification plugin: ${_p}"
    # SECURITY: the rendered manifest carries cleartext webhook URLs/secrets —
    # render to a 0600 temp file and clean up on the failure path too.
    _tmp_manifest=$(mktemp)
    chmod 0600 "$_tmp_manifest"
    if ! render_template_only "plugins/notification/${_p}/manifest.yaml" "$_tmp_manifest" "$NOTIFY_ALLOWLIST"; then
      rm -f "$_tmp_manifest"
      err "render of notification plugin '${_p}' failed"
      exit 1
    fi
    if ! kubectl apply -f "$_tmp_manifest" >/dev/null; then
      rm -f "$_tmp_manifest"
      err "kubectl apply for notification plugin '${_p}' failed"
      exit 1
    fi
    rm -f "$_tmp_manifest"
  done
  unset _np _p _tmp_manifest
  ok "Notifications ready (${NOTIFICATION_PROVIDERS})"
else
  log "NOTIFICATION_PROVIDERS empty — CI/CD events will be log-only (set NOTIFICATION_PROVIDERS to enable)"
fi
