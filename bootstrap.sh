#!/usr/bin/env bash
# =============================================================================
# Outpost / bootstrap.sh
# -----------------------------------------------------------------------------
# Cross-platform one-command installer (macOS / Linux / WSL2).
#
# Two modes (set via OUTPOST_MODE in .env):
#
#   local : Compose data services only (PG / Redis / RabbitMQ / Meilisearch
#           on localhost). No CF Tunnel, no k3s, no GitOps. Zero required
#           input — every value either has a sensible default or gets
#           auto-generated. Phase 1 → 4 → 10.
#
#   full  : Everything in local + Cloudflare Tunnel + k3s + ArgoCD + Tekton
#           CI/CD + Testkube + Argo Rollouts + multi-channel notifications.
#           Requires ROOT_DOMAIN, CF_TUNNEL_TOKEN, GIT_USER, GIT_TOKEN
#           and MANIFEST_REPO_URL. Phase 1 → 10.
#
# Phases:
#   1. Preflight: tools, OS detection, docker daemon
#   2. Config: prompt or load .env, generate secrets
#   3. Render: INFRA.md, INFRA.zh-CN.md from .env
#   4. Compose: bring up data services (+ cloudflared + caddy in full mode)
#   ──── full mode only below ────
#   5. k3s: install via platform/<os>.sh
#   6. K8s base: namespaces, traefik NodePort, sealed-secrets
#   7. Plugins: registry plugin + git-provider plugin
#   8. ArgoCD + Tekton + bridges
#   9. CI/CD test gate + auto-rollback + notifications
#       (Testkube + Argo Rollouts + notification plugins)
#   ────────────────────────────────
#   10. Health checks + summary
# =============================================================================
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT"

# Source portable helpers (must come before any log/ok/warn calls)
# shellcheck source=platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"

export SK_INFRA_DIR="$INFRA_ROOT"

# =============================================================================
# Phase 1 — Preflight
# =============================================================================
phase "Phase 1 / 10 Preflight"

require_cmd bash curl openssl envsubst sed grep awk

if ! detect_os; then
  exit 1
fi
ok "OS detected: $SK_OS"

# Source platform-specific hooks
# shellcheck source=/dev/null
source "${INFRA_ROOT}/platform/${SK_OS}.sh"

# Docker
sk_install_docker

# docker compose v2
if ! docker compose version >/dev/null 2>&1; then
  err "docker compose v2 plugin required (try: brew/apt install docker-compose-plugin)"
  exit 1
fi
ok "docker compose v2 available"

# =============================================================================
# Phase 2 — Config
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
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
RABBITMQ_USER="${RABBITMQ_USER:-admin}"
MEILI_ENV="${MEILI_ENV:-production}"

