#!/usr/bin/env bash
# =============================================================================
# Outpost / platform/lib/portable.sh
# -----------------------------------------------------------------------------
# Cross-platform helpers used by bootstrap.sh, verify.sh and platform/<os>.sh.
# Source-only — never executed directly.
#
# Responsibilities:
#   - detect_os                  → exports SK_OS in {macos, linux, wsl2}
#   - render_template            → envsubst with strict ${VAR} residue check
#   - portable_sed_i             → in-place sed across BSD (macOS) and GNU
#   - portable_stat_perm         → file mode ("644") across BSD and GNU
#   - require_cmd                → fail fast with helpful message
#   - log / ok / warn / err / phase   → consistent UX
# =============================================================================

# ---- ANSI colour helpers (NO_COLOR-aware) -----------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  SK_C_RESET='\033[0m'; SK_C_BOLD='\033[1m'
  SK_C_BLUE='\033[34m'; SK_C_GREEN='\033[32m'
  SK_C_YELLOW='\033[33m'; SK_C_RED='\033[31m'; SK_C_DIM='\033[2m'
else
  SK_C_RESET=''; SK_C_BOLD=''
  SK_C_BLUE=''; SK_C_GREEN=''
  SK_C_YELLOW=''; SK_C_RED=''; SK_C_DIM=''
fi
# SK_C_DIM is reserved for future use (e.g. de-emphasized timestamps in
# verbose mode); silence shellcheck SC2034 about it being currently unused.
# shellcheck disable=SC2034
: "${SK_C_DIM:=}"

log()   { echo -e "${SK_C_BLUE}${SK_C_BOLD}[INFO]${SK_C_RESET} $*"; }
ok()    { echo -e "${SK_C_GREEN}${SK_C_BOLD}[ OK ]${SK_C_RESET} $*"; }
warn()  { echo -e "${SK_C_YELLOW}${SK_C_BOLD}[WARN]${SK_C_RESET} $*"; }
err()   { echo -e "${SK_C_RED}${SK_C_BOLD}[ERR ]${SK_C_RESET} $*" >&2; }
phase() { echo -e "\n${SK_C_BOLD}═══════ $* ═══════${SK_C_RESET}\n"; }

# ---- OS detection -----------------------------------------------------------
# Sets SK_OS to one of: macos | linux | wsl2
# WSL2 is a Linux kernel running under Windows; we detect it from /proc/version.
detect_os() {
  local uname_s
  uname_s=$(uname -s 2>/dev/null || echo "unknown")
  case "$uname_s" in
    Darwin)
      SK_OS="macos"
      ;;
    Linux)
      if [[ -r /proc/version ]] && grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        SK_OS="wsl2"
      else
        SK_OS="linux"
      fi
      ;;
    *)
      err "Unsupported OS: $uname_s"
      err "Outpost supports macOS, Linux, and WSL2 (Win11+)"
      return 1
      ;;
  esac
  export SK_OS
}

# ---- Portable sed -i --------------------------------------------------------
# BSD sed (macOS) requires `-i ''`; GNU sed accepts `-i` with no arg.
# Usage: portable_sed_i 's#A#B#g' file
portable_sed_i() {
  local expr="$1"; shift
  if [[ "${SK_OS:-}" == "macos" ]]; then
    sed -i '' "$expr" "$@"
  else
    sed -i "$expr" "$@"
  fi
}

# ---- Portable stat (file permissions) ---------------------------------------
# Returns the octal mode (e.g. "644"). Empty string on failure.
portable_stat_perm() {
  local f="$1"
  if [[ "${SK_OS:-}" == "macos" ]]; then
    stat -f '%Lp' "$f" 2>/dev/null || echo ""
  else
    stat -c '%a' "$f" 2>/dev/null || echo ""
  fi
}

# ---- Portable readlink -f ---------------------------------------------------
# BSD readlink does not support -f; fall back to a python/perl one-liner.
portable_realpath() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target"
  elif [[ "${SK_OS:-}" == "macos" ]]; then
    perl -MCwd -e 'print Cwd::abs_path(shift)' "$target"
  else
    readlink -f "$target"
  fi
}

# ---- Required-command helper ------------------------------------------------
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Missing required command: $c"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || return 1
}

