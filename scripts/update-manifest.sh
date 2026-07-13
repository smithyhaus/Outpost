#!/bin/sh
# =============================================================================
# update-manifest.sh — bump the image reference for one app in the manifest
# repo and commit the change. Used by the `update-manifest-task` Tekton Task
# (mounted via ConfigMap) AND directly by `tests/bats/update-manifest.bats`.
#
# Single source of truth: edit ONLY this file. The Tekton Task ConfigMap is
# rebuilt from this file on every `bootstrap.sh` run.
#
# ----- Inputs (env vars, all required) -----
#   MANIFEST_REPO_URL   HTTPS URL ending in .git
#   MANIFEST_BRANCH     e.g. main
#   APP_NAME            subdir under apps/, e.g. hello-go
#   IMAGE               full image ref, e.g. registry.example.com/hello-go:abc1234
#   COMMIT_MESSAGE      git commit subject
#   WORK_DIR            writable scratch dir (Tekton workspace path)
#
# Optional:
#   GIT_CRED_FILE       path to .git-credentials (default: $WORK_DIR/.git-credentials)
#   GIT_USER_EMAIL      committer email   (default: tekton-ci@local)
#   GIT_USER_NAME       committer name    (default: Tekton CI)
#   YQ_BIN              path to yq        (default: /usr/local/bin/yq)
#                       If yq is missing, the script will install
#                       mikefarah/yq v4.44.3 to /usr/local/bin/yq.
#
# ----- Modes (auto-detected) -----
#   A. kustomize  — apps/<APP_NAME>/kustomization.yaml exists AND has
#                   an `.images` key (any state, including `[]`).
#                   The script finds the entry where `name == <repo-without-tag>`,
#                   updates its `newName` and `newTag`, OR appends one
#                   if no matching entry exists.
#                   This is the kustomize-native approach.
#
#   B. legacy     — Otherwise, if apps/<APP_NAME>/deployment.yaml exists,
#                   set `.spec.template.spec.containers[0].image` directly.
#                   Backward compatible with single-deployment projects.
#
#   Neither file present → error.
#
# ----- Idempotence -----
#   If the resulting file content is identical to HEAD, the script exits 0
#   without committing. Re-running with the same image is a no-op.
# =============================================================================
set -eu

# ---- Validate required inputs ------------------------------------------------
: "${MANIFEST_REPO_URL:?env MANIFEST_REPO_URL is required}"
: "${MANIFEST_BRANCH:?env MANIFEST_BRANCH is required}"
: "${APP_NAME:?env APP_NAME is required}"
: "${IMAGE:?env IMAGE is required}"
: "${COMMIT_MESSAGE:?env COMMIT_MESSAGE is required}"
: "${WORK_DIR:?env WORK_DIR is required}"

GIT_CRED_FILE="${GIT_CRED_FILE:-$WORK_DIR/.git-credentials}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-tekton-ci@local}"
GIT_USER_NAME="${GIT_USER_NAME:-Tekton CI}"
YQ_BIN="${YQ_BIN:-/usr/local/bin/yq}"

# ---- Ensure yq is available --------------------------------------------------
if ! command -v "$YQ_BIN" >/dev/null 2>&1 && ! [ -x "$YQ_BIN" ]; then
  echo "→ installing yq (mikefarah) v4.44.3"
  if ! command -v curl >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl ca-certificates >/dev/null
    fi
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)  YQ_ARCH="amd64" ;;
    aarch64|arm64) YQ_ARCH="arm64" ;;
    *) echo "ERROR: unsupported arch $ARCH for yq install" >&2; exit 2 ;;
  esac
  YQ_REL="mikefarah/yq/releases/download/v4.44.3/yq_linux_${YQ_ARCH}"
  # CN egress to github.com is flaky (SSL eof / connect timeout). Prefer the
  # DaoCloud github-release file mirror, fall back to github directly, each with
  # retries for transient flakes.
  for _u in "https://files.m.daocloud.io/github.com/${YQ_REL}" "https://github.com/${YQ_REL}"; do
    if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 -o "$YQ_BIN" "$_u"; then break; fi
  done
  [ -s "$YQ_BIN" ] || { echo "ERROR: failed to download yq from mirror + github" >&2; exit 2; }
  chmod +x "$YQ_BIN"
