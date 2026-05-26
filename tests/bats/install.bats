#!/usr/bin/env bats
# =============================================================================
# install.sh — one-shot installer smoke tests.
#
# Exercises every code path that doesn't require a network clone:
#   - preflight tool detection
#   - mode auto-detection (ROOT_DOMAIN → full, absent → local)
#   - full-mode required-var enforcement
#   - .env rendering (caller-exported vars overwrite template values)
#   - OUTPOST_FORCE_ENV / OUTPOST_SKIP_BOOTSTRAP behavior
#
# The bootstrap.sh + git clone steps are stubbed by setting
# OUTPOST_SKIP_BOOTSTRAP=1 and pointing OUTPOST_DIR at a pre-populated
# scratch dir (a copy of the real repo).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALLER="${INFRA_ROOT}/install.sh"
  [ -x "$INSTALLER" ] || skip "install.sh not executable"

  TEST_TMPDIR="$(mktemp -d)"
  # Stage a fake "already cloned" outpost dir so render_env() can find
  # .env.example without us going to the network.
  mkdir -p "$TEST_TMPDIR/outpost"
  cp "${INFRA_ROOT}/.env.example" "$TEST_TMPDIR/outpost/.env.example"
  # Init a tiny git repo so fetch_repo's "already cloned" branch is taken
  # (the alternative would be a real `git clone` over the network).
  ( cd "$TEST_TMPDIR/outpost"
    git init --quiet
    git -c user.email=bats@test -c user.name=bats commit --quiet --allow-empty -m init
  )
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR}" ]] && rm -rf "$TEST_TMPDIR"
}

@test "install.sh: shellcheck-style bash syntax is valid" {
  run bash -n "$INSTALLER"
  [ "$status" -eq 0 ]
}

@test "install.sh: local mode auto-detected when ROOT_DOMAIN unset" {
  # OUTPOST_SKIP_BOOTSTRAP=1 stops after env render; we also need a
  # "pre-cloned" tree so fetch_repo doesn't try to update from a real remote.
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/outpost" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    OUTPOST_SKIP_FETCH=1 \
    OUTPOST_FORCE_ENV=1 \
    bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mode: local" ]]
  run grep -E '^OUTPOST_MODE=local$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
}

@test "install.sh: full mode auto-detected when ROOT_DOMAIN set" {
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/outpost" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    OUTPOST_SKIP_FETCH=1 \
    OUTPOST_FORCE_ENV=1 \
    ROOT_DOMAIN=example.com \
    CF_TUNNEL_TOKEN=tok \
    GIT_USER=u GIT_TOKEN=t \
    MANIFEST_REPO_URL=https://example.com/m \
    bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mode: full" ]]
  run grep -E '^ROOT_DOMAIN=example.com$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
  run grep -E '^CF_TUNNEL_TOKEN=tok$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
}

@test "install.sh: full mode rejects missing required vars" {
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/outpost" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    OUTPOST_SKIP_FETCH=1 \
    OUTPOST_FORCE_ENV=1 \
    OUTPOST_MODE=full \
    ROOT_DOMAIN=example.com \
    bash "$INSTALLER"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "CF_TUNNEL_TOKEN" ]]
  [[ "$output" =~ "GIT_USER" ]]
  [[ "$output" =~ "GIT_TOKEN" ]]
  [[ "$output" =~ "MANIFEST_REPO_URL" ]]
}

@test "install.sh: preserves existing .env unless OUTPOST_FORCE_ENV=1" {
  printf '# hand-edited config\nROOT_DOMAIN=preserved.example\n' \
    > "$TEST_TMPDIR/outpost/.env"
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/outpost" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    OUTPOST_SKIP_FETCH=1 \
    bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # Existing .env must still be there, untouched.
  run grep -E '^# hand-edited config$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
  run grep -E '^ROOT_DOMAIN=preserved.example$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
}

@test "install.sh: caller-exported vars overwrite template values" {
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/outpost" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    OUTPOST_SKIP_FETCH=1 \
    OUTPOST_FORCE_ENV=1 \
    REGISTRY_PLUGIN=aliyun-acr \
    GIT_PROVIDER_PLUGIN=github \
    bash "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -E '^REGISTRY_PLUGIN=aliyun-acr$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
  run grep -E '^GIT_PROVIDER_PLUGIN=github$' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
  # And the un-set var still carries the template default.
  run grep -E '^OUTPOST_MODE=' "$TEST_TMPDIR/outpost/.env"
  [ "$status" -eq 0 ]
}

@test "install.sh: refuses non-git OUTPOST_DIR collision" {
  # This test must exercise the real fetch_repo collision-detection branch,
  # so OUTPOST_SKIP_FETCH is NOT set. The die() fires before git is invoked.
  mkdir -p "$TEST_TMPDIR/colliding"
  touch "$TEST_TMPDIR/colliding/random-file"
  run env -i HOME="$TEST_TMPDIR" PATH="$PATH" \
    OUTPOST_DIR="$TEST_TMPDIR/colliding" \
    OUTPOST_SKIP_BOOTSTRAP=1 \
    bash "$INSTALLER"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not a git checkout" ]]
}
