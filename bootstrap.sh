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
#           auto-generated. Phase 1 → 4 → 9.
#
#   full  : Everything in local + Cloudflare Tunnel + k3s + ArgoCD + Tekton
#           CI/CD. Requires ROOT_DOMAIN, CF_TUNNEL_TOKEN, GIT_USER, GIT_TOKEN
#           and MANIFEST_REPO_URL. Phase 1 → 9.
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
#   ────────────────────────────────
#   9. Health checks + summary
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
phase "Phase 1 / 9  Preflight"

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
phase "Phase 2 / 9  Configuration"

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

# Defaults shared by both modes
REGISTRY_PLUGIN="${REGISTRY_PLUGIN:-self-hosted}"
GIT_PROVIDER_PLUGIN="${GIT_PROVIDER_PLUGIN:-gitee}"
MANIFEST_REPO_BRANCH="${MANIFEST_REPO_BRANCH:-main}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
RABBITMQ_USER="${RABBITMQ_USER:-admin}"
MEILI_ENV="${MEILI_ENV:-production}"

# Auto-generate any blank passwords (both modes)
[[ -z "${POSTGRES_PASSWORD:-}" ]]    && POSTGRES_PASSWORD=$(gen_password)
[[ -z "${REDIS_PASSWORD:-}" ]]       && REDIS_PASSWORD=$(gen_password)
[[ -z "${RABBITMQ_PASSWORD:-}" ]]    && RABBITMQ_PASSWORD=$(gen_password)
[[ -z "${MEILI_MASTER_KEY:-}" ]]     && MEILI_MASTER_KEY=$(gen_password)
[[ -z "${GIT_WEBHOOK_SECRET:-}" ]]   && GIT_WEBHOOK_SECRET=$(gen_password)

# Plugin selection only matters in full mode
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
  ok "Plugins selected: registry=${REGISTRY_PLUGIN}  git-provider=${GIT_PROVIDER_PLUGIN}"

  log "Running plugin preflight checks..."
  ( set -a; source .env; set +a; bash "plugins/registry/${REGISTRY_PLUGIN}/preflight.sh" )
  ( set -a; source .env; set +a; bash "plugins/git-provider/${GIT_PROVIDER_PLUGIN}/preflight.sh" )
  ok "Plugin preflights passed"
fi

# Persist .env (canonical form)
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
  echo "MANIFEST_REPO_URL=${MANIFEST_REPO_URL}"
  echo "MANIFEST_REPO_BRANCH=${MANIFEST_REPO_BRANCH}"
  # ACR specifics carried through if set
  [[ -n "${ALIYUN_ACR_REGISTRY:-}" ]]  && echo "ALIYUN_ACR_REGISTRY=${ALIYUN_ACR_REGISTRY}"
  [[ -n "${ALIYUN_ACR_NAMESPACE:-}" ]] && echo "ALIYUN_ACR_NAMESPACE=${ALIYUN_ACR_NAMESPACE}"
  [[ -n "${ALIYUN_ACR_USER:-}" ]]      && echo "ALIYUN_ACR_USER=${ALIYUN_ACR_USER}"
  [[ -n "${ALIYUN_ACR_PASSWORD:-}" ]]  && echo "ALIYUN_ACR_PASSWORD=${ALIYUN_ACR_PASSWORD}"
} > .env
chmod 600 .env

# Re-export for envsubst
set -a; # shellcheck disable=SC1091
source .env; set +a
ok ".env written (perm 600)"

# =============================================================================
# Phase 3 — Render INFRA.md
# =============================================================================
phase "Phase 3 / 9  Render credential vault"

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
phase "Phase 4 / 9  Compose data services"

cd core/compose

# Tunnel-profile services (cloudflared, caddy) only start in full mode.
COMPOSE_PROFILE_ARGS=()
HEALTH_SERVICES=("postgres" "redis" "rabbitmq" "meilisearch")
if [[ "$OUTPOST_MODE" == "full" ]]; then
  COMPOSE_PROFILE_ARGS=(--profile tunnel)
fi

log "Pulling images..."
docker compose "${COMPOSE_PROFILE_ARGS[@]}" pull
log "Bringing up services..."
docker compose "${COMPOSE_PROFILE_ARGS[@]}" up -d
log "Waiting for health..."
for svc in "${HEALTH_SERVICES[@]}"; do
  for _ in {1..30}; do
    state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "starting")
    [[ "$state" == "healthy" || "$state" == "none" ]] && { ok "$svc healthy"; break; }
    sleep 2
  done
done
cd "$INFRA_ROOT"

