# shellcheck shell=bash
# =============================================================================
# Phase 2 — Configuration: .env load/prompt, defaults, plugin validation,
#                          .env persist, plugin preflights.
# =============================================================================
phase "Phase 2 / 10 Configuration"

if [[ -f .env ]]; then
  warn ".env already exists — reusing values (mv .env .env.bak to start fresh)"
  set -a; # shellcheck disable=SC1091
  source .env; set +a
else
  cp .env.example .env
fi

# Mode selection (default: local — lowest-friction onboarding).
OUTPOST_MODE="${OUTPOST_MODE:-local}"
case "$OUTPOST_MODE" in
  local|full) ;;
  *) err "OUTPOST_MODE must be 'local' or 'full' (got '$OUTPOST_MODE')"; exit 1 ;;
esac
ok "Mode: $OUTPOST_MODE"

# Required interactive values (skipped if already in .env, skipped entirely in local mode)
prompt_required() {
  local var="$1" desc="$2" val=""
  while [[ -z "${!var:-}" ]]; do
    read -r -p "$desc: " val
    [[ -z "$val" ]] && { warn "Cannot be empty"; continue; }
    printf -v "$var" '%s' "$val"
  done
  export "${var?}"
}

if [[ "$OUTPOST_MODE" == "full" ]]; then
  prompt_required ROOT_DOMAIN       "Root domain (e.g. example.com)"
  prompt_required CF_TUNNEL_TOKEN   "Cloudflare Tunnel Token"
  prompt_required GIT_USER          "Git username (Gitee/GitHub/GitLab)"
  prompt_required GIT_TOKEN         "Git personal access token"
  prompt_required MANIFEST_REPO_URL "Manifest repo HTTPS URL (ends with .git)"
else
  # Local mode: every value gets a usable default. Zero prompts.
  ROOT_DOMAIN="${ROOT_DOMAIN:-outpost.local}"
  CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
  GIT_USER="${GIT_USER:-}"
  GIT_TOKEN="${GIT_TOKEN:-}"
  MANIFEST_REPO_URL="${MANIFEST_REPO_URL:-}"
fi

# Derive GIT_HOST from MANIFEST_REPO_URL (e.g. https://gitee.com/u/r.git → gitee.com).
# Used by Tekton's git credentials Secret + .git-credentials file.
# In local mode we leave it blank — Tekton phase doesn't run.
if [[ -n "${MANIFEST_REPO_URL:-}" ]]; then
  GIT_HOST="$(printf '%s\n' "$MANIFEST_REPO_URL" | awk -F/ '{print $3}')"
  if [[ -z "$GIT_HOST" ]]; then
    err "Could not derive GIT_HOST from MANIFEST_REPO_URL='$MANIFEST_REPO_URL'"
    err "Expected an HTTPS URL like https://gitee.com/<user>/<repo>.git"
    exit 1
  fi
else
  GIT_HOST=""
fi
export GIT_HOST

# Defaults shared by both modes
REGISTRY_PLUGIN="${REGISTRY_PLUGIN:-self-hosted}"
GIT_PROVIDER_PLUGIN="${GIT_PROVIDER_PLUGIN:-gitee}"
MANIFEST_REPO_BRANCH="${MANIFEST_REPO_BRANCH:-main}"

# Built-in service subdomain prefixes (joined with .${ROOT_DOMAIN}).
# Templates under core/k8s/ reference these via envsubst; render_template's
# strict residue check requires every ${VAR} placeholder in a template to
# be set in the environment, so these defaults guarantee no silent failure
# even when the operator left .env at its commented defaults.
ARGOCD_HOST="${ARGOCD_HOST:-argocd}"
HOOKS_HOST="${HOOKS_HOST:-hooks}"
# REGISTRY_SUBDOMAIN feeds registry-config.sh's REGISTRY_HOST computation for
# the self-hosted plugin only. aliyun-acr sets REGISTRY_HOST directly to the
# ACR endpoint and ignores this var.
REGISTRY_SUBDOMAIN="${REGISTRY_SUBDOMAIN:-registry}"
# Branch of an APP repo whose pushes trigger the CI/CD pipeline. The EventListener
# CEL ref filter pins to refs/heads/${OUTPOST_DEPLOY_BRANCH}; pushes to any other
# branch are ignored. Distinct from MANIFEST_REPO_BRANCH (the manifests repo).
OUTPOST_DEPLOY_BRANCH="${OUTPOST_DEPLOY_BRANCH:-main}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
RABBITMQ_USER="${RABBITMQ_USER:-admin}"