# Phase 9 plugin defaults (full mode only — but read in both so .env is consistent)
TEST_RUNNER="${TEST_RUNNER:-testkube}"
TESTKUBE_MODE="${TESTKUBE_MODE:-oss}"
ROLLOUT_PLUGIN="${ROLLOUT_PLUGIN:-argo-rollouts}"
ROLLOUTS_DASHBOARD_HOST="${ROLLOUTS_DASHBOARD_HOST:-rollouts.${ROOT_DOMAIN}}"
NOTIFICATION_PROVIDERS="${NOTIFICATION_PROVIDERS:-}"
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
[[ -z "${MEILI_MASTER_KEY:-}" ]]       && MEILI_MASTER_KEY=$(gen_password)
[[ -z "${GIT_WEBHOOK_SECRET:-}" ]]     && GIT_WEBHOOK_SECRET=$(gen_password)
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

  # Resolve registry-plugin-aware Pipeline params. Pipeline-build.yaml uses
  # ${REGISTRY_HOST} / ${REGISTRY_PUSH_HOST} / ${KANIKO_EXTRA_ARGS} as defaults
  # so a single Pipeline definition serves all registry plugins without
  # per-plugin pipeline overrides.
  case "$REGISTRY_PLUGIN" in
    self-hosted)
      REGISTRY_HOST="registry.${ROOT_DOMAIN}"
      # Push to the in-cluster Service to bypass cloudflared HTTP/2 limit
      # on large blob uploads (Java/.NET multi-stage builds OOM at the edge).
      REGISTRY_PUSH_HOST="docker-registry.registry.svc.cluster.local:5000"
      # In-cluster registry is plain HTTP, anonymous — kaniko needs both
      # insecure flags. --cache=true reuses the same registry under /cache
      # to warm subsequent builds (Java/.NET cold-cache used to hit 90m).
      KANIKO_EXTRA_ARGS='["--skip-tls-verify","--insecure","--cache=true","--cache-repo=docker-registry.registry.svc.cluster.local:5000/cache"]'
      ;;
    aliyun-acr)
      REGISTRY_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      # ACR is HTTPS-only with valid certs; pushing through the public
      # endpoint is fine. registry-push and registry are the same host.
      REGISTRY_PUSH_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      # No insecure flags — they would force kaniko to attempt plain HTTP
      # which ACR refuses. Cache lives under /cache in the same namespace.
      # shellcheck disable=SC2089  # literal quotes are intended — value is a JSON-shape string for envsubst
      KANIKO_EXTRA_ARGS="[\"--cache=true\",\"--cache-repo=${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}/cache\"]"
      ;;
    *)
      err "REGISTRY_PLUGIN '$REGISTRY_PLUGIN' lacks a kaniko config block in bootstrap.sh"
      err "Add a case branch setting REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS"
      exit 1
      ;;
  esac
  # shellcheck disable=SC2090  # KANIKO_EXTRA_ARGS holds intentional literal quotes; consumed by envsubst into pipeline-build.yaml
  export REGISTRY_HOST REGISTRY_PUSH_HOST KANIKO_EXTRA_ARGS

  # ---- WEBHOOK_REPO_WHITELIST → CEL list literal ----
  # Empty (default) → []  → CEL filter `size([]) == 0 || ...` short-circuits
  #                         to true, accepting any repo.
  # Set            → ['url1','url2',...] → CEL filter only accepts those.
  # See eventlistener.yaml's interceptor that consumes ${CEL_WHITELIST_LIST}.
  if [[ -n "${WEBHOOK_REPO_WHITELIST:-}" ]]; then
    CEL_WHITELIST_LIST="["
    IFS=',' read -ra _wl <<< "$WEBHOOK_REPO_WHITELIST"
    for _r in "${_wl[@]}"; do
      _r="${_r// /}"
      [[ -z "$_r" ]] && continue
      CEL_WHITELIST_LIST+="'$_r',"
    done
    CEL_WHITELIST_LIST="${CEL_WHITELIST_LIST%,}]"
    unset _wl _r
  else
    CEL_WHITELIST_LIST="[]"
  fi
  export CEL_WHITELIST_LIST
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
  echo "MEILI_MASTER_KEY=${MEILI_MASTER_KEY}"
  echo "MEILI_ENV=${MEILI_ENV}"
  echo "GIT_USER=${GIT_USER}"
  echo "GIT_TOKEN=${GIT_TOKEN}"
  echo "GIT_WEBHOOK_SECRET=${GIT_WEBHOOK_SECRET}"
  echo "OUTPOST_DASHBOARD_USER=${OUTPOST_DASHBOARD_USER}"
  echo "OUTPOST_DASHBOARD_PASSWORD=${OUTPOST_DASHBOARD_PASSWORD}"
  echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
  echo "MANIFEST_REPO_BRANCH=${MANIFEST_REPO_BRANCH}"
  echo "GIT_HOST=${GIT_HOST}"
  # Registry-plugin-derived Pipeline defaults (re-derived on each bootstrap,
  # but persisted so status.sh / verify.sh can show what's active).
  echo "REGISTRY_HOST=${REGISTRY_HOST:-}"
  echo "REGISTRY_PUSH_HOST=${REGISTRY_PUSH_HOST:-}"
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

# =============================================================================
# Phase 3 — Render INFRA.md
# =============================================================================
phase "Phase 3 / 10 Render credential vault"

# Local mode uses a slimmer template (no public hosts, no GitOps section).
if [[ "$OUTPOST_MODE" == "local" ]]; then
  TMPL_BASENAME="INFRA.local.md.template"