# =============================================================================
# Local mode short-circuit
# -----------------------------------------------------------------------------
# Phases 5–8 require k3s + GitOps. In local mode we skip directly to summary.
# =============================================================================
if [[ "$OUTPOST_MODE" == "local" ]]; then
  phase "Phase 9 / 9  Summary (local mode)"

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
  echo "  To upgrade to full mode (CF Tunnel + k3s + GitOps):"
  echo "    1. set OUTPOST_MODE=full in .env"
  echo "    2. fill ROOT_DOMAIN, CF_TUNNEL_TOKEN, GIT_USER, GIT_TOKEN, MANIFEST_REPO_URL"
  echo "    3. re-run bash bootstrap.sh"
  echo ""
  exit 0
fi

# =============================================================================
# Phase 5 — k3s
# =============================================================================
phase "Phase 5 / 9  k3s cluster"

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
ok "k3s ready, namespaces created"

# =============================================================================
# Phase 6 — sealed-secrets
# =============================================================================
phase "Phase 6 / 9  sealed-secrets"

kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
kubectl wait --for=condition=Available --timeout=180s deployment -l name=sealed-secrets-controller -n kube-system 2>/dev/null || true

if ! command -v kubeseal >/dev/null 2>&1; then
  log "Downloading kubeseal CLI..."
  KS_VER="0.27.1"
  case "$SK_OS" in
    macos) ARCH="darwin-amd64" ;;
    *)     ARCH="linux-amd64"  ;;
  esac
  curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KS_VER}/kubeseal-${KS_VER}-${ARCH}.tar.gz" \
    | tar -xz kubeseal
  sudo mv kubeseal /usr/local/bin/
  sudo chmod +x /usr/local/bin/kubeseal
fi
mkdir -p secrets-backup
kubeseal --fetch-cert > secrets-backup/sealed-secrets-pub.pem 2>/dev/null || true
ok "sealed-secrets ready"

# =============================================================================
# Phase 7 — Plugins
# =============================================================================
phase "Phase 7 / 9  Plugins"

log "Applying registry plugin: ${REGISTRY_PLUGIN}"
render_apply "plugins/registry/${REGISTRY_PLUGIN}/manifest.yaml"

log "Applying git-provider plugin: ${GIT_PROVIDER_PLUGIN}"
render_apply "plugins/git-provider/${GIT_PROVIDER_PLUGIN}/manifest.yaml"
ok "Plugins applied"

# =============================================================================
# Phase 8 — ArgoCD + Tekton + bridges
# =============================================================================
phase "Phase 8 / 9  ArgoCD, Tekton, bridges"

# ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f core/k8s/04-argocd/cmd-params-cm.yaml
kubectl rollout restart deployment/argocd-server -n argocd

render_apply "core/k8s/04-argocd/ingress.yaml"
render_apply "core/k8s/04-argocd/repo-secret.template.yaml"
render_apply "core/k8s/04-argocd/bootstrap-app.yaml"

# Tekton
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
sleep 10
kubectl wait --for=condition=Available --timeout=300s deployment --all -n tekton-pipelines || warn "some tekton deploys still rolling"

# Catalog tasks (git-clone, kaniko)
kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.9/git-clone.yaml
kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/kaniko/0.6/kaniko.yaml
kubectl get task git-clone -o yaml | sed 's/kind: Task/kind: ClusterTask/' | kubectl apply -f -
kubectl get task kaniko    -o yaml | sed 's/kind: Task/kind: ClusterTask/' | kubectl apply -f -

# Tekton RBAC + secrets + pipeline + binding/template
kubectl apply -f core/k8s/05-tekton/rbac.yaml
render_apply "core/k8s/05-tekton/secrets.template.yaml"
render_apply "core/k8s/05-tekton/pipeline-build.yaml"
kubectl apply -f core/k8s/05-tekton/task-update-manifest.yaml
render_apply "core/k8s/05-tekton/triggertemplate.yaml"
render_apply "core/k8s/05-tekton/eventlistener.yaml"

# Bridges
kubectl apply -f core/k8s/06-bridges/
ok "ArgoCD + Tekton + bridges applied"

# Get ArgoCD admin password
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '(not yet ready)')
grep -q '^ARGOCD_ADMIN_PASSWORD=' .env || echo "ARGOCD_ADMIN_PASSWORD=${ARGOCD_ADMIN_PASSWORD}" >> .env

# =============================================================================
# Phase 9 — Health summary
# =============================================================================
phase "Phase 9 / 9  Summary"

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
echo "  ArgoCD UI:    https://argocd.${ROOT_DOMAIN}"
echo "  username:     admin"
echo "  password:     ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo "  Webhook URL:  https://hooks.${ROOT_DOMAIN}"
echo "  Webhook secret: ${GIT_WEBHOOK_SECRET}"
echo ""
echo "  Read INFRA.md for the full credential vault."
echo "  Run ./verify.sh anytime to check stack health."
echo ""
