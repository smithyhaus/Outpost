#!/usr/bin/env bash
# =============================================================================
# Outpost / doctor.sh
# -----------------------------------------------------------------------------
# Ex-ante preflight. Surfaces the failure modes that otherwise only appear
# half-way through bootstrap.sh — port collisions, Docker down, an unresolved
# domain, a malformed Cloudflare token, an unreachable build image, blocked
# build egress.
#
# Read-only / idempotent: never writes a file; `docker run --rm` only.
#
# Usage:
#   ./doctor.sh                   coloured human output
#   ./doctor.sh --json            machine-readable JSON (AI parsable)
#   ./doctor.sh --quiet           summary line only
#   ./doctor.sh --egress h1,h2    additionally probe build egress to those hosts
#
# Exit codes:
#   0  all PASS
#   1  any FAIL
#   2  any WARN (no FAIL)
#
# Mode awareness:
#   In OUTPOST_MODE=local only the Compose-layer preconditions are checked
#   (tooling, host ports, disk). Domain / Cloudflare / k3s-networking checks
#   are full-mode only.
#
# JSON schema is locked at tests/schema/doctor-output.schema.json.
# =============================================================================
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }

# shellcheck source=platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"
# shellcheck source=platform/lib/doctor-checks.sh
source "${INFRA_ROOT}/platform/lib/doctor-checks.sh"

# ---- args -------------------------------------------------------------------
MODE="human"
EGRESS_HOSTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)   MODE="json";  shift ;;
    --quiet)  MODE="quiet"; shift ;;
    --egress) IFS=',' read -ra EGRESS_HOSTS <<< "${2:-}"
              # shift past the flag, then past its value if one was given.
              # `shift 2` would be a no-op (count out of range) when --egress
              # is the last arg, leaving $# unchanged → arg-loop never ends.
              shift; [[ $# -gt 0 ]] && shift ;;
    *)        shift ;;
  esac
done

# Load env best-effort — doctor MUST work before bootstrap (no .env yet).
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi
ROOT_DOMAIN="${ROOT_DOMAIN:-example.com}"
OUTPOST_MODE="${OUTPOST_MODE:-local}"
case "$OUTPOST_MODE" in
  local|full) ;;
  *) OUTPOST_MODE="unknown" ;;
esac
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"

detect_os 2>/dev/null || SK_OS="unknown"

# ---- result accumulation ----------------------------------------------------
PASS_CNT=0; WARN_CNT=0; FAIL_CNT=0
RESULTS=()

# record <status> <id> <detail> [fix_hint]
record() {
  local status="$1" id="$2" detail="$3" fix_hint="${4:-}"
  RESULTS+=("$status|$id|$detail|$fix_hint")
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
    if [[ -n "$fix_hint" && "$status" != "PASS" ]]; then
      echo -e "       ${SK_C_DIM}↳ fix: $fix_hint${SK_C_RESET}"
    fi
  fi
}

section() {
  if [[ "$MODE" == "human" ]]; then
    echo ""
    echo -e "${SK_C_BOLD}═══ $1 ═══${SK_C_RESET}"
  fi
}

has_cmd()   { command -v "$1" >/dev/null 2>&1; }
docker_ok() { docker info >/dev/null 2>&1; }

# Port → Compose service name (bash 3.2-safe; no associative arrays).
port_svc() {
  case "$1" in
    5432) echo "postgres" ;;
    6379) echo "redis" ;;
    5672) echo "rabbitmq" ;;
    9308) echo "manticore" ;;
    *)    echo "?" ;;
  esac
}

# ---- 1. Tooling -------------------------------------------------------------
section "1. Tooling"
if [[ "$OUTPOST_MODE" == "full" ]]; then
  REQUIRED_TOOLS=(docker openssl envsubst curl kubectl helm git)
else
  REQUIRED_TOOLS=(docker openssl envsubst curl)