# Phase 9 plugin defaults (full mode only — but read in both so .env is consistent)
TEST_RUNNER="${TEST_RUNNER:-testkube}"
TESTKUBE_MODE="${TESTKUBE_MODE:-oss}"
ROLLOUT_PLUGIN="${ROLLOUT_PLUGIN:-argo-rollouts}"
ROLLOUTS_DASHBOARD_HOST="${ROLLOUTS_DASHBOARD_HOST:-rollouts.${ROOT_DOMAIN}}"
NOTIFICATION_PROVIDERS="${NOTIFICATION_PROVIDERS:-}"

# Tekton PipelineRun auto-pruner (CronJob in tekton-pipelines ns).
# Without these defaults Tekton never GCs finished PipelineRuns; their
# kaniko build pods accumulate ~1 GB ephemeral-storage each and after
# ~50 builds the node hits DiskPressure → mid-build Evicted. See
# core/k8s/05-tekton/pruner.yaml for full rationale + RBAC scope.
OUTPOST_TEKTON_RETENTION_HOURS="${OUTPOST_TEKTON_RETENTION_HOURS:-24}"
OUTPOST_TEKTON_PRUNE_SCHEDULE="${OUTPOST_TEKTON_PRUNE_SCHEDULE:-0 * * * *}"
OUTPOST_TEKTON_PRUNER_IMAGE="${OUTPOST_TEKTON_PRUNER_IMAGE:-bitnami/kubectl:1.31}"
DINGTALK_WEBHOOK_URL="${DINGTALK_WEBHOOK_URL:-}"
DINGTALK_SIGN_SECRET="${DINGTALK_SIGN_SECRET:-}"
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
FEISHU_SIGN_SECRET="${FEISHU_SIGN_SECRET:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_URL="${GENERIC_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_BEARER="${GENERIC_WEBHOOK_BEARER:-}"
TESTKUBE_CLOUD_API_KEY="${TESTKUBE_CLOUD_API_KEY:-}"

# Auto-generate any blank passwords (both modes)
[[ -z "${POSTGRES_PASSWORD:-}" ]]      && POSTGRES_PASSWORD=$(gen_password)
[[ -z "${REDIS_PASSWORD:-}" ]]         && REDIS_PASSWORD=$(gen_password)
[[ -z "${RABBITMQ_PASSWORD:-}" ]]      && RABBITMQ_PASSWORD=$(gen_password)
[[ -z "${GIT_WEBHOOK_SECRET:-}" ]]     && GIT_WEBHOOK_SECRET=$(gen_password)
# Independent from GIT_WEBHOOK_SECRET (which Tekton uses for app-repo pushes).
# Manifest-repo webhook hits argocd-server /api/webhook — different secret
# = different blast radius if either leaks.
[[ -z "${ARGOCD_WEBHOOK_SECRET:-}" ]]  && ARGOCD_WEBHOOK_SECRET=$(gen_password)
# Dashboard BasicAuth — protects Tekton Dashboard + Argo Rollouts UI.
# Both ship without built-in auth and grant write access (cancel/delete
# PipelineRuns, abort/promote rollouts). Auto-generated in full mode.
[[ -z "${OUTPOST_DASHBOARD_USER:-}" ]]     && OUTPOST_DASHBOARD_USER="outpost"
[[ -z "${OUTPOST_DASHBOARD_PASSWORD:-}" ]] && OUTPOST_DASHBOARD_PASSWORD=$(gen_password)

# Plugin selection only matters in full mode (existence check is cheap, do it first)
if [[ "$OUTPOST_MODE" == "full" ]]; then
  if [[ ! -d "plugins/registry/${REGISTRY_PLUGIN}" ]]; then
    err "Unknown REGISTRY_PLUGIN: ${REGISTRY_PLUGIN}"
    err "Available: $(ls plugins/registry)"
    exit 1
  fi
  if [[ ! -d "plugins/git-provider/${GIT_PROVIDER_PLUGIN}" ]]; then
    err "Unknown GIT_PROVIDER_PLUGIN: ${GIT_PROVIDER_PLUGIN}"
    err "Available: $(ls plugins/git-provider)"
    exit 1
  fi

  # Resolve registry-plugin-aware Pipeline params + webhook repo whitelist.
  # All actual logic lives in platform/lib/{registry-config,cel-helpers}.sh
  # so it has bats coverage. bootstrap.sh just orchestrates.
  resolve_registry_config || exit 1
  build_cel_whitelist

  if [[ ! -d "plugins/test-runner/${TEST_RUNNER}" ]]; then
    err "Unknown TEST_RUNNER: ${TEST_RUNNER}"
    err "Available: $(ls plugins/test-runner)"
    exit 1
  fi
  if [[ ! -d "plugins/rollout/${ROLLOUT_PLUGIN}" ]]; then
    err "Unknown ROLLOUT_PLUGIN: ${ROLLOUT_PLUGIN}"
    err "Available: $(ls plugins/rollout)"
    exit 1
  fi
  # Validate each enabled notification plugin exists.
  if [[ -n "${NOTIFICATION_PROVIDERS}" ]]; then
    IFS=',' read -ra _np <<< "${NOTIFICATION_PROVIDERS}"
    for _p in "${_np[@]}"; do
      _p="${_p// /}"
      [[ -z "$_p" ]] && continue
      if [[ ! -d "plugins/notification/${_p}" ]]; then
        err "Unknown NOTIFICATION_PROVIDER '$_p'"
        err "Available: $(ls plugins/notification)"
        exit 1
      fi
    done
    unset _np _p
  fi
  ok "Plugins: registry=${REGISTRY_PLUGIN} git=${GIT_PROVIDER_PLUGIN} test-runner=${TEST_RUNNER} rollout=${ROLLOUT_PLUGIN}"
  if [[ -n "${NOTIFICATION_PROVIDERS}" ]]; then
    ok "Notifications: ${NOTIFICATION_PROVIDERS}"
  else
    warn "Notifications: none (set NOTIFICATION_PROVIDERS to enable)"
  fi
fi

# Persist .env (canonical form). MUST happen before plugin preflight runs:
# the preflight subshell does `source .env`, so any auto-generated value
# (e.g. GIT_WEBHOOK_SECRET) needs to be on disk first or the subshell sees
# the stale empty value.
{
  echo "OUTPOST_MODE=${OUTPOST_MODE}"
  echo "ROOT_DOMAIN=${ROOT_DOMAIN}"
  echo "CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}"
  echo "REGISTRY_PLUGIN=${REGISTRY_PLUGIN}"
  echo "GIT_PROVIDER_PLUGIN=${GIT_PROVIDER_PLUGIN}"
  echo "POSTGRES_USER=${POSTGRES_USER}"
  echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
  echo "POSTGRES_DB=${POSTGRES_DB}"
  echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
  echo "RABBITMQ_USER=${RABBITMQ_USER}"
  echo "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"
  echo "GIT_USER=${GIT_USER}"
  echo "GIT_TOKEN=${GIT_TOKEN}"
  echo "GIT_WEBHOOK_SECRET=${GIT_WEBHOOK_SECRET}"
  echo "ARGOCD_WEBHOOK_SECRET=${ARGOCD_WEBHOOK_SECRET}"
  echo "OUTPOST_DASHBOARD_USER=${OUTPOST_DASHBOARD_USER}"
  echo "OUTPOST_DASHBOARD_PASSWORD=${OUTPOST_DASHBOARD_PASSWORD}"
  echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
  echo "MANIFEST_REPO_BRANCH=${MANIFEST_REPO_BRANCH}"
  echo "OUTPOST_DEPLOY_BRANCH=${OUTPOST_DEPLOY_BRANCH}"
  echo "GIT_HOST=${GIT_HOST}"
  # Registry-plugin-derived Pipeline defaults (re-derived on each bootstrap,
  # but persisted so status.sh / verify.sh can show what's active).
  echo "REGISTRY_HOST=${REGISTRY_HOST:-}"
  echo "REGISTRY_PUSH_HOST=${REGISTRY_PUSH_HOST:-}"
  # Built-in service subdomain prefix overrides (joined with .${ROOT_DOMAIN} by
  # the relevant template/computation). Persisted so subsequent rebuilds, the
  # registry plugin's REGISTRY_HOST computation, and verify.sh all agree.
  echo "ARGOCD_HOST=${ARGOCD_HOST}"
  echo "HOOKS_HOST=${HOOKS_HOST}"
  echo "REGISTRY_SUBDOMAIN=${REGISTRY_SUBDOMAIN}"
  echo "KANIKO_EXTRA_ARGS=${KANIKO_EXTRA_ARGS:-}"
  echo "WEBHOOK_REPO_WHITELIST=${WEBHOOK_REPO_WHITELIST:-}"
  echo "CEL_WHITELIST_LIST=${CEL_WHITELIST_LIST:-[]}"
  # ACR specifics carried through if set
  [[ -n "${ALIYUN_ACR_REGISTRY:-}" ]]  && echo "ALIYUN_ACR_REGISTRY=${ALIYUN_ACR_REGISTRY}"
  [[ -n "${ALIYUN_ACR_NAMESPACE:-}" ]] && echo "ALIYUN_ACR_NAMESPACE=${ALIYUN_ACR_NAMESPACE}"
  [[ -n "${ALIYUN_ACR_USER:-}" ]]      && echo "ALIYUN_ACR_USER=${ALIYUN_ACR_USER}"
  [[ -n "${ALIYUN_ACR_PASSWORD:-}" ]]  && echo "ALIYUN_ACR_PASSWORD=${ALIYUN_ACR_PASSWORD}"
  # Phase 9 (test gate + auto-rollback + notifications)
  echo "TEST_RUNNER=${TEST_RUNNER}"
  echo "TESTKUBE_MODE=${TESTKUBE_MODE}"
  [[ -n "${TESTKUBE_CLOUD_API_KEY:-}" ]] && echo "TESTKUBE_CLOUD_API_KEY=${TESTKUBE_CLOUD_API_KEY}"
  echo "ROLLOUT_PLUGIN=${ROLLOUT_PLUGIN}"
  echo "ROLLOUTS_DASHBOARD_HOST=${ROLLOUTS_DASHBOARD_HOST}"
  echo "NOTIFICATION_PROVIDERS=${NOTIFICATION_PROVIDERS}"
  echo "OUTPOST_TEKTON_RETENTION_HOURS=${OUTPOST_TEKTON_RETENTION_HOURS}"
  echo "OUTPOST_TEKTON_PRUNE_SCHEDULE=\"${OUTPOST_TEKTON_PRUNE_SCHEDULE}\""
  echo "OUTPOST_TEKTON_PRUNER_IMAGE=${OUTPOST_TEKTON_PRUNER_IMAGE}"
  [[ -n "${DINGTALK_WEBHOOK_URL:-}" ]]   && echo "DINGTALK_WEBHOOK_URL=${DINGTALK_WEBHOOK_URL}"
  [[ -n "${DINGTALK_SIGN_SECRET:-}" ]]   && echo "DINGTALK_SIGN_SECRET=${DINGTALK_SIGN_SECRET}"
  [[ -n "${FEISHU_WEBHOOK_URL:-}" ]]     && echo "FEISHU_WEBHOOK_URL=${FEISHU_WEBHOOK_URL}"
  [[ -n "${FEISHU_SIGN_SECRET:-}" ]]     && echo "FEISHU_SIGN_SECRET=${FEISHU_SIGN_SECRET}"
  [[ -n "${WECOM_WEBHOOK_URL:-}" ]]      && echo "WECOM_WEBHOOK_URL=${WECOM_WEBHOOK_URL}"
  [[ -n "${GENERIC_WEBHOOK_URL:-}" ]]    && echo "GENERIC_WEBHOOK_URL=${GENERIC_WEBHOOK_URL}"
  [[ -n "${GENERIC_WEBHOOK_BEARER:-}" ]] && echo "GENERIC_WEBHOOK_BEARER=${GENERIC_WEBHOOK_BEARER}"
} > .env
chmod 600 .env

# Re-export for envsubst (and for the preflight subshell below)
set -a; # shellcheck disable=SC1091
source .env; set +a
ok ".env written (perm 600)"

# Now that .env is canonical, run plugin preflight checks
if [[ "$OUTPOST_MODE" == "full" ]]; then
  log "Running plugin preflight checks..."
  ( set -a; source .env; set +a; bash "plugins/registry/${REGISTRY_PLUGIN}/preflight.sh" )
  ( set -a; source .env; set +a; bash "plugins/git-provider/${GIT_PROVIDER_PLUGIN}/preflight.sh" )
  ( set -a; source .env; set +a; bash "plugins/test-runner/${TEST_RUNNER}/preflight.sh" )
  ( set -a; source .env; set +a; bash "plugins/rollout/${ROLLOUT_PLUGIN}/preflight.sh" )
  if [[ -n "${NOTIFICATION_PROVIDERS}" ]]; then
    IFS=',' read -ra _np <<< "${NOTIFICATION_PROVIDERS}"
    for _p in "${_np[@]}"; do
      _p="${_p// /}"
      [[ -z "$_p" ]] && continue
      ( set -a; source .env; set +a; bash "plugins/notification/${_p}/preflight.sh" )
    done
    unset _np _p
  fi
  ok "Plugin preflights passed"
fi
