# shellcheck shell=bash
# =============================================================================
# Phase 9 — CI/CD test gate + auto-rollback + notifications.
# Wires up Gate A (Tekton run-tests Task), Gate B (Argo Rollouts canary +
# auto-rollback), and multi-channel notifications. Idempotent: safe to re-run.
# =============================================================================
phase "Phase 9 / 10 Test gate, auto-rollback, notifications"

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
  catalog-tasks)
    log "Installing Tekton Catalog test tasks..."
    for _task in golang-test pytest jest junit-runner dotnet-test; do
      kubectl apply -n tekton-pipelines \
        -f "https://raw.githubusercontent.com/tektoncd/catalog/main/task/${_task}/0.1/${_task}.yaml" \
        2>/dev/null || warn "  catalog task ${_task} not found at 0.1; check manually"
    done
    unset _task
    ;;
esac
render_apply "plugins/test-runner/${TEST_RUNNER}/manifest.yaml"

# Apply the run-tests Task (uses the active runner).
kubectl apply -f core/k8s/05-tekton/run-tests-task.yaml
ok "Test runner ready"

# ---- 9b. Rollout plugin (Argo Rollouts) ----
log "Installing rollout plugin: ${ROLLOUT_PLUGIN}"
if [[ "${ROLLOUT_PLUGIN}" == "argo-rollouts" ]]; then
  # Server-side apply — Rollouts CRDs are large, same rationale as ArgoCD/Tekton.
  # Vendored (core/k8s/vendor/) instead of curl'd from github.com/.../latest/
  # download/ at install time — that host is intermittently throttled/blocked
  # in CN, and the old `latest` path floated (a re-bootstrap months apart
  # could silently jump major versions). See each file's header for upgrade
  # instructions.
  kubectl apply --server-side=true --force-conflicts -n argo-rollouts \
    -f core/k8s/vendor/argo-rollouts-install-v1.9.0.yaml
  kubectl apply --server-side=true --force-conflicts -n argo-rollouts \
    -f core/k8s/vendor/argo-rollouts-dashboard-install-v1.9.0.yaml
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
  render_apply "plugins/rollout/${ROLLOUT_PLUGIN}/ingressroute.yaml"
fi
ok "Rollout plugin ready (https://${ROLLOUTS_DASHBOARD_HOST})"

# ---- 9c. Notifications ----
# argocd-notifications is shipped as part of ArgoCD core (>=2.3); the controller
# auto-discovers argocd-notifications-cm + argocd-notifications-secret.

