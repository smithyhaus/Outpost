#!/usr/bin/env bats
# =============================================================================
# Tests for scripts/ci/{build-image.sh,run-tests.sh,publish-npm.sh} — the
# host-side CI engine steps (v0.3.0, GHA self-hosted runner).
#
# PATH-shim stubs (buildctl / docker / pnpm) record their argv so the tests
# lock the INVOCATION CONTRACT: image ref shape (sha-7, REGISTRY_PUSH_HOST
# path), ACR-safe insecure flag, path-traversal + arg-injection guards, and
# the publish-type routing. Same stub style as update-manifest.bats.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BUILD="${INFRA_ROOT}/scripts/ci/build-image.sh"
  TESTS="${INFRA_ROOT}/scripts/ci/run-tests.sh"
  PUBLISH="${INFRA_ROOT}/scripts/ci/publish-npm.sh"
  [ -x "$BUILD" ] || skip "build-image.sh not executable"
  command -v yq  >/dev/null 2>&1 || skip "yq not available (install mikefarah/yq)"
  command -v git >/dev/null 2>&1 || skip "git not available"

  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  export MOCK_LOG="$TMP/calls.log"

  # buildctl stub: record argv, satisfy --metadata-file.
  cat > "$BIN/buildctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
prev=""
for a in "$@"; do
  if [ "$prev" = "--metadata-file" ]; then
    printf '{\n  "containerimage.digest": "sha256:deadbeef"\n}\n' > "$a"
  fi
  prev="$a"
done
exit "${MOCK_BUILDCTL_RC:-0}"
STUB
  chmod +x "$BIN/buildctl"

  # docker stub for Gate A containment.
  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
exit "${MOCK_DOCKER_RC:-0}"
STUB
  chmod +x "$BIN/docker"

  # pnpm stub for the publish route.
  cat > "$BIN/pnpm" <<'STUB'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "$MOCK_LOG"
exit "${MOCK_PNPM_RC:-0}"
STUB
  chmod +x "$BIN/pnpm"

  export PATH="$BIN:$PATH"

  # Workspace = a real git checkout (sha-7 comes from HEAD when GITHUB_SHA
  # is unset).
  WS="$TMP/ws"
  mkdir -p "$WS"
  ( cd "$WS"
    git init -q
    git config user.email t@l; git config user.name T
    git config commit.gpgsign false
    echo "FROM scratch" > Dockerfile
    git add .; git commit -q -m init )
  SHA7="$(cd "$WS" && git rev-parse --short=7 HEAD)"

  # Hermetic env: never read the repo's .env; self-hosted registry defaults.
  export OUTPOST_NO_ENV=1
  export REGISTRY_PLUGIN=self-hosted
  export ROOT_DOMAIN=example.com
  unset GITHUB_SHA GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_ENV OUTPOST_LIBRARY_REPOS 2>/dev/null || true
}

teardown() {
  rm -rf "$TMP"
}

# ---- build-image: image ref / sha-7 -----------------------------------------

@test "build-image: pushes REGISTRY_PUSH_HOST/<repo>:<sha7> (self-hosted, insecure)" {
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 0 ]
  grep -q -- "--output type=image,name=docker-registry.registry.svc.cluster.local:5000/myapp:${SHA7},push=true,registry.insecure=true" "$MOCK_LOG"
}

@test "build-image: GITHUB_SHA wins over git HEAD for the sha-7 tag" {
  GITHUB_SHA="fedcba9876543210fedcba9876543210fedcba98" run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 0 ]
  grep -q "myapp:fedcba9" "$MOCK_LOG"
}

@test "build-image: aliyun-acr push has NO registry.insecure (ACR-safe)" {
  REGISTRY_PLUGIN=aliyun-acr \
  ALIYUN_ACR_REGISTRY=registry.cn-hangzhou.aliyuncs.com \
  ALIYUN_ACR_NAMESPACE=myns \
    run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 0 ]
  grep -q "name=registry.cn-hangzhou.aliyuncs.com/myns/myapp:${SHA7},push=true" "$MOCK_LOG"
  ! grep -q "registry.insecure" "$MOCK_LOG"
}

@test "build-image: writes image= to GITHUB_OUTPUT and IMAGE= to GITHUB_ENV" {
  export GITHUB_OUTPUT="$TMP/gh-out" GITHUB_ENV="$TMP/gh-env"
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_ENV"
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 0 ]
  grep -q "^image=docker-registry.registry.svc.cluster.local:5000/myapp:${SHA7}$" "$GITHUB_OUTPUT"
  grep -q "^IMAGE=docker-registry.registry.svc.cluster.local:5000/myapp:${SHA7}$" "$GITHUB_ENV"
}

# ---- build-image: ported guards ---------------------------------------------