else
  TMPL_BASENAME="INFRA.md.template"
fi

for tmpl in "i18n/en/${TMPL_BASENAME}" "i18n/zh-CN/${TMPL_BASENAME}"; do
  [[ -f "$tmpl" ]] || continue
  out_lang="${tmpl#i18n/}"
  out_lang="${out_lang%%/*}"
  if [[ "$out_lang" == "en" ]]; then
    render_template "$tmpl" "INFRA.md"
  else
    render_template "$tmpl" "INFRA.${out_lang}.md"
  fi
done
[[ -f INFRA.md ]] && chmod 600 INFRA.md
[[ -f INFRA.zh-CN.md ]] && chmod 600 INFRA.zh-CN.md
ok "Credential vault(s) rendered"

# =============================================================================
# Phase 4 — Compose layer
# =============================================================================
phase "Phase 4 / 10 Compose data services"

# Always invoke `docker compose` with explicit --env-file and -f so that
# any caller (this script, the launchd agent, status.sh, reset.sh) gets
# the same canonical view, regardless of CWD or shell environment.
# The .env file lives at the infra root, not next to docker-compose.yml.
COMPOSE_ARGS=(--env-file "${INFRA_ROOT}/.env" -f "${INFRA_ROOT}/core/compose/docker-compose.yml")
HEALTH_SERVICES=("postgres" "redis" "rabbitmq" "meilisearch")
if [[ "$OUTPOST_MODE" == "full" ]]; then
  COMPOSE_ARGS+=(--profile tunnel)
fi

log "Pulling images..."
docker compose "${COMPOSE_ARGS[@]}" pull
log "Bringing up services..."
docker compose "${COMPOSE_ARGS[@]}" up -d
log "Waiting for health..."
for svc in "${HEALTH_SERVICES[@]}"; do
  healthy=0
  for _ in {1..30}; do
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "starting")
    if [[ "$state" == "healthy" ]]; then
      ok "$svc healthy"; healthy=1; break
    fi
    sleep 2
  done
  if [[ "$healthy" -eq 0 ]]; then
    err "$svc did not reach healthy state — check: docker logs $svc --tail 50"
    exit 1
  fi
done

# =============================================================================
# Local mode short-circuit
# -----------------------------------------------------------------------------
# Phases 5–8 require k3s + GitOps. In local mode we skip directly to summary.
# =============================================================================
if [[ "$OUTPOST_MODE" == "local" ]]; then
  phase "Phase 10 / 10 Summary (local mode)"

  echo ""
  echo "Compose:"
  docker compose -f core/compose/docker-compose.yml ps
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Outpost bootstrap complete (local mode)"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  echo "  PostgreSQL : postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"
  echo "  Redis      : redis://default:${REDIS_PASSWORD}@localhost:6379/0"
  echo "  RabbitMQ   : amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@localhost:5672/  (UI: http://localhost:15672)"
  echo "  Meilisearch: http://localhost:7700  (Bearer ${MEILI_MASTER_KEY})"
  echo ""
  echo "  Read INFRA.md for full credential vault."
  echo "  Run ./verify.sh anytime to check stack health."
  echo ""
  echo "  To upgrade to full mode (CF Tunnel + k3s + GitOps), follow the"
  echo "  quickstart full-mode walkthrough:"
  echo "    i18n/en/docs/00-quickstart.md      (Phase A through I)"
  echo "    i18n/zh-CN/docs/00-quickstart.md   (Chinese version)"
  echo ""
  exit 0
fi

# =============================================================================
# Phase 5 — k3s
# =============================================================================
phase "Phase 5 / 10 k3s cluster"

sk_install_k3s
sk_setup_autostart
sk_configure_registry_mirror

# Apply Traefik NodePort config
case "$SK_OS" in
  linux|wsl2)
    sudo cp core/k8s/01-traefik-config.yaml /var/lib/rancher/k3s/server/manifests/
    sleep 5
    ;;
  macos)
    # k3d already exposes 30080/30443 via the cluster create command.
    kubectl apply -f core/k8s/01-traefik-config.yaml
    ;;
