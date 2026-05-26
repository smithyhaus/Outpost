#!/usr/bin/env bash
# =============================================================================
# install.sh — one-shot Outpost installer.
# -----------------------------------------------------------------------------
# Designed for the canonical "no clone required" install path:
#
#   curl -fsSL https://raw.githubusercontent.com/smithyhaus/Outpost/main/install.sh \
#     | ROOT_DOMAIN=mycompany.com \
#       CF_TUNNEL_TOKEN=xxx \
#       MANIFEST_REPO_URL=https://github.com/me/manifests \
#       APP_REPO=https://github.com/me/scm-mcp \
#       bash
#
# Works equally as a local `bash install.sh` from a checkout. Idempotent:
# safe to re-run — already-cloned trees are `git pull`-ed, an existing .env
# is preserved unless OUTPOST_FORCE_ENV=1.
#
# What it does, in order:
#   1. Preflight: bash 4+ ? git ? docker ? On macOS/Linux/WSL2 ?
#   2. Clone (or update) the infras repo to OUTPOST_DIR (default: ~/outpost).
#   3. Render .env from env vars provided by the caller (no interactive prompt
#      when stdin is a pipe — required for `curl | bash`). Local mode needs
#      zero env; full mode requires the documented six.
#   4. Run `bash bootstrap.sh` (the existing installer entrypoint).
#   5. If APP_REPO is set, run `outpost onboard "$APP_REPO"` to register the
#      caller's application in the new infras instance.
#
# Environment variables the caller may set:
#
#   OUTPOST_DIR             where to place the infras checkout (default ~/outpost)
#   OUTPOST_GIT_URL         repo URL to clone (default upstream)
#   OUTPOST_GIT_REF         branch/tag/SHA to check out (default main)
#   OUTPOST_MODE            local | full  (default: full if ROOT_DOMAIN set, else local)
#   OUTPOST_FORCE_ENV=1     overwrite an existing .env (otherwise it is kept)
#   OUTPOST_SKIP_BOOTSTRAP=1  do step 1-3 only; useful for offline staging
#   APP_REPO                optional git URL of an app to onboard after bootstrap
#
#   ROOT_DOMAIN, CF_TUNNEL_TOKEN, GIT_USER, GIT_TOKEN, MANIFEST_REPO_URL,
#   GIT_WEBHOOK_SECRET, REGISTRY_PLUGIN, GIT_PROVIDER_PLUGIN, ...
#       — any standard outpost var is passed through verbatim into .env.
# =============================================================================
set -euo pipefail

OUTPOST_GIT_URL="${OUTPOST_GIT_URL:-https://github.com/smithyhaus/Outpost.git}"
OUTPOST_GIT_REF="${OUTPOST_GIT_REF:-main}"
OUTPOST_DIR="${OUTPOST_DIR:-$HOME/outpost}"

# Coloring (only when stdout is a tty — avoids ANSI noise in CI logs).
if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YELLOW=$'\e[33m'
  C_DIM=$'\e[2m';    C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_DIM=''; C_BOLD=''; C_RESET=''
fi
log()  { printf '%s\n' "${C_BOLD}[outpost-install]${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
preflight() {
  log "preflight"
  command -v git >/dev/null 2>&1   || die "git is required (install: brew/apt/dnf install git)"
  command -v bash >/dev/null 2>&1  || die "bash is required"
  command -v docker >/dev/null 2>&1 || die "docker is required (https://docs.docker.com/get-docker/)"
  if ! docker info >/dev/null 2>&1; then
    warn "docker daemon not reachable — bootstrap will fail when it tries to compose up"
  fi
  case "$(uname -s)" in
    Darwin|Linux) : ;;
    *) die "unsupported OS: $(uname -s) — outpost targets macOS, Linux, and WSL2" ;;
  esac
}

# --- clone or update ---------------------------------------------------------
fetch_repo() {
  if [[ "${OUTPOST_SKIP_FETCH:-0}" == "1" ]]; then
    warn "OUTPOST_SKIP_FETCH=1 — skipping clone/update (assuming $OUTPOST_DIR is staged)"
    [[ -d "$OUTPOST_DIR" ]] || die "OUTPOST_SKIP_FETCH=1 but $OUTPOST_DIR does not exist"
    return 0
  fi
  if [[ -d "$OUTPOST_DIR/.git" ]]; then
    log "updating existing checkout at $OUTPOST_DIR"
    # If the checkout doesn't have an `origin` remote (e.g. it was hand-staged
    # rather than freshly cloned), skip the fetch and just trust the on-disk
    # state. Treat as a soft warning, not a hard fail.
    if git -C "$OUTPOST_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$OUTPOST_DIR" fetch --quiet origin "$OUTPOST_GIT_REF" || \
        warn "git fetch failed — proceeding with on-disk state"
      # `pull --ff-only` so local edits abort the install rather than vanish.
      if ! git -C "$OUTPOST_DIR" pull --ff-only --quiet origin "$OUTPOST_GIT_REF" 2>/dev/null; then
        warn "fast-forward pull skipped — using on-disk state (resolve drift if needed)"
      fi
    else
      warn "no 'origin' remote in $OUTPOST_DIR — using on-disk state as-is"
    fi
    ok "checkout ready"
  elif [[ -e "$OUTPOST_DIR" ]]; then
    die "$OUTPOST_DIR exists but is not a git checkout — remove it or set OUTPOST_DIR= to a different path"
  else
    log "cloning $OUTPOST_GIT_URL → $OUTPOST_DIR (ref: $OUTPOST_GIT_REF)"
    git clone --branch "$OUTPOST_GIT_REF" --depth 1 --quiet "$OUTPOST_GIT_URL" "$OUTPOST_DIR" \
      || die "git clone failed: $OUTPOST_GIT_URL @ $OUTPOST_GIT_REF"
    ok "cloned"
  fi
}

