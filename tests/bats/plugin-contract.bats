#!/usr/bin/env bats
# Verify every plugin satisfies the contract

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "every plugin has plugin.yaml + preflight.sh + README.md" {
  while IFS= read -r dir; do
    [ -f "$dir/plugin.yaml" ] || fail "missing plugin.yaml in $dir"
    [ -f "$dir/preflight.sh" ] || fail "missing preflight.sh in $dir"
    [ -x "$dir/preflight.sh" ] || fail "preflight.sh not executable in $dir"
    [ -f "$dir/README.md" ] || fail "missing README.md in $dir"
    # at least one of manifest.yaml / compose.yaml
    [ -f "$dir/manifest.yaml" ] || [ -f "$dir/compose.yaml" ] || \
      fail "missing manifest.yaml or compose.yaml in $dir"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

@test "plugin.yaml carries kind + name fields" {
  while IFS= read -r f; do
    grep -q "^kind:" "$f"  || fail "missing 'kind:' in $f"
    grep -q "^name:" "$f"  || fail "missing 'name:' in $f"
  done < <(find "${INFRA_ROOT}/plugins" -name plugin.yaml)
}

@test "self-hosted preflight passes with no env" {
  env -i bash "${INFRA_ROOT}/plugins/registry/self-hosted/preflight.sh"
}

@test "aliyun-acr preflight fails when env missing" {
  run env -i bash "${INFRA_ROOT}/plugins/registry/aliyun-acr/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "ALIYUN_ACR" ]]
}

@test "git-provider preflight fails when env missing" {
  for p in gitee github gitlab; do
    run env -i bash "${INFRA_ROOT}/plugins/git-provider/$p/preflight.sh"
    [ "$status" -ne 0 ] || fail "$p preflight should have failed without env"
  done
}

@test "manifests use \${VAR} envsubst form (no __VAR__ leftovers)" {
  ! grep -rEn '__[A-Z_]+__' "${INFRA_ROOT}/plugins" "${INFRA_ROOT}/core" \
                            "${INFRA_ROOT}/examples" 2>/dev/null
}

# =============================================================================
# git-provider preflight: real authenticated `git ls-remote` probe (v0.3).
# `git` is stubbed on PATH so these run hermetically (no real network calls).
# =============================================================================

setup_git_stub() {
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/bin"
  cat > "$STAGE/bin/git" <<EOF
#!/bin/sh
echo "GIT_CALL: \$*" >> "$STAGE/git.log"
if [ "\$1" = "ls-remote" ]; then
  case "\$2" in
    *"${GIT_STUB_FAIL_MARKER:-__never_matches__}"*) exit 128 ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOF
  chmod +x "$STAGE/bin/git"
  # Stub curl so the GitHub API check never hits the real network. Exit code
  # controlled by CURL_STUB_HTTP_CODE (defaults to 200 = auth OK).
  cat > "$STAGE/bin/curl" <<EOF
#!/bin/sh
echo "CURL_CALL: \$*" >> "$STAGE/curl.log"
printf '%s' "${CURL_STUB_HTTP_CODE:-200}"
exit 0
EOF
  chmod +x "$STAGE/bin/curl"
  export PATH="$STAGE/bin:$PATH"
}

teardown_git_stub() {
  [ -n "${STAGE:-}" ] && rm -rf "$STAGE" || true
}

@test "gitee preflight: no matching OUTPOST_REPOS entry → WARN, exit 0, no git calls" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="https://github.com/org/other.git" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no OUTPOST_REPOS entry matches" ]]
  [ ! -f "$STAGE/git.log" ]
  teardown_git_stub
}

@test "gitee preflight: matching entry + successful ls-remote → passes" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="https://gitee.com/org/svc-a.git" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -eq 0 ]
  grep -q "GIT_CALL: ls-remote" "$STAGE/git.log"
  teardown_git_stub
}

@test "gitee preflight: matching entry + failing ls-remote → FAILs loudly, names the repo" {
  export GIT_STUB_FAIL_MARKER="svc-bad"
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="https://gitee.com/org/svc-bad.git" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "ls-remote FAILED" ]]
  [[ "$output" =~ "svc-bad" ]]
  teardown_git_stub
  unset GIT_STUB_FAIL_MARKER
}