esac

# Configure containerd insecure registry mirror for self-hosted plugin
if [[ "$REGISTRY_PLUGIN" == "self-hosted" && ( "$SK_OS" == "linux" || "$SK_OS" == "wsl2" ) ]]; then
  log "Configuring containerd insecure registry mirror..."
  sudo mkdir -p /etc/rancher/k3s
  sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<EOF
mirrors:
  registry.${ROOT_DOMAIN}:
    endpoint:
      - "http://registry.${ROOT_DOMAIN}"
configs:
  registry.${ROOT_DOMAIN}:
    tls:
      insecure_skip_verify: true
EOF
  sudo systemctl restart k3s 2>/dev/null || true
  sleep 10
fi

kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f core/k8s/00-namespaces.yaml
kubectl apply -f core/k8s/02-apps-resource-controls.yaml
ok "k3s ready, namespaces + apps resource controls applied"

# =============================================================================
# Phase 6 — sealed-secrets
# =============================================================================
phase "Phase 6 / 10 sealed-secrets"

# -----------------------------------------------------------------------------
# Restore master key BEFORE installing the controller — otherwise the
# controller generates a brand-new RSA keypair and existing SealedSecrets
# in your manifest repos can never be decrypted again. Without this,
# every cluster reset is a Sealed-Secrets bankruptcy event.
# Backup file is gitignored (.gitignore covers secrets-backup/), preserved
# across resets by reset.sh's default behaviour.
# -----------------------------------------------------------------------------
if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
  log "Restoring sealed-secrets master key from secrets-backup/..."
  kubectl apply -f secrets-backup/sealed-secrets-master.key.yaml >/dev/null
  ok "  master key restored — old SealedSecrets will decrypt on this cluster"
fi

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
kubectl wait --for=condition=Available --timeout=180s deployment -l name=sealed-secrets-controller -n kube-system 2>/dev/null || true

# If we restored a key, restart the controller so it picks up the restored
# Secret on its next leader election (controller caches keys at startup).
if [[ -f secrets-backup/sealed-secrets-master.key.yaml ]]; then
  kubectl -n kube-system rollout restart deployment sealed-secrets-controller >/dev/null
  kubectl wait --for=condition=Available --timeout=180s deployment -l name=sealed-secrets-controller -n kube-system 2>/dev/null || true
fi

if ! command -v kubeseal >/dev/null 2>&1; then
  log "Downloading kubeseal CLI..."
  # Pin kubeseal to a known-good version. Bump as new releases are validated.
  # https://github.com/bitnami-labs/sealed-secrets/releases
  KS_VER="0.28.0"
  case "$SK_OS" in
    macos)
      # Apple Silicon (M-series) needs darwin-arm64; Intel Macs darwin-amd64.
      if [[ "$(uname -m)" == "arm64" ]]; then
        ARCH="darwin-arm64"
      else
        ARCH="darwin-amd64"
      fi
      ;;
    *)
      if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        ARCH="linux-arm64"
      else
        ARCH="linux-amd64"
      fi
      ;;
  esac
  curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS_VER}/kubeseal-${KS_VER}-${ARCH}.tar.gz" \
    | tar -xz kubeseal
  sudo mv kubeseal /usr/local/bin/
  sudo chmod +x /usr/local/bin/kubeseal
fi
mkdir -p secrets-backup
chmod 700 secrets-backup
kubeseal --fetch-cert > secrets-backup/sealed-secrets-pub.pem 2>/dev/null || true

# Backup master private key (RSA) — restored on next bootstrap to keep
# existing SealedSecrets decryptable. Gitignored by .gitignore.
log "Backing up sealed-secrets master key for cross-reset continuity..."
if kubectl -n kube-system get secret \
     -l sealedsecrets.bitnami.com/sealed-secrets-key \
     -o yaml > secrets-backup/sealed-secrets-master.key.yaml.tmp 2>/dev/null \
   && grep -q 'kind: List' secrets-backup/sealed-secrets-master.key.yaml.tmp; then
  mv secrets-backup/sealed-secrets-master.key.yaml.tmp \
     secrets-backup/sealed-secrets-master.key.yaml
  chmod 600 secrets-backup/sealed-secrets-master.key.yaml
  ok "sealed-secrets ready (master key backed up to secrets-backup/)"
