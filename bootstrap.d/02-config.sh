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
  # OUTPOST_REPOS is required in full mode: it is the reconciliation basis
  # (verify.sh's "ultimate judge") AND the git-provider preflight probe list.
  # An empty registry would make the anti-silence layer blind — the exact
  # self-deception v0.3 exists to kill.
  prompt_required OUTPOST_REPOS     "App repos, comma list of <clone-url>[#branch]"
else
  # Local mode: every value gets a usable default. Zero prompts.
  ROOT_DOMAIN="${ROOT_DOMAIN:-outpost.local}"
  CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
  GIT_USER="${GIT_USER:-}"
  GIT_TOKEN="${GIT_TOKEN:-}"
  MANIFEST_REPO_URL="${MANIFEST_REPO_URL:-}"
  OUTPOST_REPOS="${OUTPOST_REPOS:-}"
fi

# OUTPOST_REPOS entry shape: "<url>[#<branch>]" where url is https://… or
# git@…, branch optional (empty → OUTPOST_DEPLOY_BRANCH at consume time).
# Validated in BOTH modes (a malformed entry in local mode would still bite
# on the eventual full-mode upgrade). Fail loud now, not at reconcile time.
IFS=',' read -ra _repos <<< "${OUTPOST_REPOS:-}"
for _r in "${_repos[@]:-}"; do
  _r="${_r// /}"
  [[ -z "$_r" ]] && continue
  if ! [[ "$_r" =~ ^(https://[^#[:space:]]+|git@[^#[:space:]]+)(#[A-Za-z0-9._/-]+)?$ ]]; then
    err "OUTPOST_REPOS entry malformed: '$_r'"
    err "Expected '<https-or-ssh-clone-url>[#branch]', e.g. https://gitee.com/org/svc.git#release"
    exit 1
  fi
done
unset _repos _r

# Derive GIT_HOST from MANIFEST_REPO_URL (e.g. https://gitee.com/u/r.git → gitee.com).
# Used by verify.sh's reconciliation credential lookup and the manifest-sync /
# update-manifest env-shaped credential fallback (GIT_USER/GIT_TOKEN@GIT_HOST).
# In local mode we leave it blank — no CI/CD phases run.
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
# Derived (not persisted): buildkit push transport, consumed by
# scripts/ci/build-image.sh (buildctl push flags). The in-cluster self-hosted
# registry is plain HTTP; aliyun-acr is HTTPS-only and refuses plain HTTP
# outright. Overridable for exotic setups.
case "$REGISTRY_PLUGIN" in
  aliyun-acr) REGISTRY_INSECURE="${REGISTRY_INSECURE:-false}" ;;
  *)          REGISTRY_INSECURE="${REGISTRY_INSECURE:-true}"  ;;
esac
GIT_PROVIDER_PLUGIN="${GIT_PROVIDER_PLUGIN:-gitee}"
# Build engine gate (v0.3):
#   buildkit — DEFAULT and the only supported engine. The buildkitd daemon
#              (core/k8s/08-buildkit) with a persistent RUN --mount=type=cache
#              pnpm store; the CLIENT is scripts/ci/build-image.sh (buildctl
#              over the 30750 NodePort, run by the GitHub Actions runner).
#              Phase 8 blocks on the daemon being Ready when this is set.
#   kaniko   — DEPRECATED. The Tekton kaniko Task was removed with the Tekton
#              engine; this value now only skips the buildkitd readiness gate
#              (nothing installs or runs kaniko anymore). Kept as a recognized
#              value so old .env files don't hard-fail — but builds require
#              buildkit.
BUILD_ENGINE_TASK="${BUILD_ENGINE_TASK:-buildkit}"
# Optional extra clone credentials for private app repos on hosts OTHER than
# MANIFEST_REPO_URL's. Comma-separated `host|user|token`; empty = single-host.
# Consumed by the git-provider preflight probes (Phase 2) and verify.sh's
# reconciliation ls-remote (per-host credential lookup).
GIT_CREDENTIALS_EXTRA="${GIT_CREDENTIALS_EXTRA:-}"
MANIFEST_REPO_BRANCH="${MANIFEST_REPO_BRANCH:-main}"

# Built-in service subdomain prefixes (joined with .${ROOT_DOMAIN}).
# Templates under core/k8s/ reference these via envsubst; render_template's
# strict residue check requires every ${VAR} placeholder in a template to
# be set in the environment, so these defaults guarantee no silent failure
# even when the operator left .env at its commented defaults.
# (v0.3 removed ARGOCD_HOST / HOOKS_HOST — no ArgoCD UI, no inbound webhook
# receiver. Only the registry prefix remains a bootstrap-time input.)
# REGISTRY_SUBDOMAIN feeds registry-config.sh's REGISTRY_HOST computation for
# the self-hosted plugin only. aliyun-acr sets REGISTRY_HOST directly to the
# ACR endpoint and ignores this var.
REGISTRY_SUBDOMAIN="${REGISTRY_SUBDOMAIN:-registry}"
# Branch of an APP repo whose pushes trigger the CI workflow. The workflow
# template's `on: push: branches:` pins this; an OUTPOST_REPOS entry without
# an explicit #branch also reconciles against it. Distinct from
# MANIFEST_REPO_BRANCH (the manifests repo the sync job watches).
OUTPOST_DEPLOY_BRANCH="${OUTPOST_DEPLOY_BRANCH:-main}"

# ---- GitHub Actions runner + manifest-sync + reconciliation (v0.3) ----------
GITHUB_RUNNER_URL="${GITHUB_RUNNER_URL:-}"
GITHUB_RUNNER_PAT="${GITHUB_RUNNER_PAT:-}"
GITHUB_RUNNER_LABELS="${GITHUB_RUNNER_LABELS:-outpost}"
GITHUB_RUNNER_NAME="${GITHUB_RUNNER_NAME:-}"   # empty → outpost-<hostname> at install
# When a PAT is present the URL must be a github.com org or single-repo URL —
# anything else would fail deep inside Phase 8's token mint with an opaque
# API error. PAT empty = runner install skipped (loud WARN in Phase 8).
if [[ -n "$GITHUB_RUNNER_PAT" ]]; then
  if ! [[ "$GITHUB_RUNNER_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?/?$ ]]; then
    err "GITHUB_RUNNER_URL must be https://github.com/<org> or https://github.com/<owner>/<repo>"
    err "(got '${GITHUB_RUNNER_URL}') — required because GITHUB_RUNNER_PAT is set"
    exit 1
  fi
fi
# Minutes between manifest-sync CronJob runs. Must be a cron-safe integer
# (schedule renders as */N in the minute field).
MANIFEST_SYNC_INTERVAL="${MANIFEST_SYNC_INTERVAL:-2}"
if ! [[ "$MANIFEST_SYNC_INTERVAL" =~ ^[0-9]+$ ]] \
   || [[ "$MANIFEST_SYNC_INTERVAL" -lt 1 || "$MANIFEST_SYNC_INTERVAL" -gt 59 ]]; then
  err "MANIFEST_SYNC_INTERVAL must be an integer 1-59 (minutes), got '${MANIFEST_SYNC_INTERVAL}'"
  exit 1
fi
# Seconds a live-HEAD/deployed-tag mismatch may persist before verify.sh's
# reconciliation reports FAIL (naming the repo).
OUTPOST_STALENESS_THRESHOLD="${OUTPOST_STALENESS_THRESHOLD:-1800}"
if ! [[ "$OUTPOST_STALENESS_THRESHOLD" =~ ^[0-9]+$ ]]; then
  err "OUTPOST_STALENESS_THRESHOLD must be an integer (seconds), got '${OUTPOST_STALENESS_THRESHOLD}'"
  exit 1
fi
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
RABBITMQ_USER="${RABBITMQ_USER:-admin}"

# Phase 9 plugin defaults (full mode only — but read in both so .env is consistent)
TEST_RUNNER="${TEST_RUNNER:-testkube}"
# skip (default) | oss | cloud. Nothing in the MVP pipeline talks to the
# Testkube product — the run-tests Task evals outpost.test.yaml inline — and
# the oss helm install must reach us-east1-docker.pkg.dev (GAR), which times
# out from CN and wasted ~5min per bootstrap. Set oss/cloud when Phase 2
# actually adopts Testkube TestWorkflows.
TESTKUBE_MODE="${TESTKUBE_MODE:-skip}"
# Rollout plugin: default `none` in v0.3 (canary is opt-in, controller-only —
# apps adopt the Rollout CRD themselves; manifest-sync is Rollout-kind aware).
ROLLOUT_PLUGIN="${ROLLOUT_PLUGIN:-none}"
NOTIFICATION_PROVIDERS="${NOTIFICATION_PROVIDERS:-}"

# Apps namespace ResourceQuota + LimitRange — dynamic per host capacity.
# Pure auto-detect from sysctl (macOS) or /proc/meminfo + nproc (Linux);
# values can be pinned by setting OUTPOST_APPS_* in .env BEFORE bootstrap.
# Formula in platform/lib/host-capacity.sh; mathematically:
#   8GB / 4-CPU laptop   → quota.limits.cpu=8,  limits.memory=3Gi
#   32GB / 8-CPU desktop → quota.limits.cpu=16, limits.memory=12Gi
#   64GB / 16-CPU rig    → quota.limits.cpu=32, limits.memory=30Gi
# CPU overcommits cleanly in K8s → limits.cpu is intentionally 2× host vCPU.
# Memory does NOT overcommit safely → limits.memory is sized from what's LEFT
# after reserving half the host (capped at 24Gi) for buildkitd, not from the
# raw host total — see platform/lib/host-capacity.sh for the full formula.
# apps_quota_defaults emits five space-separated integers on a single line.
# read -r -a does word-splitting without shellcheck's SC2207 warning that
# bare `array=( $(...) )` would trip.
read -r -a _apps_q <<< "$(apps_quota_defaults)"
OUTPOST_APPS_PODS_MAX="${OUTPOST_APPS_PODS_MAX:-${_apps_q[0]}}"
OUTPOST_APPS_REQUESTS_CPU="${OUTPOST_APPS_REQUESTS_CPU:-${_apps_q[1]}}"
OUTPOST_APPS_LIMITS_CPU="${OUTPOST_APPS_LIMITS_CPU:-${_apps_q[2]}}"
OUTPOST_APPS_REQUESTS_MEMORY="${OUTPOST_APPS_REQUESTS_MEMORY:-${_apps_q[3]}Gi}"
OUTPOST_APPS_LIMITS_MEMORY="${OUTPOST_APPS_LIMITS_MEMORY:-${_apps_q[4]}Gi}"
unset _apps_q
# LimitRange defaults — host-independent (describes what a "small dev service"
# looks like, not what the host can fit). Overridable for unusual app profiles.
OUTPOST_APPS_DEFAULT_REQUEST_CPU="${OUTPOST_APPS_DEFAULT_REQUEST_CPU:-50m}"
OUTPOST_APPS_DEFAULT_REQUEST_MEMORY="${OUTPOST_APPS_DEFAULT_REQUEST_MEMORY:-64Mi}"
OUTPOST_APPS_DEFAULT_LIMIT_CPU="${OUTPOST_APPS_DEFAULT_LIMIT_CPU:-500m}"
OUTPOST_APPS_DEFAULT_LIMIT_MEMORY="${OUTPOST_APPS_DEFAULT_LIMIT_MEMORY:-512Mi}"
OUTPOST_APPS_MAX_CPU="${OUTPOST_APPS_MAX_CPU:-4}"
OUTPOST_APPS_MAX_MEMORY="${OUTPOST_APPS_MAX_MEMORY:-8Gi}"

# Registry GC — periodic tag prune + blob garbage-collect for self-hosted
# registry plugin only. The docker-registry has no built-in GC; without
# this CronJob, every CI push leaks blobs forever and the 50Gi PVC fills.
# Schedule defaults to every 6h.
# Tag retention = rollback depth (`outpost rollback` can only reach kept
# tags). v0.3 default bumped 5 → 10: OUTPOST_REGISTRY_KEEP_TAGS is the
# documented .env knob; OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO is the legacy
# name gc.yaml + registry-gc.sh still consume, kept as an alias (explicit
# legacy value wins for old .env files, then the new knob, then 10).
OUTPOST_REGISTRY_GC_SCHEDULE="${OUTPOST_REGISTRY_GC_SCHEDULE:-0 */6 * * *}"
OUTPOST_REGISTRY_KEEP_TAGS="${OUTPOST_REGISTRY_KEEP_TAGS:-10}"
OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO="${OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO:-${OUTPOST_REGISTRY_KEEP_TAGS}}"
DINGTALK_WEBHOOK_URL="${DINGTALK_WEBHOOK_URL:-}"
DINGTALK_SIGN_SECRET="${DINGTALK_SIGN_SECRET:-}"
FEISHU_WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
FEISHU_SIGN_SECRET="${FEISHU_SIGN_SECRET:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_URL="${GENERIC_WEBHOOK_URL:-}"
GENERIC_WEBHOOK_BEARER="${GENERIC_WEBHOOK_BEARER:-}"
TESTKUBE_CLOUD_API_KEY="${TESTKUBE_CLOUD_API_KEY:-}"

# Auto-generate any blank passwords (both modes).
# v0.3 removed GIT_WEBHOOK_SECRET / ARGOCD_WEBHOOK_SECRET (no inbound webhook
# path exists) and OUTPOST_DASHBOARD_USER/PASSWORD (no dashboards to seal).
[[ -z "${POSTGRES_PASSWORD:-}" ]]      && POSTGRES_PASSWORD=$(gen_password)
[[ -z "${REDIS_PASSWORD:-}" ]]         && REDIS_PASSWORD=$(gen_password)
[[ -z "${RABBITMQ_PASSWORD:-}" ]]      && RABBITMQ_PASSWORD=$(gen_password)

# Plugin selection only matters in full mode (existence check is cheap, do it first)
if [[ "$OUTPOST_MODE" == "full" ]]; then
  if [[ ! -d "plugins/registry/${REGISTRY_PLUGIN}" ]]; then
    err "Unknown REGISTRY_PLUGIN: ${REGISTRY_PLUGIN}"
    err "Available: $(ls plugins/registry)"
    exit 1
  fi
  # GIT_PROVIDER_PLUGIN accepts a comma-separated list (mirror of
  # NOTIFICATION_PROVIDERS). Each selected provider's preflight runs an
  # authenticated ls-remote against its OUTPOST_REPOS hosts (credentials +
  # host-matching contract — the webhook-receiver role is gone in v0.3).
  # Validate each entry exists.
  IFS=',' read -ra _gp <<< "${GIT_PROVIDER_PLUGIN}"
  _found=0
  for _p in "${_gp[@]}"; do
    _p="${_p// /}"
    [[ -z "$_p" ]] && continue
    if [[ ! -d "plugins/git-provider/${_p}" ]]; then
      err "Unknown GIT_PROVIDER_PLUGIN entry '$_p'"
      err "Available: $(ls plugins/git-provider)"
      exit 1
    fi
    _found=$((_found + 1))
  done
  # git-provider is NOT optional — an empty or all-blank list (,,) would only
  # fail late in a preflight with an opaque error. Fail loud now.
  if [[ "$_found" -eq 0 ]]; then
    err "GIT_PROVIDER_PLUGIN must list at least one provider (got '${GIT_PROVIDER_PLUGIN}')"
    err "Available: $(ls plugins/git-provider)"
    exit 1
  fi
  unset _gp _p _found

  # Resolve registry-plugin-aware push/pull hosts (REGISTRY_HOST /
  # REGISTRY_PUSH_HOST). Logic lives in platform/lib/registry-config.sh so it
  # has bats coverage. (v0.3: the CEL webhook whitelist builder is gone with
  # the EventListener.)
  resolve_registry_config || exit 1

  if [[ ! -d "plugins/test-runner/${TEST_RUNNER}" ]]; then
    err "Unknown TEST_RUNNER: ${TEST_RUNNER}"
    err "Available: $(ls plugins/test-runner)"
    exit 1
  fi
  # ROLLOUT_PLUGIN=none is a first-class value (v0.3 default) — only validate
  # a plugin dir when one is actually selected.
  if [[ "${ROLLOUT_PLUGIN}" != "none" && ! -d "plugins/rollout/${ROLLOUT_PLUGIN}" ]]; then
    err "Unknown ROLLOUT_PLUGIN: ${ROLLOUT_PLUGIN}"
    err "Available: none $(ls plugins/rollout)"
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
# (e.g. POSTGRES_PASSWORD) needs to be on disk first or the subshell sees
# the stale empty value.
{
  echo "OUTPOST_MODE=${OUTPOST_MODE}"
  echo "ROOT_DOMAIN=${ROOT_DOMAIN}"
  echo "CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}"
  echo "REGISTRY_PLUGIN=${REGISTRY_PLUGIN}"
  echo "BUILD_ENGINE_TASK=${BUILD_ENGINE_TASK}"
  echo "GIT_PROVIDER_PLUGIN=${GIT_PROVIDER_PLUGIN}"
  echo "POSTGRES_USER=${POSTGRES_USER}"
  echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
  echo "POSTGRES_DB=${POSTGRES_DB}"
  echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
  echo "RABBITMQ_USER=${RABBITMQ_USER}"
  echo "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}"
  echo "GIT_USER=${GIT_USER}"
  echo "GIT_TOKEN=${GIT_TOKEN}"
  # Contains `|` and `,` field/entry separators (and a PAT) — env_kv printf %q
  # so it round-trips through `source .env` intact.
  env_kv GIT_CREDENTIALS_EXTRA "${GIT_CREDENTIALS_EXTRA:-}"
  echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
  echo "MANIFEST_REPO_BRANCH=${MANIFEST_REPO_BRANCH}"
  echo "OUTPOST_DEPLOY_BRANCH=${OUTPOST_DEPLOY_BRANCH}"
  echo "GIT_HOST=${GIT_HOST}"
  # v0.3 CI/CD engine — app-repo registry + runner + sync + reconciliation.
  # OUTPOST_REPOS carries `#` and `,`; the PAT is a secret with arbitrary
  # chars — env_kv both so `source .env` round-trips safely.
  env_kv OUTPOST_REPOS "${OUTPOST_REPOS:-}"
  echo "GITHUB_RUNNER_URL=${GITHUB_RUNNER_URL}"
  env_kv GITHUB_RUNNER_PAT "${GITHUB_RUNNER_PAT:-}"
  echo "GITHUB_RUNNER_LABELS=${GITHUB_RUNNER_LABELS}"
  echo "GITHUB_RUNNER_NAME=${GITHUB_RUNNER_NAME}"
  echo "MANIFEST_SYNC_INTERVAL=${MANIFEST_SYNC_INTERVAL}"
  echo "OUTPOST_STALENESS_THRESHOLD=${OUTPOST_STALENESS_THRESHOLD}"
  # Registry-plugin-derived Pipeline defaults (re-derived on each bootstrap,
  # but persisted so status.sh / verify.sh can show what's active).
  echo "REGISTRY_HOST=${REGISTRY_HOST:-}"
  echo "REGISTRY_PUSH_HOST=${REGISTRY_PUSH_HOST:-}"
  # Built-in service subdomain prefix overrides (joined with .${ROOT_DOMAIN} by
  # the relevant template/computation). Persisted so subsequent rebuilds, the
  # registry plugin's REGISTRY_HOST computation, and verify.sh all agree.
  echo "REGISTRY_SUBDOMAIN=${REGISTRY_SUBDOMAIN}"
  # Values that may contain shell metacharacters (spaces, &, =, [, ", etc).
  # env_kv runs printf '%q' so round-trip through `source` is safe. See
  # platform/lib/portable.sh for the why + concrete failure modes.
  # (KANIKO_EXTRA_ARGS name kept: read-build-config.sh's merged extra-args
  # contract still consumes it, even though kaniko itself is retired.)
  env_kv KANIKO_EXTRA_ARGS       "${KANIKO_EXTRA_ARGS:-}"
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
  echo "NOTIFICATION_PROVIDERS=${NOTIFICATION_PROVIDERS}"
  # Apps ns ResourceQuota — dynamic-per-host, but persisted so subsequent
  # bootstraps + status.sh + verify.sh agree on what's installed.
  echo "OUTPOST_APPS_PODS_MAX=${OUTPOST_APPS_PODS_MAX}"
  echo "OUTPOST_APPS_REQUESTS_CPU=${OUTPOST_APPS_REQUESTS_CPU}"
  echo "OUTPOST_APPS_LIMITS_CPU=${OUTPOST_APPS_LIMITS_CPU}"
  echo "OUTPOST_APPS_REQUESTS_MEMORY=${OUTPOST_APPS_REQUESTS_MEMORY}"
  echo "OUTPOST_APPS_LIMITS_MEMORY=${OUTPOST_APPS_LIMITS_MEMORY}"
  echo "OUTPOST_APPS_DEFAULT_REQUEST_CPU=${OUTPOST_APPS_DEFAULT_REQUEST_CPU}"
  echo "OUTPOST_APPS_DEFAULT_REQUEST_MEMORY=${OUTPOST_APPS_DEFAULT_REQUEST_MEMORY}"
  echo "OUTPOST_APPS_DEFAULT_LIMIT_CPU=${OUTPOST_APPS_DEFAULT_LIMIT_CPU}"
  echo "OUTPOST_APPS_DEFAULT_LIMIT_MEMORY=${OUTPOST_APPS_DEFAULT_LIMIT_MEMORY}"
  echo "OUTPOST_APPS_MAX_CPU=${OUTPOST_APPS_MAX_CPU}"
  echo "OUTPOST_APPS_MAX_MEMORY=${OUTPOST_APPS_MAX_MEMORY}"
  env_kv OUTPOST_REGISTRY_GC_SCHEDULE "${OUTPOST_REGISTRY_GC_SCHEDULE}"
  echo "OUTPOST_REGISTRY_KEEP_TAGS=${OUTPOST_REGISTRY_KEEP_TAGS}"
  echo "OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO=${OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO}"
  # Webhook URLs commonly contain `&` (e.g. ?access_token=x&sign=y) — unquoted
  # those would re-source as two commands. env_kv guards every URL field.
  [[ -n "${DINGTALK_WEBHOOK_URL:-}" ]]   && env_kv DINGTALK_WEBHOOK_URL   "${DINGTALK_WEBHOOK_URL}"
  [[ -n "${DINGTALK_SIGN_SECRET:-}" ]]   && env_kv DINGTALK_SIGN_SECRET   "${DINGTALK_SIGN_SECRET}"
  [[ -n "${FEISHU_WEBHOOK_URL:-}" ]]     && env_kv FEISHU_WEBHOOK_URL     "${FEISHU_WEBHOOK_URL}"
  [[ -n "${FEISHU_SIGN_SECRET:-}" ]]     && env_kv FEISHU_SIGN_SECRET     "${FEISHU_SIGN_SECRET}"
  [[ -n "${WECOM_WEBHOOK_URL:-}" ]]      && env_kv WECOM_WEBHOOK_URL      "${WECOM_WEBHOOK_URL}"
  [[ -n "${GENERIC_WEBHOOK_URL:-}" ]]    && env_kv GENERIC_WEBHOOK_URL    "${GENERIC_WEBHOOK_URL}"
  [[ -n "${GENERIC_WEBHOOK_BEARER:-}" ]] && env_kv GENERIC_WEBHOOK_BEARER "${GENERIC_WEBHOOK_BEARER}"
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
  IFS=',' read -ra _gp <<< "${GIT_PROVIDER_PLUGIN}"
  for _p in "${_gp[@]}"; do
    _p="${_p// /}"
    [[ -z "$_p" ]] && continue
    ( set -a; source .env; set +a; bash "plugins/git-provider/${_p}/preflight.sh" )
  done
  unset _gp _p
  ( set -a; source .env; set +a; bash "plugins/test-runner/${TEST_RUNNER}/preflight.sh" )
  if [[ "${ROLLOUT_PLUGIN}" != "none" ]]; then
    ( set -a; source .env; set +a; bash "plugins/rollout/${ROLLOUT_PLUGIN}/preflight.sh" )
  fi
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
