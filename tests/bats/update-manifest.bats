#!/usr/bin/env bats
# =============================================================================
# Tests for scripts/update-manifest.sh.
# Each test spins up a local bare git repo (the manifest repo), seeds it with
# initial files, runs the script with controlled env vars, then inspects the
# bare repo to verify the resulting commit.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${INFRA_ROOT}/scripts/update-manifest.sh"
  [ -x "$SCRIPT" ] || skip "update-manifest.sh is not executable"

  command -v git >/dev/null 2>&1 || skip "git not available"
  command -v yq  >/dev/null 2>&1 || skip "yq not available (install mikefarah/yq)"

  TMP="$(mktemp -d)"
  REMOTE="$TMP/remote.git"
  SEED="$TMP/seed"
  WORK="$TMP/work"

  # Bare "remote" with initial main branch
  git init --bare -q --initial-branch=main "$REMOTE"

  # Seed working clone with an initial README
  git clone -q "$REMOTE" "$SEED"
  ( cd "$SEED"
    git config user.email "test@local"
    git config user.name  "Test"
    git config commit.gpgsign false
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
    git push -q origin main
  )

  mkdir -p "$WORK"

  export MANIFEST_REPO_URL="file://$REMOTE"
  export MANIFEST_BRANCH="main"
  export APP_NAME="hello-go"
  export IMAGE="registry.example.com/hello-go:abc1234"
  export COMMIT_MESSAGE="test: bump image"
  export WORK_DIR="$WORK"
  export GIT_USER_EMAIL="test@local"
  export GIT_USER_NAME="Test CI"
  # Use the host's yq; the script's auto-install path is for in-container use.
  export YQ_BIN="$(command -v yq)"
}

teardown() {
  rm -rf "$TMP"
}

# ---------- helpers ----------------------------------------------------------

# Seed a file in the bare repo by committing through the SEED clone.
seed_file() {
  local rel="$1"
  local content="$2"
  ( cd "$SEED"
    mkdir -p "$(dirname "$rel")"
    printf '%s\n' "$content" > "$rel"
    git add "$rel"
    git commit -q -m "seed $rel"
    git push -q origin main
  )
}

# Re-clone the bare repo into INSPECT and echo the path.
inspect_repo() {
  local INSPECT="$TMP/inspect.$$"
  rm -rf "$INSPECT"
  git clone -q "$REMOTE" "$INSPECT" >&2
  echo "$INSPECT"
}

# ---------- Mode A: kustomize ------------------------------------------------

@test "Mode A: kustomization with matching name updates that entry" {
  seed_file "apps/hello-go/kustomization.yaml" 'resources:
  - deployment.yaml
images:
  - name: registry.example.com/hello-go
    newName: registry.example.com/hello-go
    newTag: old0000'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT
  INSPECT=$(inspect_repo)
  local F="$INSPECT/apps/hello-go/kustomization.yaml"

  yq -e '.images[0].newTag == "abc1234"'  "$F" >/dev/null
  yq -e '.images[0].newName == "registry.example.com/hello-go"' "$F" >/dev/null
  # exactly one entry — no append
  [ "$(yq '.images | length' "$F")" = "1" ]
}

@test "Mode A: kustomization with non-matching name appends a new entry" {
  seed_file "apps/hello-go/kustomization.yaml" 'resources:
  - deployment.yaml
images:
  - name: someone-else/other
    newName: someone-else/other
    newTag: v1'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT
  INSPECT=$(inspect_repo)
  local F="$INSPECT/apps/hello-go/kustomization.yaml"

  [ "$(yq '.images | length' "$F")" = "2" ]
  yq -e '.images[] | select(.name == "registry.example.com/hello-go") | .newTag == "abc1234"' "$F" >/dev/null
}

@test "Mode A: kustomization with empty .images: [] appends" {
  seed_file "apps/hello-go/kustomization.yaml" 'resources:
  - deployment.yaml
images: []'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT
  INSPECT=$(inspect_repo)
  local F="$INSPECT/apps/hello-go/kustomization.yaml"

  [ "$(yq '.images | length' "$F")" = "1" ]
  yq -e '.images[0].name    == "registry.example.com/hello-go"' "$F" >/dev/null
  yq -e '.images[0].newTag  == "abc1234"' "$F" >/dev/null
}

@test "Mode A: kustomization without .images key falls through to Mode B" {
  # kustomization.yaml exists but has no images: section.
  seed_file "apps/hello-go/kustomization.yaml" 'resources:
  - deployment.yaml'
  seed_file "apps/hello-go/deployment.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-go
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.example.com/hello-go:placeholder'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT
  INSPECT=$(inspect_repo)
  yq -e '.spec.template.spec.containers[0].image == "registry.example.com/hello-go:abc1234"' \
    "$INSPECT/apps/hello-go/deployment.yaml" >/dev/null
}

# ---------- Mode B: legacy deployment.yaml -----------------------------------

@test "Mode B: only deployment.yaml updates containers[0].image" {
  seed_file "apps/hello-go/deployment.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-go
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.example.com/hello-go:old0000'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT
  INSPECT=$(inspect_repo)
  yq -e '.spec.template.spec.containers[0].image == "registry.example.com/hello-go:abc1234"' \
    "$INSPECT/apps/hello-go/deployment.yaml" >/dev/null
}

# ---------- Idempotence ------------------------------------------------------

@test "idempotence: re-run with same image is a no-op" {
  seed_file "apps/hello-go/deployment.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-go
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.example.com/hello-go:abc1234'

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Capture commit count after first run
  local INSPECT1
  INSPECT1=$(inspect_repo)
  local C1
  C1=$(cd "$INSPECT1" && git rev-list --count HEAD)

  # Re-run; script should detect no change and exit 0 without committing
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  local INSPECT2
  INSPECT2=$(inspect_repo)
  local C2
  C2=$(cd "$INSPECT2" && git rev-list --count HEAD)
  [ "$C1" = "$C2" ]
}

# ---------- Error cases ------------------------------------------------------

@test "error: neither kustomization.yaml nor deployment.yaml" {
  # Just create the apps/<APP_NAME>/ dir with an unrelated file
  seed_file "apps/hello-go/.gitkeep" ''

  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"neither"* ]] || [[ "$output" == *"deployment.yaml"* ]]
}

@test "error: app dir does not exist at all" {
  # No apps/hello-go/ in the repo
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "error: image with @sha256 digest is rejected" {
  seed_file "apps/hello-go/deployment.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata: {name: hello-go}
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.example.com/hello-go:placeholder'

  IMAGE="registry.example.com/hello-go@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sha256"* ]] || [[ "$output" == *"digest"* ]]
}

@test "error: image without :tag is rejected" {
  seed_file "apps/hello-go/deployment.yaml" 'apiVersion: apps/v1
kind: Deployment
metadata: {name: hello-go}
spec:
  template:
    spec:
      containers:
        - name: app
          image: registry.example.com/hello-go:placeholder'

  IMAGE="registry.example.com/hello-go" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *":tag"* ]] || [[ "$output" == *"must contain"* ]]
}
