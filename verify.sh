#!/usr/bin/env bash
# =============================================================================
# Outpost / verify.sh  (v0.3 — liveness + reconciliation rewrite)
# -----------------------------------------------------------------------------
# Cross-platform health check. Produces structured PASS/WARN/FAIL output for
# both humans and AI agents. FAIL-not-WARN discipline: anything that means
# "pushes stop turning into deploys" is FAIL, never a polite warning — the
# 9-day gitee-webhook silence happened because capability checks passed while
# liveness was dead.
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
#   local: only tooling + the Compose data layer (local-data profile).
#   full : compose edge (caddy/cloudflared) + k8s core + CI trigger path
#          (runner unit + GitHub API) + manifest-sync heartbeat + per-repo
#          RECONCILIATION (live HEAD vs deployed tag — the ultimate judge,
#          standing outside the whole chain) + real data-layer probes.
#
# Reconciliation state: mismatches only become FAIL after persisting longer
# than OUTPOST_STALENESS_THRESHOLD; first-seen timestamps live in
# ${OUTPOST_VERIFY_STATE_DIR:-.outpost-state}/ (gitignored) along with a warm
# manifest-repo checkout. This is the ONLY thing verify.sh writes.
#
# JSON schema is locked at tests/schema/verify-output.schema.json — AI tools
# can rely on the field shape across versions.
# =============================================================================
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }

# shellcheck source=platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"
# Repo-name → manifest apps/<dir> mapping — the SAME lib update-manifest.sh
# and `outpost rollback` use, so reconciliation can never drift from CI.
# shellcheck source=scripts/lib/manifest-map.sh
source "${INFRA_ROOT}/scripts/lib/manifest-map.sh"

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
MANIFEST_SYNC_INTERVAL="${MANIFEST_SYNC_INTERVAL:-2}"
OUTPOST_STALENESS_THRESHOLD="${OUTPOST_STALENESS_THRESHOLD:-1800}"
STATE_DIR="${OUTPOST_VERIFY_STATE_DIR:-${INFRA_ROOT}/.outpost-state}"

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
# Schema id charset is ^[a-z][a-z0-9_.-]*$ — sanitize dynamic fragments.
san_id() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_'; }

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
# Per-profile: full = `edge` + `local-data` (ingress AND the data layer —
# stateful services stay in Compose in both modes, owner decision v0.3.1),
# local = `local-data` only (the four data services ARE the stack).
section "2. Compose ($([[ "$OUTPOST_MODE" == "full" ]] && echo "edge + local-data" || echo local-data) profiles)"
if docker_ok; then
  if [[ "$OUTPOST_MODE" == "full" ]]; then
    COMPOSE_SVCS=(cloudflared caddy postgres redis rabbitmq manticore)
  else
    COMPOSE_SVCS=(postgres redis rabbitmq manticore)
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

# Sections 3–8 are full-mode only. Skip them in local mode.
if [[ "$OUTPOST_MODE" == "full" ]]; then