fi
for cmd in "${REQUIRED_TOOLS[@]}"; do
  if has_cmd "$cmd"; then
    record PASS "tool.$cmd" "found at $(command -v "$cmd")" ""
  else
    record FAIL "tool.$cmd" "not installed" \
      "install $cmd — e.g. 'brew install $cmd' (macOS) or 'apt-get install $cmd' (Debian/Ubuntu)"
  fi
done
if docker_ok; then
  record PASS "docker.daemon" "running" ""
else
  record FAIL "docker.daemon" "not running" \
    "start Docker — open Docker Desktop, or 'sudo systemctl start docker' on Linux"
fi
if docker compose version >/dev/null 2>&1; then
  record PASS "docker.compose_v2" "available" ""
else
  record FAIL "docker.compose_v2" "missing" \
    "install the docker compose v2 plugin (e.g. 'apt-get install docker-compose-plugin')"
fi
record PASS "platform.os" "${SK_OS:-unknown}" ""
record PASS "platform.mode" "OUTPOST_MODE=$OUTPOST_MODE" ""

# ---- 2. Host ports ----------------------------------------------------------
# Compose host-binds these 4 ports (core/compose/docker-compose.yml). A port
# already held by something else makes Phase 4 die with a confusing
# "Bind for 0.0.0.0:<p> failed" — catch it here instead.
section "2. Host ports"
for port in 5432 6379 5672 9308; do
  svc="$(port_svc "$port")"
  if [[ "$(doctor_port_state "$port")" == "free" ]]; then
    record PASS "port.$port" "free (for the $svc container)" ""
  else
    holder="$(doctor_port_holder "$port")"
    record FAIL "port.$port" "in use${holder:+ by $holder}" \
      "stop whatever holds port $port — it collides with the $svc container; 'lsof -iTCP:$port -sTCP:LISTEN' to find it"
  fi
done

# ---- 3. Disk ----------------------------------------------------------------
# Best-effort, WARN-only — on macOS Docker Desktop the data lives in a VM that
# the host's df cannot see, so this degrades to a WARN rather than a FAIL.
section "3. Disk"
if docker_ok; then
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")"
  if [[ -n "$docker_root" ]] && df -Pk "$docker_root" >/dev/null 2>&1; then
    free_kb="$(df -Pk "$docker_root" 2>/dev/null | awk 'NR==2{print $4}')"
    free_gb=$(( ${free_kb:-0} / 1024 / 1024 ))
    if [[ "$free_gb" -ge 5 ]]; then
      record PASS "disk.docker" "${free_gb}G free at $docker_root" ""
    else
      record WARN "disk.docker" "only ${free_gb}G free at $docker_root" \
        "low disk where Docker stores data — Postgres/Manticore fill it fast; run 'docker system prune'"
    fi
  else
    record WARN "disk.docker" "could not determine Docker disk free space" ""
  fi
else
  record WARN "disk.docker" "skipped — docker not running" ""
fi

# ---- 4-5. Full-mode-only preconditions --------------------------------------
if [[ "$OUTPOST_MODE" == "full" ]]; then

# ---- 4. Domain & Cloudflare -------------------------------------------------
section "4. Domain & Cloudflare"
if [[ "$ROOT_DOMAIN" == "example.com" ]]; then
  record WARN "dns.root_domain" "ROOT_DOMAIN still example.com" \
    "set ROOT_DOMAIN in .env to your real domain before a full-mode bootstrap"
elif [[ "$(doctor_dns_state "$ROOT_DOMAIN")" == "ok" ]]; then
  record PASS "dns.root_domain" "$ROOT_DOMAIN resolves" ""
else
  record FAIL "dns.root_domain" "$ROOT_DOMAIN does not resolve" \
    "move ROOT_DOMAIN's nameservers to Cloudflare and wait for DNS propagation"
fi
if [[ "$(doctor_cf_token_state "$CF_TUNNEL_TOKEN")" == "valid" ]]; then
  record PASS "cf.token" "CF_TUNNEL_TOKEN looks well-formed" ""