fi

# ---- Parse image ref into name + tag ----------------------------------------
# Greedy left-trim on `:` keeps tag (handles `host:port/path:tag` correctly).
# Greedy right-trim on `:*` keeps name. Digest form (@sha256:...) is rejected
# because Tekton always passes :short-sha here; supporting digests would
# require parsing logic that is out of scope.
case "$IMAGE" in
  *@sha256:*)
    echo "ERROR: image ref with @sha256 digest is not supported by this script."
    echo "       Pass the :tag form instead. Got: $IMAGE" >&2
    exit 2
    ;;
esac

case "$IMAGE" in
  *:*)  ;;
  *)    echo "ERROR: image ref must contain a :tag (got: $IMAGE)" >&2; exit 2 ;;
esac

IMAGE_NAME="${IMAGE%:*}"
IMAGE_TAG="${IMAGE##*:}"

# ---- Configure git credentials ----------------------------------------------
if [ -f "$GIT_CRED_FILE" ]; then
  cp "$GIT_CRED_FILE" "$HOME/.git-credentials"
fi
git config --global credential.helper "store"
git config --global user.email "$GIT_USER_EMAIL"
git config --global user.name  "$GIT_USER_NAME"

# ---- Clone manifest repo at MANIFEST_BRANCH ---------------------------------
cd "$WORK_DIR"
rm -rf repo
git clone --depth 1 --branch "$MANIFEST_BRANCH" "$MANIFEST_REPO_URL" repo
cd repo

# Resolve the manifest app dir. The GitHub repo name (APP_NAME) often carries an
# `fst-` prefix or `-web` suffix that the manifest dir drops
# (fst-product-service -> product-service, fst-admin-web -> fst-admin,
# fst-bff-ops -> bff-ops). The BFFs live INSIDE their frontend's app dir
# (fst-bff-admin -> apps/fst-admin, fst-bff-miniapp -> apps/fst-miniapp),
# hence the fst-bff-* -> fst-* variant. Try the known variants in order.
APP_DIR=""
_bff_cand=$(printf '%s' "$APP_NAME" | sed 's/^fst-bff-/fst-/')
for _cand in "$APP_NAME" "${APP_NAME#fst-}" "${APP_NAME%-web}" "$_bff_cand"; do
  if [ -d "apps/$_cand" ]; then APP_DIR="apps/$_cand"; break; fi
done
if [ -z "$APP_DIR" ]; then
  echo "ERROR: no manifest dir for '$APP_NAME' (tried apps/$APP_NAME, apps/${APP_NAME#fst-}, apps/${APP_NAME%-web}, apps/$_bff_cand)." >&2
  echo "       Add the directory with either kustomization.yaml or deployment.yaml first." >&2
  exit 1
fi

KUST_FILE="$APP_DIR/kustomization.yaml"
DEPLOY_FILE="$APP_DIR/deployment.yaml"

# ---- Mode dispatch ----------------------------------------------------------
# Mode A is selected if kustomization.yaml exists AND has an `images` key
# (even an empty array). This signals user intent to manage images via
# kustomize; we should not silently fall through to deployment.yaml in
# that case.
TARGET=""