# Pre-step: ConfigMap for the notify-task's mounted scripts. Carries both
# scripts/notify-fanout.sh (canonical, replaces v0.2's 80-line inline bash)
# and platform/lib/sign-webhook.sh (signing math — single source of truth,
# no more mirroring with the YAML). Apply unconditionally so the notify-task
# (which is applied in both NOTIFICATION_PROVIDERS branches below) always
# has its scripts volume populated. v0.4 will bake outpost/notify-runner:v1
# with these scripts + jq/curl/gettext/openssl pre-installed, eliminating
# the per-PipelineRun apk-add cost.
kubectl create configmap notify-runner-scripts \
  --from-file=notify-fanout.sh=scripts/notify-fanout.sh \
  --from-file=sign-webhook.sh=platform/lib/sign-webhook.sh \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${NOTIFICATION_PROVIDERS}" ]]; then
  log "Wiring notifications: ${NOTIFICATION_PROVIDERS}"

  # Build combined argocd-notifications-cm by concatenating base + per-plugin
  # fragments. Same pattern for argocd-notifications-secret. Both base files
  # leave their `data:` / `stringData:` sections empty so plugin fragments
  # can be appended as indented k:v lines.
  ARGO_CM_OUT="$(mktemp)"
  ARGO_SECRET_OUT="$(mktemp)"
  trap 'rm -f "$ARGO_CM_OUT" "$ARGO_SECRET_OUT"' EXIT

  cp core/k8s/04-argocd/notifications-cm.template.yaml "$ARGO_CM_OUT"
  cp core/k8s/04-argocd/notifications-secret.template.yaml "$ARGO_SECRET_OUT"

  # Notification manifest.yaml mixes install-time vars (DINGTALK_WEBHOOK_URL etc.)
  # with runtime vars (${NOTIFY_*}) inside body.tmpl. Use targeted
  # substitution so the runtime placeholders survive into the ConfigMap.
  NOTIFY_ALLOWLIST="DINGTALK_WEBHOOK_URL DINGTALK_SIGN_SECRET FEISHU_WEBHOOK_URL FEISHU_SIGN_SECRET WECOM_WEBHOOK_URL GENERIC_WEBHOOK_URL GENERIC_WEBHOOK_BEARER ROOT_DOMAIN"

  IFS=',' read -ra _np <<< "${NOTIFICATION_PROVIDERS}"
  # Plugin service short-names (template suffix + service.webhook.<short>):
  #   dingtalk → dingtalk, feishu → feishu, wecom → wecom, webhook-generic → generic
  # Keep in sync with each plugin's argocd-cm-fragment.yaml service block.
  _to_short() {
    case "$1" in
      webhook-generic) echo "generic" ;;
      *)               echo "$1" ;;
    esac
  }
  _shorts=()
  for _p in "${_np[@]}"; do
    _p="${_p// /}"
    [[ -z "$_p" ]] && continue
    log "  notification plugin: ${_p}"
    # Per-plugin Tekton-side resources. Targeted substitution preserves
    # ${NOTIFY_*} runtime placeholders inside body.tmpl.
    _tmp_manifest=$(mktemp)
    render_template_only "plugins/notification/${_p}/manifest.yaml" "$_tmp_manifest" "$NOTIFY_ALLOWLIST"
    kubectl apply -f "$_tmp_manifest"
    rm -f "$_tmp_manifest"
    # Append per-plugin argocd fragments (already 2-space-indented to fit
    # under data: / stringData:).
    cat "plugins/notification/${_p}/argocd-cm-fragment.yaml" >> "$ARGO_CM_OUT"
    cat "plugins/notification/${_p}/argocd-secret-fragment.yaml" >> "$ARGO_SECRET_OUT"
    _shorts+=("$(_to_short "$_p")")
  done
  unset _np _p _tmp_manifest

  # Substitute placeholders in the assembled cm. Each trigger's `send:` list
  # needs the actual template names that the plugin fragments contributed
  # (e.g. app-deployed-dingtalk, app-deployed-feishu); the subscriptions
  # `recipients:` needs the actual service names (webhook.dingtalk, ...).
  # Without this step the literal `_PLUGIN_*_` strings remain in the cm
  # and argocd-notifications-controller logs `unknown template` for every
  # firing — silent failure mode.
  _join() { local IFS=", "; echo "$*"; }
  _tmpl_for_event() {
    # Build "app-<event>-<short1>, app-<event>-<short2>, ..."
    local event="$1" out=() s
    for s in "${_shorts[@]}"; do out+=("app-${event}-${s}"); done
    _join "${out[@]}"
  }
  _recipients() {
    local out=() s
    for s in "${_shorts[@]}"; do out+=("webhook.${s}"); done
    _join "${out[@]}"
  }
  # sed -i differs on macOS vs GNU; use a temp + mv for portability.
  _ARGO_CM_FILLED="$(mktemp)"
  sed \
    -e "s|_PLUGIN_TEMPLATES_DEPLOYED_|$(_tmpl_for_event deployed)|g" \
    -e "s|_PLUGIN_TEMPLATES_SYNC_FAILED_|$(_tmpl_for_event sync-failed)|g" \
    -e "s|_PLUGIN_TEMPLATES_DEGRADED_|$(_tmpl_for_event degraded)|g" \
    -e "s|_PLUGIN_TEMPLATES_DELETED_|$(_tmpl_for_event deleted)|g" \
    -e "s|_PLUGIN_TEMPLATES_ROLLBACK_|$(_tmpl_for_event rollback)|g" \
    -e "s|_PLUGIN_RECIPIENTS_|$(_recipients)|g" \
    "$ARGO_CM_OUT" > "$_ARGO_CM_FILLED"
  mv "$_ARGO_CM_FILLED" "$ARGO_CM_OUT"
  unset _shorts _tmpl_for_event _recipients _join _to_short _ARGO_CM_FILLED

  # Defensive: fail loudly if any placeholder survived (means a future
  # template added _PLUGIN_*_ without updating the sed list above).
  if grep -q '_PLUGIN_[A-Z_]*_' "$ARGO_CM_OUT"; then
    err "argocd-notifications-cm has unsubstituted _PLUGIN_*_ placeholders:"
    grep '_PLUGIN_[A-Z_]*_' "$ARGO_CM_OUT" | sed 's/^/    /'
    exit 1
  fi

  # Render envsubst on the combined files (resolves ${ROOT_DOMAIN} in templates,
  # ${DINGTALK_WEBHOOK_URL} in secret data, etc.) then apply.
  render_apply "$ARGO_CM_OUT"
  render_apply "$ARGO_SECRET_OUT"

  # Apply the shared Tekton notify-task (called from pipeline-build.yaml `finally`).
  kubectl apply -f core/k8s/05-tekton/notify-task.yaml
  ok "Notifications ready (${NOTIFICATION_PROVIDERS})"
else
  log "NOTIFICATION_PROVIDERS empty — skipping notification wiring"
  # Apply the notify-task anyway so pipeline-build's finally block resolves;
  # with no provider Secrets mounted, the fanout step no-ops with [WARN] logs.
  kubectl apply -f core/k8s/05-tekton/notify-task.yaml
fi

# Re-render pipeline-build with the now-canonical NOTIFICATION_PROVIDERS so
# the finally step receives the right provider list.
render_apply "core/k8s/05-tekton/pipeline-build.yaml"