@test "build-image: rejects CONTEXT with .. (path-traversal guard)" {
  printf 'context: "../evil"\n' > "$WS/outpost.build.yaml"
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing CONTEXT/DOCKERFILE outside source root"* ]]
  ! grep -q "output type=image" "$MOCK_LOG" 2>/dev/null
}

@test "build-image: rejects absolute DOCKERFILE (path-traversal guard)" {
  printf 'dockerfile: "/var/run/secrets/Dockerfile"\n' > "$WS/outpost.build.yaml"
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing CONTEXT/DOCKERFILE outside source root"* ]]
}

@test "build-image: rejects build-arg with embedded whitespace (arg-injection guard)" {
  printf 'buildArgs:\n  - "X=1 --output evil"\n' > "$WS/outpost.build.yaml"
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 1 ]
  [[ "$output" == *"arg-injection guard"* ]]
}

@test "build-image: forwards clean build-args as --opt build-arg:K=V" {
  printf 'buildArgs:\n  - "VERSION=1.2.3"\n' > "$WS/outpost.build.yaml"
  run bash "$BUILD" "$WS" myapp
  [ "$status" -eq 0 ]
  grep -q -- "--opt build-arg:VERSION=1.2.3" "$MOCK_LOG"
  # platform default from registry-config.sh survives the merge too
  grep -q -- "--opt build-arg:HY_REGISTRY=" "$MOCK_LOG"
}

# ---- build-image: publish-type routing --------------------------------------

@test "build-image: library repo routes to publish-npm.sh (no buildctl call)" {
  export OUTPOST_LIBRARY_REPOS="somelib, mylib"
  export HY_REGISTRY_PUBLISH_URL="http://localhost:14873/"
  run bash "$BUILD" "$WS" mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"routing to publish-npm.sh"* ]]
  grep -q "pnpm install" "$MOCK_LOG"
  grep -q -- "pnpm -r --filter ./packages/\* publish --registry http://localhost:14873/ --no-git-checks" "$MOCK_LOG"
  ! grep -q "output type=image" "$MOCK_LOG"
}

# ---- publish-npm ------------------------------------------------------------

@test "publish-npm: writes @hy scope + dummy authToken .npmrc, exit-code judgement" {
  export HY_REGISTRY_PUBLISH_URL="http://localhost:14873/"
  run bash "$PUBLISH" "$WS"
  [ "$status" -eq 0 ]
  grep -q '@hy:registry=http://localhost:14873/' "$WS/.npmrc"
  grep -q '//localhost:14873/:_authToken=anonymous' "$WS/.npmrc"
  [[ "$output" == *"[OK] publish-npm done"* ]]
}

@test "publish-npm: a real pnpm publish failure fails the step" {
  export HY_REGISTRY_PUBLISH_URL="http://localhost:14873/"
  MOCK_PNPM_RC=1 run bash "$PUBLISH" "$WS"
  [ "$status" -ne 0 ]
}

# ---- run-tests (Gate A) -----------------------------------------------------

@test "run-tests: no test files → clean no-op skip, exit 0" {
  run bash "$TESTS" "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gate A: skipped"* ]]
  ! grep -q "docker run" "$MOCK_LOG" 2>/dev/null
}

@test "run-tests: outpost.test.yaml without .runner.command fails loudly" {
  printf 'runner: {}\n' > "$WS/outpost.test.yaml"
  run bash "$TESTS" "$WS"
  [ "$status" -eq 1 ]
  [[ "$output" == *".runner.command is required"* ]]
}

@test "run-tests: command runs CONTAINERIZED (docker run, workspace mounted)" {
  printf 'runner:\n  command: ["sh", "-c", "true"]\n' > "$WS/outpost.test.yaml"
  run bash "$TESTS" "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK] Gate A passed"* ]]
  grep -q "docker run --rm -v $WS:/workspace" "$MOCK_LOG"
}

@test "run-tests: container exit code propagates as Gate A failure" {
  printf 'runner:\n  command: ["false"]\n' > "$WS/outpost.test.yaml"
  MOCK_DOCKER_RC=7 run bash "$TESTS" "$WS"
  [ "$status" -eq 7 ]
  [[ "$output" == *"Gate A failed"* ]]
}

@test "run-tests: Dockerfile.test keeps old plumbing-OK semantics" {
  printf 'FROM scratch\n' > "$WS/Dockerfile.test"
  run bash "$TESTS" "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"treating as plumbing OK"* ]]
}

@test "run-tests: TEST_RUNNER_PLUGIN=none no-ops even with tests present" {
  printf 'runner:\n  command: ["true"]\n' > "$WS/outpost.test.yaml"
  TEST_RUNNER_PLUGIN=none run bash "$TESTS" "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Gate A: skipped"* ]]
}