# ---- 3. K8s core -------------------------------------------------------------
section "3. K8s core"
if kubectl_ok; then
  ready=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || true)
  total=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  if [[ "$ready" -ge 1 && "$ready" -eq "$total" ]]; then
    record PASS "k8s.nodes" "$ready/$total Ready"
  else
    record FAIL "k8s.nodes" "$ready/$total Ready"
  fi

  for ns_dep in "registry:docker-registry" \
                "registry:verdaccio" \
                "buildkit:buildkitd" \
                "argo-rollouts:argo-rollouts" \
                "testkube:testkube-api-server"; do
    ns="${ns_dep%%:*}"; dep="${ns_dep##*:}"
    # Skip plugin namespaces if not installed (rollout plugin defaults to
    # none; testkube agent install defaults to skip).
    kubectl get ns "$ns" >/dev/null 2>&1 || { record WARN "k8s.$ns.$dep" "ns absent — plugin not installed (skip)"; continue; }
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

  # Active build engine — FAIL-level, not the generic ns-absent WARN above.
  # buildkitd down means EVERY build fails; a WARN here is the same
  # capability≠liveness self-deception the gitee-webhook incident taught us.
  if [[ "${BUILD_ENGINE_TASK:-buildkit}" == "buildkit" ]]; then
    bk_ready=$(kubectl get deployment buildkitd -n buildkit \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
    if [[ "$bk_ready" == "True" ]]; then
      record PASS "buildkit.daemon" "active build engine Ready"
    else
      record FAIL "buildkit.daemon" "BUILD_ENGINE_TASK=buildkit but daemon not Available — ALL builds will fail (kubectl -n buildkit get pods)"
    fi
  fi

  # Plugin marker ConfigMaps (cheap proof the plugin manifests applied).
  for entry in "testkube:cm:outpost-test-runner" \
               "argo-rollouts:cm:outpost-rollout"; do
    IFS=":" read -r ns kind name <<< "$entry"
    kubectl get ns "$ns" >/dev/null 2>&1 || continue  # plugin off — already WARNed above
    if kubectl get -n "$ns" "$kind" "$name" >/dev/null 2>&1; then
      record PASS "k8s.$ns.$name" "$kind exists"
    else
      record WARN "k8s.$ns.$name" "$kind missing — re-run bootstrap if you expected this plugin"
    fi
  done

  # Distinguish "kubectl itself failed" from "checked and found nothing" —
  # an API blip must not read as a clean bill of health.
  if _pods_raw=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null); then
    crashing=$(printf '%s' "$_pods_raw" | grep -E "CrashLoopBackOff|ImagePullBackOff|ErrImagePull" || true)
    if [[ -z "$crashing" ]]; then
      record PASS "k8s.no_crashloop" "no Crash/ImagePull issues"
    else
      record FAIL "k8s.no_crashloop" "found: $(echo "$crashing" | tr '\n' '; ')"
    fi
  else
    record FAIL "k8s.no_crashloop" "kubectl get pods -A itself failed — cannot assess pod health (API server down?)"
  fi
  unset _pods_raw
fi

# ---- 4. CI trigger path (GitHub Actions runner) ------------------------------
# Anti-silence layer 2a: the runner must be RUNNING (systemd) and ONLINE
# (GitHub's view). With a PAT configured, an unreachable api.github.com is a
# FAIL — an unreachable GitHub means no push triggers any build, which is
# exactly the silent-death class this section exists to catch.
section "4. CI trigger (GitHub Actions runner)"
if [[ -z "${GITHUB_RUNNER_PAT:-}" ]]; then
  # A production full-mode box without a runner means NO push ever builds —
  # that is exactly the silent-death class, so it must be FAIL by default.
  # OUTPOST_CI_SELFTEST=1 (set only by this repo's own e2e workflow) opts
  # into WARN for runner-less k3d rehearsals.
  if [[ "${OUTPOST_CI_SELFTEST:-0}" == "1" ]]; then
    record WARN "ci.runner" "runner not configured (GITHUB_RUNNER_PAT empty) — OUTPOST_CI_SELFTEST=1, tolerated for this repo's own e2e"
  else
    record FAIL "ci.runner" "GITHUB_RUNNER_PAT empty — NO CI builds will ever trigger; set GITHUB_RUNNER_URL/PAT in .env and re-run bootstrap"
  fi