# ---- render_template (CRITICAL — anti-silent-failure) -----------------------
# Strict template renderer with ${VAR} residue detection.
#
# WHY this matters:
#   envsubst silently emits empty strings for unset variables. Manifests then
#   pass `kubectl apply` validation but reference empty hostnames/secrets,
#   causing puzzling runtime breakage.
#
# Contract:
#   render_template <input> <output>
#     - Renders <input> via envsubst into <output>.
#     - If any ${...} placeholder remains in <output>, deletes it and exits 1.
#     - Returns 0 on success.
#
# Notes:
#   - Use $$VAR in templates if you need a literal "$VAR" in output (envsubst
#     does NOT interpret double-dollar escaping; instead, list the substitutable
#     vars explicitly with the second-arg form below).
render_template() {
  local src="$1" dst="$2"
  if [[ ! -r "$src" ]]; then
    err "render_template: source not readable: $src"
    return 1
  fi

  if ! command -v envsubst >/dev/null 2>&1; then
    err "render_template: envsubst not found (install gettext/gettext-base)"
    return 1
  fi

  # Anti-silent-failure (SKILL.md invariant #10): every ${VAR} in the source
  # MUST be set in the current environment. We check BEFORE envsubst because
  # envsubst silently replaces unset vars with empty strings — the post-sub
  # grep would never find them.
  #
  # Only enforce on the ${VAR}/${ VAR } braced form. Bare $VAR is too easy
  # to mistake for shell text inside YAML; force authors to use ${VAR}.
  local missing=()
  local v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if [[ -z "${!v+x}" ]]; then
      missing+=("$v")
    fi
  done < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$src" | sed 's/^\${//; s/}$//' | sort -u)

  if (( ${#missing[@]} > 0 )); then
    err "render_template: unresolved placeholders in $src: \${${missing[*]}}"
    err "Hint: ensure these variables are exported in the current shell."
    return 1
  fi

  envsubst < "$src" > "$dst"
  return 0
}

# ---- render_template_only (targeted substitution) --------------------------
# Like render_template, but only substitutes ${VAR} placeholders for vars in
# the allowlist. All other ${VAR} placeholders are preserved literally —
# essential for templates that mix install-time vars with runtime placeholders
# (e.g. notification body templates carrying ${NOTIFY_APP} for the notify-task
# to render at fanout time).
#
# Strict check still applies to the allowlist: a listed var that appears in
# the source MUST be set in the env, otherwise abort. Unlisted ${VAR} patterns
# pass through untouched.
#
# Usage:
#   render_template_only <src> <dst> "VAR1 VAR2 VAR3"
render_template_only() {
  local src="$1" dst="$2" varlist="$3"
  if [[ ! -r "$src" ]]; then
    err "render_template_only: source not readable: $src"
    return 1
  fi
  if ! command -v envsubst >/dev/null 2>&1; then
    err "render_template_only: envsubst not found (install gettext/gettext-base)"
    return 1
  fi

  # Strict residue check: every allowlist var that appears in the source
  # must be set. Unlisted placeholders are intentionally not checked.
  local missing=()
  local v
  for v in $varlist; do
    if grep -qE "\\\$\\{${v}\\}" "$src"; then
      if [[ -z "${!v+x}" ]]; then
        missing+=("$v")
      fi
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    err "render_template_only: unresolved placeholders in $src: \${${missing[*]}}"
    err "Hint: ensure these variables are exported in the current shell."
    return 1
  fi

  # Build envsubst targeted substitution list: "$VAR1 $VAR2 ...".
  local sublist=""
  for v in $varlist; do
    sublist="$sublist \$$v"
  done

  # shellcheck disable=SC2086 # sublist is intentionally word-split
  envsubst "$sublist" < "$src" > "$dst"
  return 0
}

# ---- render_apply -----------------------------------------------------------
# render a template + kubectl apply. Used by bootstrap.sh in many places to
# replace the historical multi-sed-pipe pattern.
render_apply() {
  local src="$1"
  local tmp
  tmp=$(mktemp)
  # We DO want $tmp to expand at trap-define time (each render_apply call
  # gets its own scratch path). Single-quote the rest so shellcheck SC2064
  # is happy without changing semantics.
  # shellcheck disable=SC2064
  trap 'rm -f "'"$tmp"'"' RETURN
  if ! render_template "$src" "$tmp"; then
    return 1
  fi
  kubectl apply -f "$tmp"
}

# ---- Confirmation helper ----------------------------------------------------
confirm() {
  local prompt="${1:-Continue?}"
  local ans=""
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- Random password generator ----------------------------------------------
gen_password() {
  # 32 chars, URL-safe alphanumeric subset
  openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-32
}
