#!/usr/bin/env bash
# =============================================================================
# Regenerate vendored Tekton catalog tasks.
# -----------------------------------------------------------------------------
# Use this when bumping the pinned task version (e.g., kaniko 0.7 -> 0.8).
# The result is committed to core/k8s/05-tekton/catalog/ and the bootstrap
# applies that local copy — there is no install-time network dependency.
#
# Usage:
#   bash scripts/vendor-tekton-catalog.sh
#
# Side effect: overwrites the catalog/*.yaml files in place. Run
# `git diff core/k8s/05-tekton/catalog/` after to see what changed.
# =============================================================================
set -euo pipefail

# Tasks to vendor: <local-filename>::<catalog-path-under-task/>
TASKS=(
  "git-clone-0.10.yaml::git-clone/0.10/git-clone.yaml"
  "kaniko-0.7.yaml::kaniko/0.7/kaniko.yaml"
)

DST="core/k8s/05-tekton/catalog"
BASE="https://raw.githubusercontent.com/tektoncd/catalog/main/task"
API="https://api.github.com/repos/tektoncd/catalog/commits"

mkdir -p "$DST"

today="$(date -u +%Y-%m-%d)"

for entry in "${TASKS[@]}"; do
  local_name="${entry%%::*}"
  remote_path="${entry##*::}"
  out="$DST/$local_name"

  echo ">> $remote_path  →  $out"

  # Fetch the most recent commit SHA that touched this exact file. Pinning
  # this in the header lets a future operator audit upstream changes.
  sha="$(curl -fsSL --max-time 15 \
    "${API}?path=task/${remote_path}&per_page=1" 2>/dev/null \
    | grep -m1 '"sha"' | sed -E 's/.*"sha": "([^"]+)".*/\1/' || true)"

  if [[ -z "$sha" ]]; then
    echo "  WARN: could not fetch SHA from GitHub API (rate limit? offline?)"
    echo "  Falling back to 'unknown' in provenance header."
    sha="unknown"
  fi

  body="$(curl -fsSL --max-time 30 "${BASE}/${remote_path}")"
  if [[ -z "$body" ]]; then
    echo "  ERROR: empty body from ${BASE}/${remote_path}"
    exit 1
  fi

  cat >"$out" <<EOF
# =============================================================================
# VENDORED — DO NOT HAND-EDIT. Regenerate via scripts/vendor-tekton-catalog.sh
# -----------------------------------------------------------------------------
# Source: tektoncd/catalog @ ${sha}
#         task/${remote_path}
# Fetched: ${today}
#
# Why vendored (not curl'd at bootstrap):
#   1. main is mutable — silent breakage if catalog re-edits this file.
#   2. raw.githubusercontent.com is intermittently throttled in CN.
#   3. Tractable code review — diff vendored vs upstream is in-repo.
# =============================================================================
EOF
  printf '%s\n' "$body" >>"$out"
  echo "  → $(wc -l <"$out" | tr -d ' ') lines vendored"
done

echo ""
echo "Done. Review with: git diff $DST/"