else
  rm -f secrets-backup/sealed-secrets-master.key.yaml.tmp
  warn "Could not back up sealed-secrets master key — re-run bootstrap to retry"
fi

# =============================================================================
# Phase 7 — Plugins (registry only; git-provider needs Tekton CRDs from Phase 8)
# =============================================================================
phase "Phase 7 / 10 Plugins (registry)"

log "Applying registry plugin: ${REGISTRY_PLUGIN}"
render_apply "plugins/registry/${REGISTRY_PLUGIN}/manifest.yaml"
ok "Registry plugin applied"

# Configure containerd to use the in-cluster docker-registry as a mirror for
# `registry.${ROOT_DOMAIN}`. Without this, k8s pulls go through cloudflared,
# which has an HTTP/2 PROTOCOL_ERROR ceiling on large blob transfers
# (multi-stage Java/Dotnet builds easily hit it).
#
# macOS-specific path: k3d node is a Docker container; we write registries.yaml
# inside it (idempotent on content) and restart the k3s server only when
# content actually changed (so re-running bootstrap on a healthy cluster is
# disruption-free).
if [[ "$REGISTRY_PLUGIN" == "self-hosted" && "$SK_OS" == "macos" ]]; then
  log "Configuring k3d containerd registry mirror (macOS)..."

  # docker-registry Service ClusterIP is stable for the cluster's lifetime
  # (recreated on `k3d cluster delete`; that's fine — bootstrap re-runs).
  REG_IP=$(kubectl get svc -n registry docker-registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [[ -z "$REG_IP" ]]; then
    warn "docker-registry ClusterIP not found yet — skipping mirror config"
  else
    DESIRED=$(cat <<EOF
mirrors:
  registry.${ROOT_DOMAIN}:
    endpoint:
      - "http://${REG_IP}:5000"
configs:
  "${REG_IP}:5000":
    tls:
      insecure_skip_verify: true
EOF
)
    K3D_NODE="k3d-${OUTPOST_K3D_CLUSTER:-selfhost}-server-0"
    CURRENT=$(docker exec "$K3D_NODE" cat /etc/rancher/k3s/registries.yaml 2>/dev/null || echo "")
    if [[ "$CURRENT" != "$DESIRED" ]]; then
      printf '%s\n' "$DESIRED" | docker exec -i "$K3D_NODE" sh -c 'cat > /etc/rancher/k3s/registries.yaml'
      log "  registries.yaml updated; restarting k3d node to reload containerd..."
      docker restart "$K3D_NODE" >/dev/null
      # Wait for kube-apiserver to come back before asking it for node status —
      # otherwise kubectl wait gets ServiceUnavailable from the LB and exits
      # immediately (set -e then aborts the whole bootstrap).
      log "  waiting for kube-apiserver to come back..."
      for _ in {1..60}; do
        kubectl get --raw=/readyz >/dev/null 2>&1 && break
        sleep 2
      done
      kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
      ok "containerd mirror set: registry.${ROOT_DOMAIN} -> ${REG_IP}:5000"
    else
      ok "containerd mirror already up to date"
    fi
  fi
fi

# git-provider plugin contains Tekton TriggerBinding (triggers.tekton.dev CRD).
# Defer it to Phase 8 right after `kubectl apply` of Tekton triggers/release.yaml.

# =============================================================================
# Phase 8 — ArgoCD + Tekton + bridges
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

# Catalog tasks (git-clone, kaniko) — applied as namespace-scoped Tasks in
# tekton-pipelines. ClusterTask was removed from tekton.dev/v1 in Tekton
# v0.50; pipeline-build.yaml references these via `kind: Task`.
#
# Versions chosen for Tekton tekton.dev/v1 API compatibility:
#   git-clone 0.10 — current v1 API, supersedes 0.9 (v1beta1)
#   kaniko    0.7  — current v1 API. NOTE: marked deprecated upstream;
#                    pinned executor v1.5.1 is a multi-arch manifest list
#                    (incl. linux/arm64), so Apple Silicon k3d works.
#                    See TODOS.md for replacement plan (buildah/kaniko v1.20+).
kubectl apply -n tekton-pipelines \
  -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.10/git-clone.yaml
kubectl apply -n tekton-pipelines \
  -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/kaniko/0.7/kaniko.yaml

# Tekton RBAC + secrets + pipeline + binding/template
kubectl apply -f core/k8s/05-tekton/rbac.yaml
render_apply "core/k8s/05-tekton/secrets.template.yaml"
render_apply "core/k8s/05-tekton/pipeline-build.yaml"

# update-manifest Task is split: scripts/update-manifest.sh is the canonical
# source, mounted into the Task via this ConfigMap. Re-apply on every run so
# script edits take effect without manual ConfigMap surgery.
kubectl create configmap update-manifest-script \
  --from-file=update-manifest.sh=scripts/update-manifest.sh \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f core/k8s/05-tekton/task-update-manifest.yaml

render_apply "core/k8s/05-tekton/triggertemplate.yaml"
render_apply "core/k8s/05-tekton/eventlistener.yaml"

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

# =============================================================================
# Phase 9 — CI/CD test gate + auto-rollback + notifications
# -----------------------------------------------------------------------------
# Wires up Gate A (Tekton run-tests Task), Gate B (Argo Rollouts canary +
# auto-rollback), and multi-channel notifications. Idempotent: safe to re-run.
# =============================================================================
phase "Phase 9 / 10 Test gate, auto-rollback, notifications"

# ---- 9a. Test runner ----
log "Installing test-runner: ${TEST_RUNNER}"
case "${TEST_RUNNER}" in
  testkube)
    if [[ "${TESTKUBE_MODE}" == "oss" ]]; then
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
  kubectl apply --server-side=true --force-conflicts -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl apply --server-side=true --force-conflicts -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml
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
  done
  unset _np _p _tmp_manifest

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

