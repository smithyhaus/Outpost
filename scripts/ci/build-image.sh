#!/usr/bin/env bash
# =============================================================================
# scripts/ci/build-image.sh — build & push one app image from a GHA workflow.
# -----------------------------------------------------------------------------
# Runs ON THE HOST (self-hosted runner), called by templates/github/
# outpost-build.yml. Drives the long-lived in-cluster buildkitd over its
# NodePort (127.0.0.1:30750); the PUSH is performed BY the daemon, in-cluster,
# straight to the registry Service — so the image name in the manifest equals
# the push target (REGISTRY_PUSH_HOST, per platform/lib/registry-config.sh).
# The registry NodePort (127.0.0.1:30500) is the HOST-side API endpoint
# (tag listing for `outpost rollback`), NOT the push path: buildkitd resolving
# 127.0.0.1 would hit its own pod loopback.
#
# Hardened logic ported 1:1 from core/k8s/05-tekton/task-buildkit.yaml:
#   - CONTEXT/DOCKERFILE path-traversal guards (reject absolute + `..`)
#   - build-arg allowlist + whitespace/arg-injection guard (positional args,
#     never string-concat-then-word-split)
#   - ACR-safe push: registry.insecure=true ONLY for the plain-HTTP
#     self-hosted registry — buildkit rewrites the resolver to PlainHTTP
#     unconditionally, and HTTPS registries (aliyun-acr) refuse that outright.
#
# Usage (workflow):  build-image.sh [<workspace>] [<repo-name>]
#   workspace  — checked-out app repo (default: $GITHUB_WORKSPACE)
#   repo-name  — app repo name        (default: ${GITHUB_REPOSITORY##*/},
#                else basename of workspace)
#
# Routing: repos listed in OUTPOST_LIBRARY_REPOS (comma list, default
# "fst-foundation") ship no image — they are delegated to publish-npm.sh
# (@hy/* → Verdaccio), same split as the old pipeline-publish trigger.
#
# Outputs: prints the pushed image ref; appends image=<ref> to $GITHUB_OUTPUT
# and IMAGE=<ref> to $GITHUB_ENV when set (consumed by the update-manifest
# workflow step).
#
# bash-3.2 compatible (no mapfile / assoc arrays / ${var,,}).
# =============================================================================
set -euo pipefail

_CI_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPOST_ROOT="${OUTPOST_ROOT:-$(cd "$_CI_DIR/../.." && pwd)}"