else
  # (a) local liveness: the runner's systemd unit
  case "$SK_OS" in
    linux|wsl2)
      if has_cmd systemctl; then
        _runner_units=$(systemctl list-units --type=service --state=running 'actions.runner.*' --no-legend 2>/dev/null | grep -c "actions.runner" || true)
        if [[ "${_runner_units:-0}" -ge 1 ]]; then
          record PASS "ci.runner.unit" "actions.runner service running (systemd)"
        else
          record FAIL "ci.runner.unit" "no running actions.runner.* systemd unit — pushes will queue forever (cd ~/actions-runner && sudo ./svc.sh status)"
        fi
      else
        record WARN "ci.runner.unit" "systemctl not available — cannot check runner service"
      fi
      ;;
    *)
      record WARN "ci.runner.unit" "non-systemd platform ($SK_OS) — check the runner via ~/actions-runner/svc.sh status"
      ;;
  esac

  # (b) GitHub's view: is a runner online for GITHUB_RUNNER_URL?
  _gh_path="${GITHUB_RUNNER_URL#https://github.com/}"
  _gh_path="${_gh_path%/}"
  if [[ "$_gh_path" == */* ]]; then _gh_api="repos/${_gh_path}"; else _gh_api="orgs/${_gh_path}"; fi
  _runners_json=$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer ${GITHUB_RUNNER_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/${_gh_api}/actions/runners?per_page=100" 2>/dev/null) || _runners_json=""
  if [[ -z "$_runners_json" ]]; then
    record FAIL "ci.runner.online" "CI trigger path down — api.github.com unreachable or PAT rejected (proxy? token scope?)"
  else
    _online=$(printf '%s' "$_runners_json" | grep -c '"status": *"online"' || true)
    if [[ "${_online:-0}" -ge 1 ]]; then
      record PASS "ci.runner.online" "$_online runner(s) online at ${GITHUB_RUNNER_URL}"
    else
      record FAIL "ci.runner.online" "GitHub reports NO online runner for ${GITHUB_RUNNER_URL} — pushes will queue forever"
    fi
  fi

  # (c) last workflow conclusion per github.com-hosted OUTPOST_REPOS entry.
  IFS=',' read -ra _entries <<< "${OUTPOST_REPOS:-}"
  for _e in "${_entries[@]:-}"; do
    _e="${_e// /}"
    [[ -z "$_e" ]] && continue
    _url="${_e%%#*}"
    case "$_url" in
      https://github.com/*) : ;;
      *) continue ;;  # gitee-canonical repos are judged by reconciliation below
    esac
    _slug="${_url#https://github.com/}"
    _slug="${_slug%.git}"
    _name=$(san_id "${_slug##*/}")
    _run_json=$(curl -fsS --max-time 15 \
      -H "Authorization: Bearer ${GITHUB_RUNNER_PAT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${_slug}/actions/runs?per_page=1" 2>/dev/null) || _run_json=""
    if [[ -z "$_run_json" ]]; then
      record FAIL "ci.workflow.$_name" "CI trigger path down — cannot query workflow runs for $_slug"
      continue
    fi
    _concl=$(printf '%s' "$_run_json" | sed -n 's/.*"conclusion": *"\([^"]*\)".*/\1/p' | head -n1)
    _status=$(printf '%s' "$_run_json" | sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' | head -n1)
    if [[ -z "$_status" ]]; then
      record WARN "ci.workflow.$_name" "no workflow runs yet — if this repo has pushes, the workflow file is missing (templates/github/outpost-build.yml)"
    elif [[ "$_concl" == "success" ]]; then
      record PASS "ci.workflow.$_name" "last run: success"
    elif [[ "$_status" == "in_progress" || "$_status" == "queued" ]]; then
      record WARN "ci.workflow.$_name" "last run: $_status"
    else
      record FAIL "ci.workflow.$_name" "last run: ${_concl:-$_status}"
    fi
  done
  unset _entries _e _url _slug _name _run_json _concl _status _runners_json _gh_path _gh_api _runner_units
fi

# ---- 5. CD (manifest-sync heartbeat) -----------------------------------------
# Anti-silence layer 2b: the sync CronJob must exist AND have heartbeated
# within 3× its interval, AND its last run must have succeeded. Every branch
# that means "deploys stopped" is FAIL.
section "5. CD (manifest-sync)"
if kubectl_ok; then
  if kubectl get cronjob manifest-sync -n outpost-ci >/dev/null 2>&1; then
    record PASS "sync.cronjob" "manifest-sync CronJob present (ns outpost-ci)"
  else
    record FAIL "sync.cronjob" "manifest-sync CronJob MISSING — nothing deploys; re-run bootstrap"
  fi
  hb_ts=$(kubectl get configmap sync-heartbeat -n outpost-ci -o jsonpath='{.data.last_sync_ts}' 2>/dev/null || true)
  hb_result=$(kubectl get configmap sync-heartbeat -n outpost-ci -o jsonpath='{.data.last_result}' 2>/dev/null || true)
  hb_head=$(kubectl get configmap sync-heartbeat -n outpost-ci -o jsonpath='{.data.applied_head}' 2>/dev/null || true)
  if [[ -z "$hb_ts" ]]; then
    record FAIL "sync.heartbeat" "sync-heartbeat ConfigMap missing/empty — sync has NEVER completed a run"
  else
    now_ts=$(date +%s)
    hb_age=$(( now_ts - hb_ts ))
    hb_max=$(( MANIFEST_SYNC_INTERVAL * 60 * 3 ))
    if [[ "$hb_age" -le "$hb_max" ]]; then
      record PASS "sync.heartbeat" "age ${hb_age}s (limit ${hb_max}s), applied_head=${hb_head:0:7}"
    else
      record FAIL "sync.heartbeat" "STALE: last heartbeat ${hb_age}s ago (limit ${hb_max}s) — sync stopped running (kubectl -n outpost-ci get jobs)"
    fi
    if [[ "$hb_result" == "ok" ]]; then
      record PASS "sync.result" "last_result=ok"
    else
      record FAIL "sync.result" "last_result='${hb_result:-<empty>}' — last sync run FAILED (outpost logs sync)"
    fi
  fi
fi

# ---- 6. Reconciliation (live HEAD vs deployed tag) ----------------------------
# Anti-silence layer 1 — the ULTIMATE JUDGE. For every OUTPOST_REPOS entry:
# authenticated ls-remote of the LIVE branch head vs the tag deployed in the
# manifest repo. A mismatch persisting past OUTPOST_STALENESS_THRESHOLD is a
# FAIL naming the repo — this catches a dead gitee→github mirror, a GitHub
# outage, an offline runner, a red workflow, a dead buildkitd or a stalled
# sync, all from OUTSIDE the chain that could be lying.
section "6. Reconciliation (OUTPOST_REPOS vs manifest)"
reconcile_creds_for_host() {
  # echo "user:token" for a bare host, or nothing (public / unknown host).
  local host="$1" entry e_host e_user e_token
  if [[ -n "${GIT_HOST:-}" && "$host" == "$GIT_HOST" && -n "${GIT_USER:-}" && -n "${GIT_TOKEN:-}" ]]; then
    printf '%s:%s' "$GIT_USER" "$GIT_TOKEN"
    return 0
  fi
  local IFS=','
  for entry in ${GIT_CREDENTIALS_EXTRA:-}; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    IFS='|' read -r e_host e_user e_token <<< "$entry"
    if [[ "$e_host" == "$host" ]]; then
      printf '%s:%s' "$e_user" "$e_token"
      return 0
    fi
  done
  return 1
}

# Extract the deployed tag for <app> from a manifest dir (kustomize images
# newTag first — matching update-manifest.sh mode A — else the legacy
# deployment.yaml container image tag).
deployed_tag_for() {
  local app="$1" dir="$2" tag=""
  if [[ -f "$dir/kustomization.yaml" ]]; then
    # images entry whose name ends in /<app> (or equals <app>): next newTag.
    tag=$(awk -v app="$app" '
      /^[[:space:]]*-?[[:space:]]*name:/ {
        n=$NF; sub(/^.*\//,"",n); inblk=(n==app)
      }
      inblk && /newTag:/ { gsub(/["'"'"']/,"",$NF); print $NF; exit }
    ' "$dir/kustomization.yaml")
  fi
  if [[ -z "$tag" && -f "$dir/deployment.yaml" ]]; then
    local ref
    ref=$(awk '/image:/ { print $2; exit }' "$dir/deployment.yaml")
    case "$ref" in *:*) tag="${ref##*:}" ;; esac
  fi
  printf '%s' "$tag"
}

if ! has_cmd git; then
  record FAIL "reconcile.git" "git not installed — reconciliation impossible"
elif [[ -z "${MANIFEST_REPO_URL:-}" ]]; then
  record WARN "reconcile.manifest" "MANIFEST_REPO_URL unset — reconciliation skipped (pre-bootstrap?)"
elif [[ -z "${OUTPOST_REPOS:-}" ]]; then
  # An empty registry means the ultimate judge is BLIND — worth noticing
  # loudly on a full install, but a fresh cluster with zero onboarded apps
  # is legitimate, so WARN not FAIL.
  record WARN "reconcile.repos" "OUTPOST_REPOS empty — nothing to reconcile; onboard apps so the anti-silence layer can see them"
else
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  MANIFEST_DIR="$STATE_DIR/manifest"
  _mhost=$(printf '%s' "$MANIFEST_REPO_URL" | sed -E 's|^[a-z+]+://([^/]+)/.*$|\1|')
  _mauth_url="$MANIFEST_REPO_URL"
  if _c=$(reconcile_creds_for_host "$_mhost"); then
    # SECURITY: _mauth_url embeds a token — never echo/record it.
    _mauth_url=$(printf '%s' "$MANIFEST_REPO_URL" | sed -E "s#^https://#https://${_c}@#")
  fi
  _mb="${MANIFEST_REPO_BRANCH:-main}"
  _m_ok=0
  if [[ -d "$MANIFEST_DIR/.git" ]]; then
    if GIT_TERMINAL_PROMPT=0 git -C "$MANIFEST_DIR" fetch --quiet "$_mauth_url" "$_mb" 2>/dev/null \
       && git -C "$MANIFEST_DIR" reset --hard --quiet FETCH_HEAD 2>/dev/null; then
      _m_ok=1
    fi
  fi
  if [[ "$_m_ok" -eq 0 ]]; then
    rm -rf "$MANIFEST_DIR"
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 --branch "$_mb" "$_mauth_url" "$MANIFEST_DIR" 2>/dev/null; then
      _m_ok=1
    fi
  fi
  if [[ "$_m_ok" -eq 0 ]]; then
    record FAIL "reconcile.manifest" "cannot clone/fetch manifest repo (network? credentials?) — deploy source-of-truth unreachable"
  else
    record PASS "reconcile.manifest" "manifest repo synced ($_mb @ $(git -C "$MANIFEST_DIR" rev-parse --short=7 HEAD 2>/dev/null))"

    # first-seen mismatch timestamps (repo<TAB>epoch), rewritten every run.
    RECON_STATE="$STATE_DIR/reconcile-state"
    RECON_STATE_NEW="$STATE_DIR/reconcile-state.new"
    : > "$RECON_STATE_NEW"
    _now=$(date +%s)

    IFS=',' read -ra _entries <<< "${OUTPOST_REPOS}"
    for _e in "${_entries[@]}"; do
      _e="${_e// /}"
      [[ -z "$_e" ]] && continue
      _url="${_e%%#*}"
      _branch="${OUTPOST_DEPLOY_BRANCH:-main}"
      [[ "$_e" == *"#"* ]] && _branch="${_e#*#}"
      _name="${_url##*/}"
      _name="${_name%.git}"
      _id=$(san_id "$_name")
      _host=$(printf '%s' "$_url" | sed -E 's#^https?://##; s#^git@##; s#[:/].*$##')

      _auth_url="$_url"
      if _c=$(reconcile_creds_for_host "$_host"); then
        _auth_url=$(printf '%s' "$_url" | sed -E "s#^https://#https://${_c}@#")
      fi
      _live=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$_auth_url" "refs/heads/${_branch}" 2>/dev/null | awk '{print $1; exit}')
      if [[ -z "$_live" ]]; then
        record FAIL "reconcile.$_id" "ls-remote FAILED for $_name@$_branch — repo unreachable or token dead (the trigger chain upstream of CI is broken)"
        continue
      fi
      _live7="${_live:0:7}"

      _appdir=$(resolve_manifest_app_dir "$_name" "$MANIFEST_DIR" || true)
      if [[ -z "$_appdir" ]]; then
        record WARN "reconcile.$_id" "no manifest dir for $_name (candidates: $(manifest_app_dir_candidates "$_name" | sort -u | tr '\n' ' ')) — not yet onboarded into the manifest repo?"
        continue
      fi
      _deployed=$(deployed_tag_for "$_name" "$MANIFEST_DIR/$_appdir")
      if [[ -z "$_deployed" ]]; then
        record WARN "reconcile.$_id" "could not extract deployed tag from $_appdir (no images newTag / deployment.yaml image)"
        continue
      fi

      if [[ "$_deployed" == "$_live7" ]]; then
        record PASS "reconcile.$_id" "deployed $_deployed == live HEAD $_live7 ($_branch)"
      else
        # Mismatch: normal for a few minutes after a push (build+sync in
        # flight). FAIL only when it persists past the staleness threshold.
        _first=$(awk -F'\t' -v n="$_name" '$1==n {print $2; exit}' "$RECON_STATE" 2>/dev/null)
        _first="${_first:-$_now}"
        printf '%s\t%s\n' "$_name" "$_first" >> "$RECON_STATE_NEW"
        _agesec=$(( _now - _first ))
        if [[ "$_agesec" -gt "$OUTPOST_STALENESS_THRESHOLD" ]]; then
          record FAIL "reconcile.$_id" "$_name STALE ${_agesec}s: live $_branch HEAD $_live7 but deployed $_deployed — the build→deploy chain is silently broken for THIS repo"
        else
          record WARN "reconcile.$_id" "$_name propagating (${_agesec}s/${OUTPOST_STALENESS_THRESHOLD}s): live $_live7, deployed $_deployed"
        fi
      fi
    done
    mv "$RECON_STATE_NEW" "$RECON_STATE"
    unset _entries _e _url _branch _name _id _host _auth_url _live _live7 _appdir _deployed _first _agesec _now
  fi
fi

# ---- 7. Data layer (host Compose + k3s bridge, real probes) ------------------
# Capability≠liveness: a running container can still refuse auth/connections.
# Probe each service with its OWN protocol via docker exec. Credentials travel
# through the environment (in-container env, or `docker exec -e VAR`
# propagation for redis) — no secret ever appears in a host command line or in
# this output. Refusal = FAIL: 17 apps die with the data layer.
section "7. Data layer (host Compose + infra-bridges bridge)"
if docker_ok; then
  data_probe() {
    # $1 id-suffix, $2 container, remaining args = in-container command
    local id="$1" ctr="$2"; shift 2
    if docker exec "$ctr" "$@" >/dev/null 2>&1; then
      record PASS "data.$id" "live ($ctr probe ok)"
    else
      record FAIL "data.$id" "$ctr probe FAILED — container down or refusing auth (docker logs $ctr --tail 20)"
    fi
  }
  data_probe postgres  postgres  sh -c 'pg_isready -U "$POSTGRES_USER"'
  # Compose passes REDIS_PASSWORD only into redis-server's command line, not
  # the container env — hand it to the probe via `docker exec -e` (env-to-env
  # propagation from verify.sh's sourced .env; never on an argv).
  if docker exec -e REDIS_PASSWORD redis sh -c 'redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG' >/dev/null 2>&1; then
    record PASS "data.redis" "live (redis probe ok)"
  else
    record FAIL "data.redis" "redis probe FAILED — container down or refusing auth (docker logs redis --tail 20)"
  fi
  data_probe rabbitmq  rabbitmq  rabbitmq-diagnostics -q ping
  data_probe manticore manticore sh -c 'wget -q -O- http://127.0.0.1:9308/ >/dev/null 2>&1 || curl -fsS http://127.0.0.1:9308/ >/dev/null 2>&1 || mysql -h127.0.0.1 -P9306 -e "SHOW STATUS" >/dev/null 2>&1'
fi
# Bridge freshness (full mode): pods reach the Compose data layer via
# ExternalName → host.docker.internal → the coredns-custom hosts entry. A WSL
# restart hands the VM a NEW IP; a stale entry strands every app pod at once
# (the recorded #1 whole-site outage mode). The reconciler CronJob rewrites it
# within ~2min — a mismatch here is either that short window or a dead
# reconciler; treat as FAIL so it never fades into background noise.
if [[ "$OUTPOST_MODE" == "full" ]] && kubectl_ok; then
  _node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  _dns_ip=$(kubectl -n kube-system get configmap coredns-custom \
    -o jsonpath='{.data.hostdockerinternal\.server}' 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [[ -z "$_dns_ip" ]]; then
    record FAIL "data.bridge_dns" "coredns-custom hosts entry missing — pods cannot resolve host.docker.internal (rerun bootstrap Phase 8)"
  elif [[ "$_dns_ip" != "$_node_ip" ]]; then
    record FAIL "data.bridge_dns" "bridge DNS stale: coredns-custom → $_dns_ip but node InternalIP is $_node_ip (reconciler heals in ~2min; persistent mismatch = reconciler dead)"
  else
    record PASS "data.bridge_dns" "host.docker.internal → $_node_ip (matches node InternalIP)"
  fi
  if kubectl -n kube-system get cronjob coredns-hosts-reconciler >/dev/null 2>&1; then
    record PASS "data.bridge_reconciler" "coredns-hosts-reconciler CronJob present"
  else
    record FAIL "data.bridge_reconciler" "coredns-hosts-reconciler CronJob missing — next WSL IP drift strands all app pods (kubectl apply -f core/k8s/06-bridges/)"
  fi
  unset _node_ip _dns_ip
fi

# ---- 8. Public ingress ------------------------------------------------------
section "8. Public ingress (Cloudflare edge)"
check_url() {
  local id="$1" url="$2" extra_ok="${3:-}"
  has_cmd curl || { record WARN "$id" "curl missing"; return; }
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null || echo "000")
  # Caller can whitelist extra codes as PASS (a service that answers a bare
  # GET with 4xx still PROVES the path is alive).
  if [[ -n "$extra_ok" ]]; then
    read -ra _extra_codes <<< "$extra_ok"
    for _c in "${_extra_codes[@]:-}"; do
      [[ "$_c" == "$code" ]] && { record PASS "$id" "HTTP $code (reachable)"; return; }
    done
  fi
  case "$code" in
    200|301|302|307|308|401|403) record PASS "$id" "HTTP $code" ;;
    000)                          record FAIL "$id" "no response" ;;
    # 404 = reachable server, no such route (ambiguous, like a bare-GET 4xx) —
    # WARN, not FAIL. A caller that needs a specific path can whitelist its code.
    502|503|504)                  record FAIL "$id" "HTTP $code (origin)" ;;
    *)                            record WARN "$id" "HTTP $code" ;;
  esac
}
# App-facing URLs only — ArgoCD/Tekton/hooks are gone in v0.3.
if [[ "$ROOT_DOMAIN" != "example.com" ]]; then
  check_url "edge.search"   "https://${SEARCH_HOST:-search}.${ROOT_DOMAIN}/"
  check_url "edge.mq"       "https://${MQ_HOST:-mq}.${ROOT_DOMAIN}"
  check_url "edge.registry" "https://${REGISTRY_SUBDOMAIN:-registry}.${ROOT_DOMAIN}/v2/"