# =============================================================================
# Phase 10 — Health summary
# =============================================================================
phase "Phase 10 / 10 Summary"

echo ""
echo "Compose:"
docker compose -f core/compose/docker-compose.yml ps
echo ""
echo "K8s pods:"
kubectl get pods -A 2>/dev/null | head -40

# Platform-specific tail notes
sk_print_post_install_notes

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Outpost bootstrap complete (full mode)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ArgoCD UI:        https://argocd.${ROOT_DOMAIN}"
echo "  username:         admin"
echo "  password:         ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo "  Tekton Dashboard: https://tekton.${ROOT_DOMAIN}"
echo "                    (PipelineRuns / TaskRuns / logs)"
echo "  Rollouts UI:      https://${ROLLOUTS_DASHBOARD_HOST}"
echo "                    (canary progress / abort / promote)"
echo "  Dashboard auth:   user ${OUTPOST_DASHBOARD_USER} / pass ${OUTPOST_DASHBOARD_PASSWORD}"
echo "                    (shared BasicAuth in front of BOTH dashboards;"
echo "                     upgrade to Cloudflare Access for SSO/IdP)"
echo ""
echo "  Test runner:      ${TEST_RUNNER}  (mode: ${TESTKUBE_MODE})"
echo "  Notifications:    ${NOTIFICATION_PROVIDERS:-(none)}"
echo ""
echo "  Webhook URL:      https://hooks.${ROOT_DOMAIN}"
echo "  Webhook secret:   ${GIT_WEBHOOK_SECRET}"
echo ""
echo "  Read INFRA.md for the full credential vault."
echo "  Run ./verify.sh anytime to check stack health."
echo ""
echo "  First-time setup verification (Phase F of the quickstart):"
echo "    bash verify.sh"
echo "    docker logs cloudflared --tail 50 | grep 'Registered tunnel connection'"
echo "    open https://argocd.${ROOT_DOMAIN}   # or curl"
echo ""
echo "  Step-by-step walkthrough (incl. autostart, dev workstation TCP,"
echo "  onboarding apps): i18n/<lang>/docs/00-quickstart.md"
echo ""
