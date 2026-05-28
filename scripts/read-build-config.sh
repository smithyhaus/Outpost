#!/bin/sh
# =============================================================================
# scripts/read-build-config.sh — read optional outpost.build.yaml from a
# cloned application source tree and emit per-app kaniko inputs:
#   dockerfile, context, extra-args (a merged JSON array)
#
# This is the canonical script — `core/k8s/05-tekton/task-read-build-config.yaml`
# mounts it via a ConfigMap and runs it inside a yq-equipped image. Putting
# the logic here (instead of inline in YAML) means it's shellcheck-able,
# bats-testable, and editable like normal code.
#
# Usage:
#   read-build-config.sh <source_root> <defaults_json> <out_dir>
#
# Arguments:
#   source_root     — directory where outpost.build.yaml may live (cloned repo)
#   defaults_json   — JSON array literal of platform-default kaniko args
#                     (e.g. ${KANIKO_EXTRA_ARGS} from registry-config.sh)
#   out_dir         — directory to write 3 single-line result files into:
#                       dockerfile / context / extra-args
#
# Defaults preserved when outpost.build.yaml is absent (zero-regression
# from v0.2 behavior):
#   dockerfile : ./Dockerfile
#   context    : ./
#   extra-args : <defaults_json> (passed through unchanged)
#
# Schema (when file exists):
#   dockerfile: "./path/to/Dockerfile"     # string, default ./Dockerfile
#   context:    "./subdir"                 # string, default ./
#   buildArgs:                             # list[str], default []
#     - "VERSION=1.0"                      # each becomes --build-arg=VERSION=1.0
#     - "DEBUG=false"
#   extraArgs:                             # list[str], default []
#     - "--single-snapshot"                # passed through verbatim
#     - "--ignore-path=/foo"
#
# Merge order (preserves precedence):
#   1. defaults_json (platform / registry-plugin)
#   2. buildArgs (app-specific --build-arg= entries)
#   3. extraArgs (app-specific kaniko flags)
#
# Requires: yq (mikefarah, v4+) on PATH.
# =============================================================================
set -eu

SRC="${1:?usage: $0 <source_root> <defaults_json> <out_dir>}"
DEFAULTS="${2:-[]}"
OUT="${3:?usage: $0 <source_root> <defaults_json> <out_dir>}"

if ! command -v yq >/dev/null 2>&1; then
  echo "read-build-config.sh: yq (mikefarah, v4+) is required but not on PATH" >&2
  exit 2
fi

CFG="${SRC}/outpost.build.yaml"
mkdir -p "$OUT"

# Normalize DEFAULTS into a JSON array (yq-mergeable shape). Three input
# forms are supported, in order of preference:
#
#   (1) Space-separated tokens — the canonical v0.5+ shape produced by
#       platform/lib/registry-config.sh. Example:
#         "--skip-tls-verify --cache=true --cache-repo=foo"
#       Chosen because Tekton's v0.50+ ParamValue handler does NOT coerce
#       plain strings, only flow-array-shaped ones. This is the only form
#       that survives the full bash → envsubst → Tekton → env-var chain
#       without silent corruption. See registry-config.sh header for the
#       full root-cause writeup.
#
#   (2) Broken JSON-shape `[a,b,c]` (no inner quotes) — what Tekton emits
#       when an older bootstrap stored KANIKO_EXTRA_ARGS as a JSON array
#       string. Kept as a defensive belt-and-suspenders fallback: if a
#       future regression reintroduces JSON shape, this branch repairs it
#       and emits a stderr warning so operators see the upstream issue.
#
#   (3) Valid JSON `["a","b","c"]` — accepted as-is for completeness.
#
# The unified output goes back into $DEFAULTS as a valid JSON array string.
case "$DEFAULTS" in
  '['*)
    # Forms (2) or (3) — already in [...] shape. Decide between them by
    # checking for embedded quotes.
    inner=$(printf '%s' "$DEFAULTS" | sed -e 's/^\[//' -e 's/\]$//')
    case "$inner" in
      *'"'*) : ;;  # form (3): already-quoted, trust input
      '')    : ;;  # empty array
      *)
        # form (2): broken-by-Tekton. Re-quote, warn so the regression is
        # discoverable.
        echo "read-build-config: WARNING — defaults param arrived in broken JSON shape '[a,b]'" >&2
        echo "  This means KANIKO_EXTRA_ARGS upstream is JSON-formatted again," >&2
        echo "  triggering Tekton ParamValue coercion. Check registry-config.sh." >&2
        normalized=$(printf '%s' "$inner" | awk -v RS=',' '{
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          if (length($0)) printf "%s\"%s\"", (NR>1 ? "," : ""), $0
        }')
        DEFAULTS="[${normalized}]"
        ;;
    esac
    ;;
  '')
    # Treat empty value as empty array.
    DEFAULTS='[]'
    ;;
  *)
    # Form (1): space-separated tokens — primary v0.5+ shape. Convert to
    # JSON array by quoting each whitespace-delimited token.
    DEFAULTS=$(printf '%s' "$DEFAULTS" | awk '{
      printf "["
      for (i=1; i<=NF; i++) printf "%s\"%s\"", (i>1 ? "," : ""), $i
      printf "]"
    }')
    ;;
esac

DOCKERFILE="./Dockerfile"
CONTEXT="./"
BUILD_ARGS_JSON='[]'
EXTRA_ARGS_JSON='[]'

if [ -f "$CFG" ]; then
  echo "outpost.build.yaml found at $CFG — parsing per-app build config" >&2
  D=$(yq '.dockerfile // ""' "$CFG")
  [ -n "$D" ] && [ "$D" != "null" ] && DOCKERFILE="$D"
  C=$(yq '.context // ""' "$CFG")
  [ -n "$C" ] && [ "$C" != "null" ] && CONTEXT="$C"
  # buildArgs → ["--build-arg=K=V", ...]. The `?` suppresses missing-key errors.
  BUILD_ARGS_JSON=$(yq -o=json -I=0 '[.buildArgs[]? | "--build-arg=" + .]' "$CFG")
  # extraArgs → passed through unchanged.
  EXTRA_ARGS_JSON=$(yq -o=json -I=0 '[.extraArgs[]?]' "$CFG")
else
  echo "no outpost.build.yaml at $CFG — using v0.2 defaults" >&2
fi

# Merge 3 JSON arrays. Write each to a doc, then ireduce-concat with yq.
# Using yq itself (instead of jq) keeps the runtime image to one tool.
TMP=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMP'" EXIT
printf '%s\n' "$DEFAULTS"        > "$TMP/d.json"
printf '%s\n' "$BUILD_ARGS_JSON" > "$TMP/b.json"
printf '%s\n' "$EXTRA_ARGS_JSON" > "$TMP/e.json"

MERGED=$(yq eval-all -p=json -o=json -I=0 \
  '. as $a ireduce ([]; . + $a)' \
  "$TMP/d.json" "$TMP/b.json" "$TMP/e.json")

# Write results (no trailing newline — Tekton results read as-is).
printf '%s' "$DOCKERFILE" > "$OUT/dockerfile"
printf '%s' "$CONTEXT"    > "$OUT/context"
printf '%s' "$MERGED"     > "$OUT/extra-args"

# Stderr summary for PipelineRun logs (stdout is reserved for nothing here —
# the script communicates only via files in $OUT).
echo "read-build-config: dockerfile=$DOCKERFILE context=$CONTEXT extra-args=$MERGED" >&2
