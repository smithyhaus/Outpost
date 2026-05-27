# shellcheck shell=bash
# =============================================================================
# Phase 8 — ArgoCD + Tekton + bridges + dashboard BasicAuth.
# Largest phase: ArgoCD install, Tekton install, git-provider plugin apply,
# catalog tasks, Pipeline + TriggerTemplate + EventListener, dashboard auth.
# =============================================================================
phase "Phase 8 / 10 ArgoCD, Tekton, bridges"

# -----------------------------------------------------------------------------
# Cleanup: orphans from earlier bootstrap versions.
#
# Scope is intentionally narrow — each entry is a resource THIS bootstrap
# created in a previous version with a name that has since changed. We only
# touch exact (kind, namespace, name) tuples we know we own. No wildcards.
# Every command is ignore-not-found so this is a no-op on a clean cluster.
# -----------------------------------------------------------------------------
log "Cleaning orphans from earlier bootstrap versions (narrow, no wildcards)..."

# (a) Tekton catalog Tasks accidentally applied to `default` namespace by a
#     pre-v0.2 bootstrap (the old `kubectl apply -f .../catalog/...` had no
#     -n flag). Current bootstrap installs them in tekton-pipelines.
for _t in git-clone kaniko; do
  if kubectl get -n default task "$_t" >/dev/null 2>&1; then
    log "  removing default/task/$_t (left over from old bootstrap)"
    kubectl delete -n default task "$_t" --ignore-not-found >/dev/null
  fi
done

# (b) Secrets renamed in v0.2 (provider-agnostic naming).
#       gitee-credentials   -> git-credentials   (tekton-pipelines)
#       gitee-manifest-repo -> git-manifest-repo (argocd)
#     Old Secrets are unreferenced after the rename; safe to delete.
for _entry in "tekton-pipelines:gitee-credentials" "argocd:gitee-manifest-repo"; do
  _ns="${_entry%%:*}"; _name="${_entry##*:}"
  if kubectl get -n "$_ns" secret "$_name" >/dev/null 2>&1; then
    log "  removing $_ns/secret/$_name (renamed in v0.2)"
    kubectl delete -n "$_ns" secret "$_name" --ignore-not-found >/dev/null
  fi
done

# (c) Trigger-fragment ConfigMaps removed in v0.3.
#     Pre-v0.3 plugins shipped <provider>-trigger-fragment ConfigMaps;
#     v0.3 reads the sibling trigger.yaml file directly, so these CMs
#     are now dead state in the cluster. Safe to delete (no consumer).
for _name in gitee-trigger-fragment github-trigger-fragment gitlab-trigger-fragment; do
  if kubectl get -n tekton-pipelines configmap "$_name" >/dev/null 2>&1; then
    log "  removing tekton-pipelines/configmap/$_name (replaced by sibling trigger.yaml in v0.3)"
    kubectl delete -n tekton-pipelines configmap "$_name" --ignore-not-found >/dev/null
  fi
done

# (d) EventListener renamed in v0.3.
#     Pre-v0.3 name was `gitee-listener` (provider-specific). v0.3 uses
#     `build-listener` (provider-agnostic, populated from the active
#     GIT_PROVIDER_PLUGIN). Service name follows: el-gitee-listener →
#     el-build-listener.
if kubectl get -n tekton-pipelines eventlistener gitee-listener >/dev/null 2>&1; then
  log "  removing tekton-pipelines/eventlistener/gitee-listener (renamed to build-listener in v0.3)"
  kubectl delete -n tekton-pipelines eventlistener gitee-listener --ignore-not-found >/dev/null
fi

unset _t _entry _ns _name
ok "Orphan cleanup done"

# ArgoCD
# Server-side apply: ArgoCD's applicationsets CRD has annotations that
# exceed the 256KB client-side-apply limit. --force-conflicts also lets
# us own fields previously client-side-applied (re-runs).
kubectl apply --server-side=true --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f core/k8s/04-argocd/cmd-params-cm.yaml
kubectl rollout restart deployment/argocd-server -n argocd

render_apply "core/k8s/04-argocd/ingress.yaml"
render_apply "core/k8s/04-argocd/repo-secret.template.yaml"
render_apply "core/k8s/04-argocd/bootstrap-app.yaml"

