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
# GIT_PROVIDER_PLUGIN is a comma-separated list — apply every selected
# provider's manifest. Each contributes a uniquely-named TriggerBinding
# (gitee-/github-/gitlab-push-binding); github additionally contributes its own
# github-webhook-secret Secret. No resource-name collisions across providers,
# so stacking them is safe.
IFS=',' read -ra _gp <<< "${GIT_PROVIDER_PLUGIN}"
for _p in "${_gp[@]}"; do
  _p="${_p// /}"
  [[ -z "$_p" ]] && continue
  log "Applying git-provider plugin: ${_p}"
  render_apply "plugins/git-provider/${_p}/manifest.yaml"
done
unset _gp _p
ok "Git-provider plugin(s) applied: ${GIT_PROVIDER_PLUGIN}"

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

# buildkit build engine (opt-in via BUILD_ENGINE_TASK=buildkit; default kaniko).
# A long-lived privileged buildkitd daemon in its own `enforce=privileged` ns
# (tekton-pipelines is `baseline`, which forbids privileged) owns a persistent
# cache PVC, so RUN --mount=type=cache pnpm stores survive builds (warm ~2-3min
# vs kaniko's ~9min cold-every-build). The `buildkit` Task is a NON-privileged
# buildctl client (passes baseline) that drives the daemon over gRPC. Both are
# applied unconditionally so flipping BUILD_ENGINE_TASK needs no infra
# re-bootstrap; the Task is inert while the pipeline's taskRef stays `kaniko`.
# Applied BEFORE pipeline-build.yaml so the referenced Task exists at apply time.
kubectl apply -f core/k8s/08-buildkit/
kubectl apply -f core/k8s/05-tekton/task-buildkit.yaml
# When buildkit is the active engine, block until the daemon is Ready so a
# webhook that fires right after bootstrap doesn't hit a not-yet-listening
# buildkitd (the build-and-push step would otherwise fail its first connect).
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

# Tekton RBAC + secrets + pipeline + binding/template
kubectl apply -f core/k8s/05-tekton/rbac.yaml
render_apply "core/k8s/05-tekton/secrets.template.yaml"
# Multi-host clone credentials (opt-in). When GIT_CREDENTIALS_EXTRA is set,
# overwrite the single-host git-credentials Secret with one that carries a
# tekton.dev/git-N annotation + .git-credentials line per extra host — required
# to clone PRIVATE app repos living on a host other than MANIFEST_REPO's. The
# secret YAML carries cleartext PATs, so render to a 0600 temp file (never log
# it) and apply from there. Default (empty) leaves the single-host secret above.
if [[ -n "${GIT_CREDENTIALS_EXTRA:-}" ]]; then
  log "Applying multi-host git clone credentials (GIT_CREDENTIALS_EXTRA)..."
  _GC_OUT=$(mktemp)
  chmod 0600 "$_GC_OUT"   # enforce, don't rely on mktemp's default umask
  if ! render_git_credentials_extra > "$_GC_OUT"; then
    rm -f "$_GC_OUT"
    unset _GC_OUT
    err "Failed to render multi-host git-credentials"
    exit 1
  fi
  # SECURITY: $_GC_OUT holds cleartext PATs. Under `set -euo pipefail` a failed
  # apply would exit before a trailing rm — so clean up on the failure path too,
  # never leaving the token file in /tmp.
  if ! kubectl apply -f "$_GC_OUT"; then
    rm -f "$_GC_OUT"
    unset _GC_OUT
    err "kubectl apply for multi-host git-credentials failed"
    exit 1
  fi
  rm -f "$_GC_OUT"
  unset _GC_OUT
  ok "Multi-host git-credentials applied (primary + extras)"
fi
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

# npm-publish stack — LIBRARY repos (fst-foundation) publish @hy/* packages
# to Verdaccio instead of building an image. The github-push-publish trigger
# spliced into the EventListener below routes to publish-template, so these
# three must exist or library pushes 500 at PipelineRun creation.
# task-npm-publish.yaml carries runtime ${REG} inside its step script — full
# render_template would either abort on it or substitute it away, so only
# ${HY_REGISTRY} is allowed to render here.
NPMPUB_TMP=$(mktemp -t outpost-npm-publish.XXXXXX)
if ! render_template_only "core/k8s/05-tekton/task-npm-publish.yaml" "$NPMPUB_TMP" "HY_REGISTRY"; then
  rm -f "$NPMPUB_TMP"
  err "render task-npm-publish.yaml failed"
  exit 1