else
  record FAIL "cf.token" "CF_TUNNEL_TOKEN missing or malformed" \
    "re-copy the tunnel token from the Cloudflare Zero Trust dashboard (Networks -> Tunnels)"
fi

# ---- 5. Container networking & build image ---------------------------------
section "5. Container networking & build image"
if docker_ok; then
  if docker run --rm --add-host=host.docker.internal:host-gateway alpine:3.20 \
       getent hosts host.docker.internal >/dev/null 2>&1; then
    record PASS "net.host_docker_internal" "resolvable from containers" ""
  else
    record FAIL "net.host_docker_internal" "not resolvable from containers" \
      "k3s pods reach the data layer via host.docker.internal — check Docker's host-gateway support"
  fi
  if docker manifest inspect gcr.io/kaniko-project/executor:v1.5.1 >/dev/null 2>&1; then
    record PASS "image.kaniko" "kaniko build image reachable" ""
  else
    record FAIL "image.kaniko" "cannot reach the kaniko build image" \
      "check network / Docker registry mirror — the Tekton build step needs gcr.io/kaniko-project/executor:v1.5.1"
  fi
else
  record WARN "net.host_docker_internal" "skipped — docker not running" ""
  record WARN "image.kaniko" "skipped — docker not running" ""
fi

fi  # end full-mode-only

# ---- 6. Build egress (opt-in via --egress) ----------------------------------
section "6. Build egress"
if [[ "${#EGRESS_HOSTS[@]}" -eq 0 ]]; then
  record PASS "egress.skipped" "no --egress hosts given" ""
else
  for h in "${EGRESS_HOSTS[@]}"; do
    [[ -z "$h" ]] && continue
    # Sanitise to the schema's id charset [a-z0-9._-]; any other char → '_'
    # (a host like "registry.local:5000" must not produce an off-pattern id).
    id_h="$(printf '%s' "$h" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_')"
    if curl -sS -o /dev/null --max-time 8 "https://$h" 2>/dev/null \
       || curl -sS -o /dev/null --max-time 8 "$h" 2>/dev/null; then
      record PASS "egress.$id_h" "reachable" ""
    else
      record FAIL "egress.$id_h" "unreachable" \
        "build pods will need to reach $h — unreachable from this machine now; check firewall/DNS/proxy"
    fi
  done
fi

# ---- Output -----------------------------------------------------------------
json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

if [[ "$MODE" == "json" ]]; then
  printf '{"schema_version":"1","summary":{"pass":%d,"warn":%d,"fail":%d,"os":"%s","mode":"%s"},"checks":[' \
    "$PASS_CNT" "$WARN_CNT" "$FAIL_CNT" "${SK_OS:-unknown}" "$OUTPOST_MODE"
  first=1
  for r in "${RESULTS[@]}"; do
    [[ $first -eq 0 ]] && printf ','
    first=0
    status="${r%%|*}"; rest="${r#*|}"
    id="${rest%%|*}"; rest="${rest#*|}"
    detail="${rest%%|*}"; fix_hint="${rest#*|}"
    printf '{"status":"%s","id":"%s","detail":"%s","fix_hint":"%s"}' \
      "$status" "$(json_esc "$id")" "$(json_esc "$detail")" "$(json_esc "$fix_hint")"
  done
  printf ']}\n'
else
  # human + quiet both get the summary; per-check lines print only in human mode.
  echo ""
  echo -e "${SK_C_BOLD}═══ Summary ═══${SK_C_RESET}"
  echo -e "${SK_C_GREEN}PASS${SK_C_RESET}: $PASS_CNT  ${SK_C_YELLOW}WARN${SK_C_RESET}: $WARN_CNT  ${SK_C_RED}FAIL${SK_C_RESET}: $FAIL_CNT  (OS: ${SK_OS:-unknown}, mode: $OUTPOST_MODE)"
fi

[[ $FAIL_CNT -gt 0 ]] && exit 1
[[ $WARN_CNT -gt 0 ]] && exit 2
exit 0