else
  record WARN "edge.skipped" "ROOT_DOMAIN unset"
fi

fi  # end full-mode-only sections

# ---- 9. Dead-man switch self-check ------------------------------------------
# The watchdog must be watched once too: if the timer is dead, every other
# FAIL in this script can go unnoticed for days (the 9-day lesson, applied
# to the alarm itself). linux/wsl2 full mode only — macOS has no systemd.
if [[ "$OUTPOST_MODE" == "full" ]]; then
  case "$SK_OS" in
    linux|wsl2)
      section "9. Dead-man switch (outpost-verify.timer)"
      if has_cmd systemctl; then
        if [[ "$(systemctl is-enabled outpost-verify.timer 2>/dev/null)" == "enabled" ]]; then
          record PASS "watchdog.timer" "outpost-verify.timer enabled"
          _svc_result=$(systemctl show outpost-verify.service -p Result --value 2>/dev/null || echo "")
          # Result=success also covers "never ran yet" (empty → success default).
          if [[ -z "$_svc_result" || "$_svc_result" == "success" ]]; then
            record PASS "watchdog.last_run" "last outpost-verify.service result: ${_svc_result:-not-run-yet}"
          else
            record FAIL "watchdog.last_run" "outpost-verify.service last Result=$_svc_result — the watchdog itself is failing (journalctl -u outpost-verify.service)"
          fi
          unset _svc_result
        else
          record FAIL "watchdog.timer" "outpost-verify.timer NOT enabled — no dead-man switch; re-run bootstrap phase 8"
        fi
      else
        record WARN "watchdog.timer" "systemctl unavailable — cannot check the verify timer"
      fi
      ;;
  esac
fi

# ---- 10. Credentials hygiene ------------------------------------------------
section "10. Credentials hygiene"
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
