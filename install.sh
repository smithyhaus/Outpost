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
#   1. Preflight: git/bash present? OS supported? Docker present — auto-installed
#      on Linux/WSL2 via get.docker.com if missing (macOS → Docker Desktop).
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
  command -v git >/dev/null 2>&1   || die "git is required (install: apt/dnf/brew install git)"
  command -v bash >/dev/null 2>&1  || die "bash is required"
  case "$(uname -s)" in
    Darwin|Linux) : ;;
    *) die "unsupported OS: $(uname -s) — outpost targets macOS, Linux, and WSL2" ;;
  esac
  ensure_docker
}

# Ensure a working Docker engine. On Linux/WSL2, auto-install via the official
# get.docker.com script when absent — this is what lets the canonical
# `curl … | bash` one-liner work from a bare WSL2 with no manual prep. On macOS
# we cannot script Docker Desktop, so we point the user at its installer.
#
# Note: this intentionally duplicates a little of platform/lib/linux.sh —
# preflight runs BEFORE the repo is cloned, so that library isn't on disk yet.
ensure_docker() {
  if docker info >/dev/null 2>&1; then ok "docker ready"; return 0; fi

  # Decide per-OS BEFORE touching the engine: macOS can't be scripted (point the
  # user at Docker Desktop), anything non-Linux is unsupported.
  case "$(uname -s)" in
    Darwin) die "Docker Desktop is required on macOS — install it first:
  https://docs.docker.com/desktop/install/mac-install/" ;;
    Linux)  ;;
    *)      die "unsupported OS: $(uname -s)" ;;
  esac

  # Linux/WSL2 needs a NATIVE engine: a dockerd this distro's systemd manages.
  # `dockerd` present is the real signal — NOT a bare `docker` on PATH, which is
  # often just a Docker Desktop WSL-integration shim (/usr/bin/docker -> /mnt/wsl/
  # docker-desktop/…) or a dangling leftover after Desktop was uninstalled. A shim
  # gives no local daemon, no docker.service and no systemd autostart, so when
  # dockerd is missing we clear any shim and install the real engine. (This is the
  # class of failure where the old "group not active" hint fired misleadingly.)
  if command -v dockerd >/dev/null 2>&1; then
    # Native engine present but daemon down — try to bring it up.
    sudo systemctl enable --now docker 2>/dev/null || sudo service docker start 2>/dev/null || true
  else
    _purge_desktop_docker_shim
    _install_docker_engine
  fi

  if docker info >/dev/null 2>&1; then ok "docker ready"; return 0; fi
  # Daemon still unreachable in THIS shell. Right after a fresh install the usual
  # cause is the 'docker' group not being active yet — worth failing on with a
  # clear fix *before* we actually bootstrap. For env-render-only runs
  # (OUTPOST_SKIP_BOOTSTRAP=1) or other transient cases, warn and let bootstrap
  # bring the daemon up — matching the installer's older, lenient behavior.
  if id -nG "$USER" 2>/dev/null | grep -qw docker && [[ "${OUTPOST_SKIP_BOOTSTRAP:-0}" != "1" ]]; then
    warn "Docker engine is installed but the 'docker' group is not active in this shell yet."
    die  "Open a NEW shell (or run 'newgrp docker'), then re-run the same install command — it is idempotent."
  fi
  warn "docker daemon not reachable yet — bootstrap will try to start it"
  return 0
}

# Remove a Docker Desktop WSL-integration shim (or its dangling leftover) so the
# native engine can own /usr/bin/docker. Only ever removes a symlink that points
# into Docker Desktop's mount or no longer resolves — never a real binary.
_purge_desktop_docker_shim() {
  local d=/usr/bin/docker
  [[ -L "$d" ]] || return 0
  local link; link="$(readlink "$d" 2>/dev/null || true)"
  if [[ "$link" == *docker-desktop* || ! -e "$d" ]]; then
    log "removing Docker Desktop docker shim: $d -> ${link:-?}"
    sudo rm -f "$d" 2>/dev/null || true
    hash -r 2>/dev/null || true
  fi
}

# Install the Docker engine on Linux/WSL2. Isolated so tests can stub it.
_install_docker_engine() {
  log "Installing native Docker engine via get.docker.com (Linux/WSL2)…"
  curl -fsSL https://get.docker.com | sh || die "docker install failed"
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  sudo systemctl enable --now docker 2>/dev/null || sudo service docker start 2>/dev/null || true
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

# Run only when actually invoked (executed, or piped via `curl | bash`) — not
# when a test harness sources this file. Tests set OUTPOST_INSTALL_SOURCE_ONLY=1.
if [[ -z "${OUTPOST_INSTALL_SOURCE_ONLY:-}" ]]; then
  main "$@"
fi