# --- .env rendering ---------------------------------------------------------
# Mode auto-detection: if ROOT_DOMAIN is set in the caller's env, default to
# full mode; otherwise local. Caller may override by exporting OUTPOST_MODE.
render_env() {
  local env_file="$OUTPOST_DIR/.env"
  local example="$OUTPOST_DIR/.env.example"

  if [[ -z "${OUTPOST_MODE:-}" ]]; then
    if [[ -n "${ROOT_DOMAIN:-}" ]]; then OUTPOST_MODE=full; else OUTPOST_MODE=local; fi
  fi
  log "mode: $OUTPOST_MODE"

  if [[ "$OUTPOST_MODE" == "full" ]]; then
    local missing=()
    [[ -z "${ROOT_DOMAIN:-}" ]]        && missing+=(ROOT_DOMAIN)
    [[ -z "${CF_TUNNEL_TOKEN:-}" ]]    && missing+=(CF_TUNNEL_TOKEN)
    [[ -z "${GIT_USER:-}" ]]           && missing+=(GIT_USER)
    [[ -z "${GIT_TOKEN:-}" ]]          && missing+=(GIT_TOKEN)
    [[ -z "${MANIFEST_REPO_URL:-}" ]]  && missing+=(MANIFEST_REPO_URL)
    if (( ${#missing[@]} > 0 )); then
      die "full mode requires: ${missing[*]}
  Pass them as env vars, e.g.:
    curl -fsSL ... | ROOT_DOMAIN=... CF_TUNNEL_TOKEN=... GIT_USER=... GIT_TOKEN=... MANIFEST_REPO_URL=... bash"
    fi
  fi

  if [[ -f "$env_file" && "${OUTPOST_FORCE_ENV:-0}" != "1" ]]; then
    warn "$env_file already exists — keeping it (set OUTPOST_FORCE_ENV=1 to overwrite)"
    return 0
  fi

  log "rendering $env_file"
  # Start from the shipped template; then for every var the caller exported
  # that matches a line `^<KEY>=`, overwrite that line. Unknown caller vars
  # are appended to the bottom. This keeps the documented .env structure +
  # comments intact while honoring any caller override.
  cp "$example" "$env_file"
  # Always set OUTPOST_MODE explicitly (template defaults to local).
  _set_env_kv "$env_file" OUTPOST_MODE "$OUTPOST_MODE"
  # The complete set of vars the template advertises. Pulled live from
  # .env.example so we never drift if the template grows.
  local known
  known=$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$example" | tr -d '=' | sort -u)
  local k v
  for k in $known; do
    if [[ -n "${!k+x}" ]]; then  # caller exported this variable
      v="${!k}"
      _set_env_kv "$env_file" "$k" "$v"
    fi
  done
  ok "$env_file written"
}

# Replace (or append) a KEY=VALUE pair in a .env file. POSIX-portable.
_set_env_kv() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    {
      if ($0 ~ "^" k "=") { printf "%s=%s\n", k, v; done = 1 }
      else                { print }
    }
    END { if (!done) printf "%s=%s\n", k, v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- bootstrap ---------------------------------------------------------------
run_bootstrap() {
  if [[ "${OUTPOST_SKIP_BOOTSTRAP:-0}" == "1" ]]; then
    warn "OUTPOST_SKIP_BOOTSTRAP=1 — skipping bootstrap.sh (env rendered, repo cloned)"
    return 0
  fi
  log "running bootstrap (this may take 2–10 minutes)"
  ( cd "$OUTPOST_DIR" && bash bootstrap.sh )
  ok "bootstrap complete"
}

# --- optional app onboarding -------------------------------------------------
onboard_app() {
  if [[ -z "${APP_REPO:-}" ]]; then
    return 0
  fi
  log "onboarding app: $APP_REPO"
  ( cd "$OUTPOST_DIR" && bash scripts/outpost onboard "$APP_REPO" )
  ok "app onboarded"
}

# --- summary -----------------------------------------------------------------
summary() {
  echo ""
  echo "${C_BOLD}═══════════════════════════════════════════════════════════════════${C_RESET}"
  echo "${C_GREEN}✓ Outpost ready${C_RESET}"
  echo "${C_BOLD}═══════════════════════════════════════════════════════════════════${C_RESET}"
  echo ""
  echo "  Checkout:    $OUTPOST_DIR"
  echo "  Mode:        $OUTPOST_MODE"
  [[ -n "${APP_REPO:-}" ]] && echo "  Onboarded:   $APP_REPO"
  echo ""
  echo "  ${C_DIM}Next steps:${C_RESET}"
  echo "    cd $OUTPOST_DIR"
  echo "    cat INFRA.md            # connection strings + passwords"
  echo "    bash verify.sh          # full stack health check"
  echo "    bash scripts/outpost    # daily CLI"
  echo ""
}

main() {
  preflight
  fetch_repo
  render_env
  run_bootstrap
  onboard_app
  summary
}

main "$@"