fi
kubectl apply -f "$NPMPUB_TMP"
rm -f "$NPMPUB_TMP"
render_apply "core/k8s/05-tekton/pipeline-publish.yaml"
kubectl apply -f core/k8s/05-tekton/triggertemplate-publish.yaml
ok "npm-publish stack applied (outpost-npm-publish / publish-npm-packages / publish-template)"

# EventListener — provider-agnostic envelope + active plugin's trigger.yaml.
# Replaces the v0.1 hardcoded Gitee eventlistener.yaml; GIT_PROVIDER_PLUGIN
# now actually selects which provider routes webhooks.
# Inline cleanup (no EXIT trap) because Phase 9 sets its own EXIT trap and
# would override ours — the EL_OUT temp file would then leak. Apply
# then delete in the same block.
log "Assembling EventListener for git-provider(s): ${GIT_PROVIDER_PLUGIN}"
EL_OUT=$(mktemp -t outpost-eventlistener.XXXXXX)
# Collect every selected provider's trigger.yaml; assemble_eventlistener_multi
# stacks them under the single `triggers:` list. Each trigger self-routes by
# its provider-specific header filter, so they coexist without conflict.
_trigger_files=()
IFS=',' read -ra _gp <<< "${GIT_PROVIDER_PLUGIN}"
for _p in "${_gp[@]}"; do
  _p="${_p// /}"
  [[ -z "$_p" ]] && continue
  _trigger_files+=( "plugins/git-provider/${_p}/trigger.yaml" )
done
unset _gp _p
if ! assemble_eventlistener_multi \
      "core/k8s/05-tekton/eventlistener-base.yaml" \
      "$EL_OUT" \
      "${_trigger_files[@]}"; then
  rm -f "$EL_OUT"
  unset _trigger_files
  err "EventListener assembly failed"
  exit 1
fi
unset _trigger_files
kubectl apply -f "$EL_OUT"
rm -f "$EL_OUT"
ok "EventListener applied (provider(s)=${GIT_PROVIDER_PLUGIN}, service=el-build-listener)"

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

# host.docker.internal resolution for k3s + containerd (e.g. WSL).
# The infra-bridges Services are ExternalName → host.docker.internal. Unlike
# Docker Desktop, k3s/containerd does NOT hand that name to pods, so every
# DB/Redis/RMQ lookup is ENOTFOUND and every app pod CrashLoops. Inject a
# CoreDNS custom server block resolving host.docker.internal → the node's
# InternalIP (the host, reachable from pods). k3s CoreDNS imports
# /etc/coredns/custom/*.server from the optional coredns-custom configmap.
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
if [ -n "$NODE_IP" ]; then
  kubectl -n kube-system create configmap coredns-custom \
    --from-literal=hostdockerinternal.server="host.docker.internal:53 {
    hosts {
        ${NODE_IP} host.docker.internal
    }
}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  ok "CoreDNS host.docker.internal → ${NODE_IP} (infra-bridges DB/Redis/RMQ resolvable)"
else
  warn "node InternalIP not found; host.docker.internal will not resolve → app pods CrashLoop"
fi

# Get ArgoCD admin password. Persist to .env ONLY when the initial-admin
# secret actually exists — on a re-bootstrap after the user deleted that
# secret (the documented ArgoCD hardening step), the old code wrote the
# literal placeholder "(not yet ready)" into .env as if it were the password.
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
if [[ -n "${ARGOCD_ADMIN_PASSWORD}" ]]; then
  grep -q '^ARGOCD_ADMIN_PASSWORD=' .env || echo "ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}" >> .env
else
  ARGOCD_ADMIN_PASSWORD='(initial-admin-secret absent — already rotated?)'
  warn "argocd-initial-admin-secret not found; not persisting a placeholder password to .env"
fi