# Enable /api/webhook receiver. Without these keys argocd-server returns 401
# for every push payload and the manifest repo's webhook delivery log fills
# up with red. Patch (not full apply) so we don't overwrite cmd-params-cm's
# server.insecure flag that's also in argocd-cm.
log "Patching argocd-cm with webhook secrets..."
_WEBHOOK_PATCH=$(mktemp)
render_template "core/k8s/04-argocd/webhook-cm-patch.template.yaml" "$_WEBHOOK_PATCH"
kubectl patch -n argocd configmap argocd-cm --type merge --patch-file "$_WEBHOOK_PATCH"
rm -f "$_WEBHOOK_PATCH"
unset _WEBHOOK_PATCH
ok "ArgoCD /api/webhook receiver enabled"

# Tekton — install pipelines + triggers CRDs and controllers.
# Same server-side-apply rationale as ArgoCD: Tekton's CRDs carry large
# OpenAPI schemas that can exceed the client-side-apply 256KB limit.
kubectl apply --server-side=true --force-conflicts \
  -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply --server-side=true --force-conflicts \
  -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply --server-side=true --force-conflicts \
  -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
sleep 10
kubectl wait --for=condition=Available --timeout=300s deployment --all -n tekton-pipelines || warn "some tekton deploys still rolling"

# Tekton release.yaml sets pod-security.kubernetes.io/enforce=restricted on
# the tekton-pipelines namespace. That's appropriate for the controllers,
# but PipelineRuns also spawn pods in this namespace and the catalog
# Tasks (git-clone, kaniko) need privileges restricted blocks (capabilities,
# allowPrivilegeEscalation, runAsRoot for kaniko's chroot). Downgrade to
# `baseline` — still hardened, but compatible with Tekton's catalog Tasks.
# See https://tekton.dev/docs/concepts/podsecurity/
kubectl label --overwrite ns tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline

# Now that Tekton CRDs (incl. triggers.tekton.dev) are registered, apply the
# git-provider plugin (it contributes a TriggerBinding the EventListener uses).
log "Applying git-provider plugin: ${GIT_PROVIDER_PLUGIN}"
render_apply "plugins/git-provider/${GIT_PROVIDER_PLUGIN}/manifest.yaml"
ok "Git-provider plugin applied"

# Catalog tasks (git-clone, kaniko) — vendored under core/k8s/05-tekton/catalog/
# to (a) avoid silent breakage when raw.githubusercontent.com/.../main/...
# mutates, and (b) eliminate the bootstrap-time network dependency on
# raw.githubusercontent.com (intermittently throttled/blocked in CN).
# Regenerate with `bash scripts/vendor-tekton-catalog.sh`.
#
# Versions:
#   git-clone 0.10 — current tekton.dev/v1 API, supersedes 0.9 (v1beta1)
#   kaniko    0.7  — current v1 API. Kaniko upstream archived 2025-06-03;
#                    catalog task marked deprecated. Replacement tracked
#                    in TODOS.md ("buildah / kaniko v1.20+ replacement").
#                    Pinned executor v1.5.1 is a multi-arch manifest list
#                    (incl. linux/arm64), so Apple Silicon k3d works.
kubectl apply -n tekton-pipelines -f core/k8s/05-tekton/catalog/git-clone-0.10.yaml
kubectl apply -n tekton-pipelines -f core/k8s/05-tekton/catalog/kaniko-0.7.yaml

# Tekton RBAC + secrets + pipeline + binding/template
kubectl apply -f core/k8s/05-tekton/rbac.yaml
render_apply "core/k8s/05-tekton/secrets.template.yaml"
render_apply "core/k8s/05-tekton/pipeline-build.yaml"

# Tekton PipelineRun auto-pruner. Without this CronJob, finished PRs (and
# their kaniko build pods, ~1 GB ephemeral each) accumulate until the node
# hits DiskPressure and starts Evicting fresh builds. Hourly sweep keeps
# the namespace within bounded ephemeral usage. RBAC is namespace-scoped.
#
# Script split pattern (same as notify-fanout / update-manifest): canonical
# source in scripts/tekton-prune.sh, mounted via ConfigMap. Re-apply on every
# bootstrap so script edits take effect without manual surgery.
kubectl create configmap tekton-pruner-script \
  --from-file=tekton-prune.sh=scripts/tekton-prune.sh \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -
render_apply "core/k8s/05-tekton/pruner.yaml"
ok "Tekton auto-pruner installed (retain ${OUTPOST_TEKTON_RETENTION_HOURS}h, schedule '${OUTPOST_TEKTON_PRUNE_SCHEDULE}')"