@test "gitee preflight: entry on an unrelated host resolved via GIT_CREDENTIALS_EXTRA is not probed by gitee" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="https://github.com/org/svc-a.git" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$STAGE/git.log" ]
  teardown_git_stub
}

@test "gitee preflight: matching entry with no resolvable credentials → FAILs with a clear hint" {
  setup_git_stub
  # GIT_HOST is a DIFFERENT host (not gitee.com), so the primary pair doesn't
  # cover this entry, and no GIT_CREDENTIALS_EXTRA entry fills the gap.
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=example.com \
    OUTPOST_REPOS="https://gitee.com/org/svc-a.git" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no credentials" ]]
  [ ! -f "$STAGE/git.log" ]
  teardown_git_stub
}

@test "gitee preflight: matching entry resolved via GIT_CREDENTIALS_EXTRA (non-primary host)" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=example.com \
    OUTPOST_REPOS="https://gitee.com/org/svc-a.git" \
    GIT_CREDENTIALS_EXTRA="gitee.com|bot|tok" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitee/preflight.sh"
  [ "$status" -eq 0 ]
  grep -q "GIT_CALL: ls-remote" "$STAGE/git.log"
  teardown_git_stub
}

@test "github preflight: GITHUB_RUNNER_URL/PAT both empty → WARN, does not fail" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "runner install/checks skipped" ]]
  teardown_git_stub
}

@test "github preflight: only ONE of GITHUB_RUNNER_URL/PAT set → FAILs (partial config)" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" GITHUB_RUNNER_URL="https://github.com/myorg" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must both be set together" ]]
  teardown_git_stub
}

@test "github preflight: bad GITHUB_RUNNER_URL shape → FAILs" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" GITHUB_RUNNER_URL="not-a-url" GITHUB_RUNNER_PAT="tok" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GITHUB_RUNNER_URL must look like" ]]
  teardown_git_stub
}

@test "github preflight: GITHUB_RUNNER_PAT fails GitHub API auth (stubbed 401) → FAILs" {
  export CURL_STUB_HTTP_CODE="401"
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" GITHUB_RUNNER_URL="https://github.com/myorg" GITHUB_RUNNER_PAT="tok" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "failed to authenticate" ]]
  grep -q "CURL_CALL:" "$STAGE/curl.log"
  teardown_git_stub
  unset CURL_STUB_HTTP_CODE
}

@test "github preflight: GITHUB_RUNNER_PAT authenticates (stubbed 200) → passes" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" GITHUB_RUNNER_URL="https://github.com/myorg" GITHUB_RUNNER_PAT="tok" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [ "$status" -eq 0 ]
  teardown_git_stub
}

@test "github preflight: PAT masked — never appears in output even on failure" {
  export CURL_STUB_HTTP_CODE="401"
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="" GITHUB_RUNNER_URL="https://github.com/myorg" GITHUB_RUNNER_PAT="SUPER_SECRET_PAT_VALUE" \
    bash "${INFRA_ROOT}/plugins/git-provider/github/preflight.sh"
  [[ "$output" != *"SUPER_SECRET_PAT_VALUE"* ]]
  teardown_git_stub
  unset CURL_STUB_HTTP_CODE
}

@test "gitlab preflight: matches self-hosted hosts via the gitlab. substring heuristic" {
  setup_git_stub
  run env -i PATH="$PATH" GIT_USER=u GIT_TOKEN=t GIT_HOST=gitee.com \
    OUTPOST_REPOS="https://gitlab.corp.example/org/svc.git" \
    GIT_CREDENTIALS_EXTRA="gitlab.corp.example|bot|tok" \
    bash "${INFRA_ROOT}/plugins/git-provider/gitlab/preflight.sh"
  [ "$status" -eq 0 ]
  grep -q "GIT_CALL: ls-remote" "$STAGE/git.log"
  teardown_git_stub
}
