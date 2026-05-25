# shellcheck shell=bash
# =============================================================================
# Outpost / platform/lib/onboard-lib.sh
# -----------------------------------------------------------------------------
# Pure helpers for the v0.4 onboard primitives — `outpost db create`,
# `outpost seal-from-template`, `outpost manifest scaffold`. Source-only:
# never executed directly. Every function here is side-effect-free except
# onboard_render_subst (which writes its <dst> file); all are unit-tested by
# tests/bats/onboard-lib.bats — same rationale as doctor-checks.sh /
# cel-helpers.sh (testable logic lives in a lib, not inline in the CLI).
#
# Governed by ADR 0002 (docs/decisions/0002-onboarding-primitives-in-platform.md):
# these helpers carry generic onboarding *mechanism* only. No app-specific
# content (secret keys, DB schema, manifest values) is hardcoded here.
#
# bash 3.2-safe (macOS default): no associative arrays, no `mapfile`.
# =============================================================================

# Map an app name to a Postgres-safe database identifier: lowercase, every
# character outside [a-z0-9_] becomes '_'. A leading digit is prefixed with
# 'app_' — Postgres unquoted identifiers cannot start with a digit, and even
# though callers quote the name, a clean identifier avoids surprises in psql
# output and downstream tooling.
onboard_db_name() {
  local raw safe
  raw="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')"
  case "$raw" in
    [0-9]*) safe="app_${raw}" ;;
    *)      safe="$raw" ;;
  esac
  printf '%s' "$safe"
}

# JSON-escape a string for embedding inside a double-quoted JSON value:
# backslash, double-quote, and control chars (newline/CR/tab → space).
# Copy of doctor.sh's json_esc — kept here so onboard-lib is self-contained.
onboard_json_esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '
}

# Emit one JSON object describing an onboard primitive's result.
#   onboard_emit_json <step> <status> <detail> <next_action> [<file>...]
# `written_files` is built from the 5th argument onward and may be empty
# (`outpost db create` writes no files). Every value is JSON-escaped.
onboard_emit_json() {
  local step="$1" status="$2" detail="$3" next_action="$4"
  shift 4
  local files=("$@")
  local files_json="" first=1 f
  if [[ ${#files[@]} -gt 0 ]]; then
    for f in "${files[@]}"; do
      [[ $first -eq 0 ]] && files_json+=','
      first=0
      files_json+="\"$(onboard_json_esc "$f")\""
    done
  fi
  printf '{"step":"%s","status":"%s","detail":"%s","written_files":[%s],"next_action":"%s"}\n' \
    "$(onboard_json_esc "$step")" \
    "$(onboard_json_esc "$status")" \
    "$(onboard_json_esc "$detail")" \
    "$files_json" \
    "$(onboard_json_esc "$next_action")"
}

# Return 0 if two files exist and are byte-identical, non-zero otherwise.
# Drives `manifest scaffold`'s unchanged-vs-drift decision. A missing file
# (cmp exit 2) counts as "not identical".
onboard_files_identical() {
  cmp -s "$1" "$2" 2>/dev/null
}

# Plain string substitution: read <src>, apply each sed expression in order,
# write <dst>.
#   onboard_render_subst <src> <dst> <sed-expr>...
# Used by `manifest scaffold` — manifests are not env-templated, so this is
# deliberately plain sed, not envsubst (contrast render_template, which is
# for ${VAR} templates and enforces a residue check).
onboard_render_subst() {
  local src="$1" dst="$2"
  shift 2
  if [[ $# -eq 0 ]]; then
    cat "$src" > "$dst"
    return
  fi
  local args=() e
  for e in "$@"; do
    args+=(-e "$e")
  done
  sed "${args[@]}" "$src" > "$dst"
}
