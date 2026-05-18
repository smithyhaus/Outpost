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