# .env carries REGISTRY_PLUGIN / ROOT_DOMAIN / HY_REGISTRY / library-repo list.
# OUTPOST_NO_ENV=1 lets tests pre-export everything (caller env wins).
if [[ -f "$OUTPOST_ROOT/.env" && "${OUTPOST_NO_ENV:-0}" != "1" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$OUTPOST_ROOT/.env"
  set +a
fi

# shellcheck source=../../platform/lib/portable.sh
source "$OUTPOST_ROOT/platform/lib/portable.sh"
# shellcheck source=../../platform/lib/registry-config.sh
source "$OUTPOST_ROOT/platform/lib/registry-config.sh"

WORKSPACE="${1:-${GITHUB_WORKSPACE:-}}"
[[ -n "$WORKSPACE" ]] || { err "usage: build-image.sh <workspace> [<repo-name>] (or set GITHUB_WORKSPACE)"; exit 2; }
[[ -d "$WORKSPACE" ]] || { err "workspace not a directory: $WORKSPACE"; exit 2; }

REPO_NAME="${2:-}"
if [[ -z "$REPO_NAME" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    REPO_NAME="${GITHUB_REPOSITORY##*/}"
  else
    REPO_NAME="$(basename "$WORKSPACE")"
  fi
fi

# ---- publish-type routing (library repos ship packages, not images) ---------
_lib_repos="${OUTPOST_LIBRARY_REPOS:-fst-foundation}"
_old_ifs="$IFS"; IFS=','
for _lr in $_lib_repos; do
  _lr="${_lr// /}"
  if [[ -n "$_lr" && "$_lr" == "$REPO_NAME" ]]; then
    IFS="$_old_ifs"
    echo "build-image: $REPO_NAME is a library repo (OUTPOST_LIBRARY_REPOS) — routing to publish-npm.sh"
    exec bash "$_CI_DIR/publish-npm.sh" "$WORKSPACE"
  fi
done
IFS="$_old_ifs"

require_cmd buildctl git yq

# ---- registry / image ref ---------------------------------------------------
resolve_registry_config

SHA="${GITHUB_SHA:-$(git -C "$WORKSPACE" rev-parse HEAD)}"
TAG="${SHA:0:7}"   # sha-7 contract — verify.sh reconciliation keys off this
IMAGE="${REGISTRY_PUSH_HOST}/${REPO_NAME}:${TAG}"

# ACR-safe: derive from the registry plugin; REGISTRY_INSECURE overrides.
case "${REGISTRY_PLUGIN:-self-hosted}" in
  self-hosted) _insecure_default="true"  ;;
  *)           _insecure_default="false" ;;
esac
INSECURE="${REGISTRY_INSECURE:-$_insecure_default}"

# ---- per-app build config (outpost.build.yaml) ------------------------------
CFG_OUT=$(mktemp -d)
trap 'rm -rf "$CFG_OUT"' EXIT
sh "$OUTPOST_ROOT/scripts/read-build-config.sh" "$WORKSPACE" "${KANIKO_EXTRA_ARGS:-}" "$CFG_OUT"
CONTEXT=$(cat "$CFG_OUT/context")
DOCKERFILE=$(cat "$CFG_OUT/dockerfile")

# CONTEXT/DOCKERFILE come from the app's outpost.build.yaml UNSANITIZED.
# Reject absolute paths and `..` so a repo can't point the build context at,
# e.g., a host secrets dir and bake it into the pushed image (path-traversal
# exfil). Both must stay relative to the checked-out source root.
for p in "$CONTEXT" "$DOCKERFILE"; do
  case "$p" in
    /*|*..*)
      err "build-image: refusing CONTEXT/DOCKERFILE outside source root: $p"
      exit 1 ;;
  esac
done

# kaniko-shaped EXTRA_ARGS → buildctl opts: keep ONLY --build-arg=K=V. Values
# are ALSO attacker-controlled (extraArgs/buildArgs in outpost.build.yaml), so
# accumulate them as ARRAY elements (never string-concat then word-split) and
# reject whitespace — otherwise `--build-arg=X=1 --output …` would inject a
# second buildctl flag (e.g. overwrite another app's image tag in the shared
# registry). buildctl is then invoked with the quoted array.
BUILD_OPTS=()
while IFS= read -r a; do
  [[ -z "$a" ]] && continue
  case "$a" in
    --build-arg=*)
      val=${a#--build-arg=}
      case "$val" in
        ''|*[[:space:]]*)
          err "build-image: rejecting build-arg with empty/whitespace value (arg-injection guard)"
          exit 1 ;;
      esac
      BUILD_OPTS[${#BUILD_OPTS[@]}]="--opt"
      BUILD_OPTS[${#BUILD_OPTS[@]}]="build-arg:$val"
      ;;
    *) : ;;  # kaniko-only flag — daemon-side config in buildkit, ignored
  esac
done < <(yq e -p=json '.[]' "$CFG_OUT/extra-args")

CTX_DIR="$WORKSPACE/$CONTEXT"
DF_PATH="$CTX_DIR/$DOCKERFILE"   # kaniko semantics: dockerfile relative to context
DF_DIR=$(dirname "$DF_PATH")
DF_NAME=$(basename "$DF_PATH")

BUILDKIT_ADDR="${BUILDKIT_ADDR:-tcp://127.0.0.1:30750}"
echo "build-image: addr=$BUILDKIT_ADDR image=$IMAGE context=$CTX_DIR dockerfile=$DF_DIR/$DF_NAME"
echo "build-image: build-arg opts=${BUILD_OPTS[*]+"${BUILD_OPTS[*]}"}"

# registry.insecure=true is NOT "try HTTPS, fall back": buildkit
# unconditionally rewrites the push resolver to PlainHTTP. Only add it for
# the plain-HTTP self-hosted registry; HTTPS registries (aliyun-acr) refuse
# the connection outright.
PUSH_OUT="type=image,name=$IMAGE,push=true"
if [[ "$INSECURE" == "true" ]]; then
  PUSH_OUT="$PUSH_OUT,registry.insecure=true"
fi

MD_FILE="$CFG_OUT/md.json"
buildctl --addr "$BUILDKIT_ADDR" build \
  --frontend dockerfile.v0 \
  --local context="$CTX_DIR" \
  --local dockerfile="$DF_DIR" \
  --opt filename="$DF_NAME" \
  ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} \
  --output "$PUSH_OUT" \
  --metadata-file "$MD_FILE"

# containerimage.digest from the pretty-printed metadata file (each key on its
# own line). Empty digest degrades gracefully: update-manifest keys off the
# image tag, not the digest.
DIGEST=$(sed -n 's/.*"containerimage.digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MD_FILE" | head -n1)
echo "build-image: pushed $IMAGE digest=${DIGEST:-<none>}"

# ---- workflow outputs -------------------------------------------------------
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "image=$IMAGE"
    echo "digest=${DIGEST:-}"
    echo "tag=$TAG"
  } >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "IMAGE=$IMAGE" >> "$GITHUB_ENV"
fi