if [ -f "$KUST_FILE" ] && "$YQ_BIN" -e 'has("images")' "$KUST_FILE" >/dev/null 2>&1; then
  echo "→ Mode A (kustomize): $KUST_FILE"

  # Locate the .images[] entry by `name`. Kustomize's images override matches
  # on the `name` field, which is the original image ref the deployment
  # contains. Convention in this project: the kustomization.yaml entry's
  # `name` equals the registry+repo (i.e. our $IMAGE_NAME).
  EXISTING_INDEX=$(
    IMAGE_NAME="$IMAGE_NAME" \
      "$YQ_BIN" '.images // [] | (map(.name) | to_entries | map(select(.value == strenv(IMAGE_NAME))) | .[0].key) // -1' \
      "$KUST_FILE"
  )

  if [ "$EXISTING_INDEX" = "-1" ] || [ -z "$EXISTING_INDEX" ]; then
    echo "  no entry with name=$IMAGE_NAME — appending"
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" \
      "$YQ_BIN" -i '
        .images = (.images // []) |
        .images += [{"name": strenv(IMAGE_NAME), "newName": strenv(IMAGE_NAME), "newTag": strenv(IMAGE_TAG)}]
      ' "$KUST_FILE"
  else
    echo "  updating .images[$EXISTING_INDEX].newTag = $IMAGE_TAG"
    IDX="$EXISTING_INDEX" IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" \
      "$YQ_BIN" -i '
        .images[env(IDX) | tonumber].newName = strenv(IMAGE_NAME) |
        .images[env(IDX) | tonumber].newTag  = strenv(IMAGE_TAG)
      ' "$KUST_FILE"
  fi

  TARGET="$KUST_FILE"

elif [ -f "$DEPLOY_FILE" ]; then
  echo "→ Mode B (legacy deployment.yaml): $DEPLOY_FILE"
  IMAGE="$IMAGE" \
    "$YQ_BIN" -i '.spec.template.spec.containers[0].image = strenv(IMAGE)' "$DEPLOY_FILE"
  TARGET="$DEPLOY_FILE"

else
  echo "ERROR: neither $KUST_FILE nor $DEPLOY_FILE exists." >&2
  echo "       Add one of:" >&2
  echo "         (recommended) kustomization.yaml with an 'images:' section, OR" >&2
  echo "         (legacy)      deployment.yaml" >&2
  exit 1
fi

# ---- Idempotence: skip commit if file content is unchanged ------------------
if git diff --quiet -- "$TARGET"; then
  echo "No changes in $TARGET. Skipping commit."
  exit 0
fi

git add "$TARGET"
git commit -m "$COMMIT_MESSAGE"

# ---- Push with rebase-on-conflict retry -------------------------------------
# Concurrent PipelineRuns on different apps both touch the manifest repo.
# Without retry, the second push gets non-fast-forward and exits 1, the
# Pipeline reports "git push failed" deep in the last step, the user first
# suspects their own code. Rebase-and-retry collapses the race window.
attempt=1
# 6 attempts with jitter: batch deploys are the NORMAL case here (multiple
# teams pushing concurrently → a dozen runs racing the same manifest repo).
# 3 immediate retries can exhaust under a 14-way race; jitter de-synchronizes
# the herd so each cycle's winner clears quickly. Each cycle is cheap
# (fetch+rebase touch one file, different per app — conflict-free).
max_attempts=6
while [ "$attempt" -le "$max_attempts" ]; do
  if git push origin "$MANIFEST_BRANCH"; then
    echo "  pushed on attempt $attempt"
    break
  fi
  if [ "$attempt" -eq "$max_attempts" ]; then
    echo "ERROR: git push failed after $max_attempts attempts" >&2
    exit 1
  fi
  echo "  push attempt $attempt/$max_attempts failed (likely concurrent push); rebasing on remote..."
  # Jittered backoff (portable: busybox sh has no $RANDOM; awk srand does).
  sleep "$(awk 'BEGIN{srand(); print int(rand()*4)+1}')"
  if ! git fetch origin "$MANIFEST_BRANCH"; then
    echo "ERROR: git fetch failed during retry" >&2
    exit 1
  fi
  if ! git rebase "origin/$MANIFEST_BRANCH"; then
    echo "ERROR: rebase conflict — manual intervention needed" >&2
    git rebase --abort 2>/dev/null || true
    exit 1
  fi
  attempt=$((attempt + 1))
done
