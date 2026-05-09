#!/usr/bin/env bash
# =============================================================================
# Outpost / verify.sh
# -----------------------------------------------------------------------------
# Cross-platform health check. Produces structured PASS/WARN/FAIL output for
# both humans and AI agents.
#
# Usage:
#   ./verify.sh           coloured human output
#   ./verify.sh --json    machine-readable JSON (AI parsable)
#   ./verify.sh --quiet   summary line only
#
# Exit codes:
#   0  all PASS
#   1  any FAIL
#   2  any WARN (no FAIL)
#
# Mode awareness:
#   In OUTPOST_MODE=local the script only checks the Compose data layer
#   (postgres / redis / rabbitmq / meilisearch). k3s, ArgoCD, Tekton and
#   public-edge sections are skipped entirely.
#
# JSON schema is locked at tests/schema/verify-output.schema.json — AI tools
# can rely on the field shape across versions.
# =============================================================================
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }

# shellcheck source=platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"

MODE="human"
case "${1:-}" in
  --json)  MODE="json"  ;;
  --quiet) MODE="quiet" ;;
esac

# Load env (best-effort; verify.sh must work even before bootstrap)
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi
ROOT_DOMAIN="${ROOT_DOMAIN:-example.com}"
OUTPOST_MODE="${OUTPOST_MODE:-local}"
case "$OUTPOST_MODE" in
  local|full) ;;
  *) OUTPOST_MODE="unknown" ;;
esac

# Detect OS quietly
detect_os 2>/dev/null || SK_OS="unknown"

PASS_CNT=0; WARN_CNT=0; FAIL_CNT=0
RESULTS=()

record() {
  local status="$1" id="$2" detail="$3"
  RESULTS+=("$status|$id|$detail")
  case "$status" in
    PASS) PASS_CNT=$((PASS_CNT+1)) ;;
    WARN) WARN_CNT=$((WARN_CNT+1)) ;;
    FAIL) FAIL_CNT=$((FAIL_CNT+1)) ;;
  esac
  if [[ "$MODE" == "human" ]]; then
    case "$status" in
      PASS) echo -e "${SK_C_GREEN}[PASS]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
      WARN) echo -e "${SK_C_YELLOW}[WARN]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
      FAIL) echo -e "${SK_C_RED}[FAIL]${SK_C_RESET} $id ${SK_C_DIM}— $detail${SK_C_RESET}" ;;
    esac
  fi
}

section() {
  if [[ "$MODE" == "human" ]]; then
    echo ""
    echo -e "${SK_C_BOLD}═══ $1 ═══${SK_C_RESET}"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
docker_ok() { docker info >/dev/null 2>&1; }
kubectl_ok() { kubectl version --request-timeout=3s >/dev/null 2>&1; }

# ---- 1. Tooling -------------------------------------------------------------
section "1. Tooling"
# Local mode doesn't need kubectl/helm. Full mode needs them all.
if [[ "$OUTPOST_MODE" == "local" ]]; then
  REQUIRED_TOOLS=(docker openssl envsubst curl)
else
  REQUIRED_TOOLS=(docker kubectl helm openssl envsubst curl git)
fi
for cmd in "${REQUIRED_TOOLS[@]}"; do
  if has_cmd "$cmd"; then
    record PASS "tool.$cmd" "found at $(command -v "$cmd")"
  else
    record FAIL "tool.$cmd" "not installed"
  fi
done
docker_ok && record PASS "docker.daemon" "running" || record FAIL "docker.daemon" "not running"
if [[ "$OUTPOST_MODE" == "full" ]]; then
  kubectl_ok && record PASS "kubectl.cluster" "reachable" || record FAIL "kubectl.cluster" "not reachable"
fi
record PASS "platform.os" "$SK_OS"
record PASS "platform.mode" "OUTPOST_MODE=$OUTPOST_MODE"

# ---- 2. Compose layer -------------------------------------------------------
section "2. Compose data services"
if docker_ok; then
  # Tunnel-profile services only run in full mode.
  if [[ "$OUTPOST_MODE" == "full" ]]; then
    COMPOSE_SVCS=(cloudflared caddy postgres redis rabbitmq meilisearch)
  else
    COMPOSE_SVCS=(postgres redis rabbitmq meilisearch)
  fi
  for svc in "${COMPOSE_SVCS[@]}"; do
    state=$(docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null) || state=""
    state="${state:-missing}"
    case "$state" in
      running)
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "none")
        if [[ "$health" == "healthy" || "$health" == "none" ]]; then
          record PASS "compose.$svc" "running ($health)"
        elif [[ "$health" == "starting" ]]; then
          record WARN "compose.$svc" "starting"
        else
          record FAIL "compose.$svc" "running but $health"
        fi
        ;;
      missing) record FAIL "compose.$svc" "container not found" ;;
      *)       record FAIL "compose.$svc" "state=$state" ;;
    esac
  done
  if [[ "$OUTPOST_MODE" == "full" ]]; then
    if docker logs cloudflared --tail 100 2>&1 | grep -q "Registered tunnel connection"; then
      record PASS "cloudflared.tunnel" "registered to Cloudflare edge"
    else
      record FAIL "cloudflared.tunnel" "not registered"
    fi
  fi