# update-manifest Task is split: scripts/update-manifest.sh is the canonical
# source, mounted into the Task via this ConfigMap. Re-apply on every run so
# script edits take effect without manual ConfigMap surgery.
kubectl create configmap update-manifest-script \
  --from-file=update-manifest.sh=scripts/update-manifest.sh \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f core/k8s/05-tekton/task-update-manifest.yaml

# read-build-config Task — same split pattern: scripts/read-build-config.sh
# is canonical (bats-tested), mounted via ConfigMap into the Task. Reads
# optional outpost.build.yaml from cloned source and emits per-app kaniko
# inputs (dockerfile / context / merged extra-args).
kubectl create configmap read-build-config-script \
  --from-file=read-build-config.sh=scripts/read-build-config.sh \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f core/k8s/05-tekton/task-read-build-config.yaml

render_apply "core/k8s/05-tekton/triggertemplate.yaml"

# EventListener — provider-agnostic envelope + active plugin's trigger.yaml.
# Replaces the v0.1 hardcoded Gitee eventlistener.yaml; GIT_PROVIDER_PLUGIN
# now actually selects which provider routes webhooks.
# Inline cleanup (no EXIT trap) because Phase 9 sets its own EXIT trap and
# would override ours — the EL_OUT temp file would then leak. Apply
# then delete in the same block.
log "Assembling EventListener for git-provider: ${GIT_PROVIDER_PLUGIN}"
EL_OUT=$(mktemp -t outpost-eventlistener.XXXXXX)
if ! assemble_eventlistener \
      "plugins/git-provider/${GIT_PROVIDER_PLUGIN}/trigger.yaml" \
      "core/k8s/05-tekton/eventlistener-base.yaml" \
      "$EL_OUT"; then
  rm -f "$EL_OUT"
  err "EventListener assembly failed"
  exit 1
fi
kubectl apply -f "$EL_OUT"
rm -f "$EL_OUT"
ok "EventListener applied (provider=${GIT_PROVIDER_PLUGIN}, service=el-build-listener)"

# Tekton Dashboard — Web UI for PipelineRuns / TaskRuns / logs.
# release-full.yaml gives read+write (cancel run, delete PR, etc).
# Exposed at tekton.<ROOT_DOMAIN> via Traefik (cloudflared 须在 CF Dashboard
# 手动加 Public Hostname: tekton.<root> → http://host.docker.internal:30080)
log "Installing Tekton Dashboard..."
kubectl apply --server-side=true --force-conflicts \
  -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml
kubectl wait --for=condition=Available --timeout=180s \
  deployment/tekton-dashboard -n tekton-pipelines 2>/dev/null || \
  warn "tekton-dashboard not ready yet — apply continues"

# -----------------------------------------------------------------------------
# Dashboard BasicAuth — Tekton Dashboard + Argo Rollouts UI both ship
# anonymous with write access. Without this, anyone hitting tekton.<root>
# or rollouts.<root> can cancel/delete PipelineRuns or abort/promote
# rollouts. Wrap them in a Traefik BasicAuth middleware shared across both.
#
# Secret is created dynamically (not via render_template) because the
# apr1 hash carries `$apr1$...` chars envsubst would mangle.
# -----------------------------------------------------------------------------
log "Sealing dashboards behind BasicAuth (user=${OUTPOST_DASHBOARD_USER})..."
DASHBOARD_HTPASSWD=$(openssl passwd -apr1 "$OUTPOST_DASHBOARD_PASSWORD")
kubectl -n tekton-pipelines create secret generic dashboard-auth-secret \
  --from-literal=users="${OUTPOST_DASHBOARD_USER}:${DASHBOARD_HTPASSWD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DASHBOARD_HTPASSWD
kubectl apply -f core/k8s/05-tekton/dashboard-auth.yaml

render_apply "core/k8s/05-tekton/dashboard-ingress.yaml"
ok "Tekton Dashboard installed (https://tekton.${ROOT_DOMAIN}) — auth required"

# Bridges
kubectl apply -f core/k8s/06-bridges/
ok "ArgoCD + Tekton + bridges applied"

# Get ArgoCD admin password
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '(not yet ready)')
grep -q '^ARGOCD_ADMIN_PASSWORD=' .env || echo "ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}" >> .env