else
  record FAIL "compose.skipped" "docker not running"
fi

# Sections 3–7 are full-mode only. Skip them in local mode.
if [[ "$OUTPOST_MODE" == "full" ]]; then

# ---- 3. K8s ----------------------------------------------------------------
section "3. K8s cluster"
if kubectl_ok; then
  ready=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || true)
  total=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  if [[ "$ready" -ge 1 && "$ready" -eq "$total" ]]; then
    record PASS "k8s.nodes" "$ready/$total Ready"
  else
    record FAIL "k8s.nodes" "$ready/$total Ready"
  fi

  for ns_dep in "argocd:argocd-server" "argocd:argocd-repo-server" \
                "tekton-pipelines:tekton-pipelines-controller" \
                "tekton-pipelines:tekton-triggers-controller" \
                "registry:docker-registry"; do
    ns="${ns_dep%%:*}"; dep="${ns_dep##*:}"
    rep=$(kubectl get deployment -n "$ns" "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    desired=$(kubectl get deployment -n "$ns" "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    if [[ -z "$rep" ]]; then
      record WARN "k8s.$ns.$dep" "not found"
    elif [[ "$rep" == "$desired" && -n "$desired" ]]; then
      record PASS "k8s.$ns.$dep" "$rep/$desired ready"
    else
      record FAIL "k8s.$ns.$dep" "$rep/$desired ready"
    fi
  done

  crashing=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E "CrashLoopBackOff|ImagePullBackOff|ErrImagePull" || true)
  if [[ -z "$crashing" ]]; then
    record PASS "k8s.no_crashloop" "no Crash/ImagePull issues"
  else
    record FAIL "k8s.no_crashloop" "found: $(echo "$crashing" | tr '\n' '; ')"
  fi
fi

# ---- 4. Bridge services ----------------------------------------------------
section "4. Bridge services (k8s → compose)"
if kubectl_ok; then
  for svc in postgres redis rabbitmq meilisearch; do
    if kubectl get svc -n infra-bridges "$svc" >/dev/null 2>&1; then
      ext=$(kubectl get svc -n infra-bridges "$svc" -o jsonpath='{.spec.externalName}' 2>/dev/null)
      if [[ "$ext" == "host.docker.internal" ]]; then
        record PASS "bridge.$svc" "ExternalName → $ext"
      else
        record WARN "bridge.$svc" "externalName=$ext"
      fi
    else
      record FAIL "bridge.$svc" "missing"
    fi
  done
fi

# ---- 5. ArgoCD applications ------------------------------------------------
section "5. ArgoCD applications"
if kubectl_ok; then
  apps=$(kubectl get application -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "$apps" ]]; then
    record WARN "argocd.applications" "no Application yet"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%%=*}"; status="${line##*=}"
      sync="${status%%/*}"; health="${status##*/}"
      if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
        record PASS "argocd.app.$name" "$status"
      elif [[ "$sync" == "OutOfSync" ]]; then
        record WARN "argocd.app.$name" "$status"
      else
        record FAIL "argocd.app.$name" "$status"
      fi
    done <<< "$apps"
  fi
fi

# ---- 6. Tekton --------------------------------------------------------------
section "6. Tekton webhook + recent runs"
if kubectl_ok; then
  if kubectl get eventlistener -A 2>/dev/null | grep -qi listener; then
    record PASS "tekton.eventlistener" "deployed"
  else
    record FAIL "tekton.eventlistener" "missing"
  fi
  recent=$(kubectl get pipelinerun -n tekton-pipelines --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[-3:]}{.metadata.name}={.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}' 2>/dev/null || true)
  if [[ -z "$recent" ]]; then
    record WARN "tekton.recent_runs" "no PipelineRun history"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%%=*}"; ok="${line##*=}"
      case "$ok" in
        True)    record PASS "tekton.run.$name" "Succeeded" ;;
        False)   record FAIL "tekton.run.$name" "Failed"    ;;
        Unknown) record WARN "tekton.run.$name" "Running"   ;;
        *)       record WARN "tekton.run.$name" "$ok"       ;;
      esac
    done <<< "$recent"
  fi
fi

# ---- 7. Public ingress ------------------------------------------------------
section "7. Public ingress (Cloudflare edge)"
check_url() {
  local id="$1" url="$2"
  has_cmd curl || { record WARN "$id" "curl missing"; return; }
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null || echo "000")
  case "$code" in
    200|301|302|307|308|401|403) record PASS "$id" "HTTP $code" ;;
    000)                          record FAIL "$id" "no response" ;;
    502|503|504)                  record FAIL "$id" "HTTP $code (origin)" ;;
    *)                            record WARN "$id" "HTTP $code" ;;
  esac
}
if [[ "$ROOT_DOMAIN" != "example.com" ]]; then
  check_url "edge.argocd"   "https://argocd.${ROOT_DOMAIN}"
  check_url "edge.tekton"   "https://tekton.${ROOT_DOMAIN}"
  check_url "edge.search"   "https://search.${ROOT_DOMAIN}/health"
  check_url "edge.mq"       "https://mq.${ROOT_DOMAIN}"
  check_url "edge.registry" "https://registry.${ROOT_DOMAIN}/v2/"
  check_url "edge.hooks"    "https://hooks.${ROOT_DOMAIN}"
else
  record WARN "edge.skipped" "ROOT_DOMAIN unset"
fi

fi  # end full-mode-only sections

# ---- 8. Credentials hygiene -------------------------------------------------
section "8. Credentials hygiene"
if [[ -f .env ]]; then
  perm=$(portable_stat_perm .env)
  [[ "$perm" == "600" ]] \
    && record PASS "creds.env_perm" ".env perm=600" \
    || record WARN "creds.env_perm" ".env perm=$perm"
else
  record FAIL "creds.env" ".env missing"
fi
[[ -f INFRA.md ]] && record PASS "creds.infra_md" "INFRA.md exists" \
                  || record WARN "creds.infra_md" "INFRA.md missing"

# ---- Output -----------------------------------------------------------------
if [[ "$MODE" == "json" ]]; then
  printf '{"schema_version":"1","summary":{"pass":%d,"warn":%d,"fail":%d,"os":"%s","mode":"%s"},"checks":[' \
    "$PASS_CNT" "$WARN_CNT" "$FAIL_CNT" "${SK_OS:-unknown}" "$OUTPOST_MODE"
  first=1
  for r in "${RESULTS[@]}"; do
    [[ $first -eq 0 ]] && printf ','
    first=0
    status="${r%%|*}"; rest="${r#*|}"
    id="${rest%%|*}"; detail="${rest#*|}"
    detail_esc=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   ')
    printf '{"status":"%s","id":"%s","detail":"%s"}' "$status" "$id" "$detail_esc"
  done
  printf ']}\n'
else
  echo ""
  echo -e "${SK_C_BOLD}═══ Summary ═══${SK_C_RESET}"
  echo -e "${SK_C_GREEN}PASS${SK_C_RESET}: $PASS_CNT  ${SK_C_YELLOW}WARN${SK_C_RESET}: $WARN_CNT  ${SK_C_RED}FAIL${SK_C_RESET}: $FAIL_CNT  (OS: $SK_OS, mode: $OUTPOST_MODE)"
fi

[[ $FAIL_CNT -gt 0 ]] && exit 1
[[ $WARN_CNT -gt 0 ]] && exit 2
exit 0
