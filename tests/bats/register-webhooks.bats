#!/usr/bin/env bats
# ===========================================================================
# Unit tests for scripts/register-webhooks.sh pure helpers (URL parsing,
# provider detection, token resolution, redaction). No network — the script is
# sourced with OUTPOST_NO_ENV=1 and a main-guard so only the functions load.
# ===========================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export OUTPOST_HOME="$INFRA_ROOT"
  export OUTPOST_NO_ENV=1                # don't read the real .env
  # shellcheck disable=SC1091
  source "$INFRA_ROOT/scripts/register-webhooks.sh"
}

# ---- URL parsing (https + scp-like git@) ----------------------------------
@test "repo_host: https URL" {
  [ "$(repo_host 'https://gitee.com/acme/app.git')" = "gitee.com" ]
}
@test "repo_host: git@ URL" {
  [ "$(repo_host 'git@github.com:acme/app.git')" = "github.com" ]
}
@test "repo_owner / repo_name: strips .git" {
  [ "$(repo_owner 'https://github.com/acme/app.git')" = "acme" ]
  [ "$(repo_name   'https://github.com/acme/app.git')" = "app" ]
}
@test "repo_owner: nested gitlab group path keeps the group as owner-prefix" {
  # group/sub/repo → owner=group/sub, name=repo (URL-encoded downstream)
  [ "$(repo_owner 'https://gitlab.com/group/sub/app.git')" = "group/sub" ]
  [ "$(repo_name  'https://gitlab.com/group/sub/app.git')" = "app" ]
}

# ---- provider detection ----------------------------------------------------
@test "provider_for_host: known hosts" {
  [ "$(provider_for_host gitee.com)"  = "gitee"  ]
  [ "$(provider_for_host github.com)" = "github" ]
  [ "$(provider_for_host gitlab.com)" = "gitlab" ]
}
@test "provider_for_host: self-hosted gitlab" {
  [ "$(provider_for_host gitlab.mycorp.com)" = "gitlab" ]
}
@test "provider_for_host: unknown host" {
  [ "$(provider_for_host git.example.org)" = "unknown" ]
}

# ---- token resolution ------------------------------------------------------
@test "token_for_host: primary host uses GIT_TOKEN" {
  GIT_HOST=gitee.com GIT_TOKEN=primary123 GIT_CREDENTIALS_EXTRA="" \
    run token_for_host gitee.com
  [ "$output" = "primary123" ]
}
@test "token_for_host: extra host uses GIT_CREDENTIALS_EXTRA entry" {
  GIT_HOST=gitee.com GIT_TOKEN=primary123 \
  GIT_CREDENTIALS_EXTRA="github.com|bot|ghp_extra999" \
    run token_for_host github.com
  [ "$output" = "ghp_extra999" ]
}
@test "token_for_host: unknown host returns empty (hard skip upstream)" {
  GIT_HOST=gitee.com GIT_TOKEN=primary123 GIT_CREDENTIALS_EXTRA="" \
    run token_for_host github.com
  [ -z "$output" ]
}

# ---- redaction never leaks the secret --------------------------------------
@test "redact: shows only last 4, never the full secret" {
  run redact "supersecretvalue1234"
  [ "$output" = "****1234" ]
  [[ "$output" != *"supersecret"* ]]
}
@test "redact: short secret is fully masked" {
  run redact "ab"
  [ "$output" = "****" ]
}

# ---- create-vs-update + dry-run branching (api() stubbed, no network) -------
# Stub api() to record the -K config it received and return a canned body, so we
# can assert the HTTP method chosen (POST=create vs PATCH/PUT=update) and that
# dry-run performs zero writes.
_stub_api() {                          # $1 = GET body to return
  STUB_GET="$1"
  call_api() {                         # mirrors the real contract: sets HTTP_CODE + BODY
    printf '%s\n===\n' "$1" >> "$CALLS"
    case "$1" in
      *'"GET"'*|*$'\nget'*) HTTP_CODE=200; BODY="$STUB_GET" ;;
      *)                    printf 'WRITE\n' >> "$CALLS"; HTTP_CODE=200; BODY='' ;;
    esac
  }
}

@test "ensure_github: empty hook list → CREATE via POST" {
  DRY_RUN=0; CALLS="$BATS_TEST_TMPDIR/c"; : > "$CALLS"
  _stub_api '[]'
  run _ensure_github acme app "https://hooks.example.com" "sekret" "tok"
  [ "$status" -eq 0 ]
  grep -q 'request = "POST"' "$CALLS"
  ! grep -q 'request = "PATCH"' "$CALLS"
}

@test "ensure_github: existing hook at same URL → UPDATE via PATCH on /hooks/<id>" {
  DRY_RUN=0; CALLS="$BATS_TEST_TMPDIR/c"; : > "$CALLS"
  _stub_api '[{"id":42,"config":{"url":"https://hooks.example.com"}}]'
  run _ensure_github acme app "https://hooks.example.com" "sekret" "tok"
  [ "$status" -eq 0 ]
  grep -q 'request = "PATCH"' "$CALLS"
  grep -q '/hooks/42' "$CALLS"
}

@test "ensure_github: dry-run performs the GET but NO write" {
  DRY_RUN=1; CALLS="$BATS_TEST_TMPDIR/c"; : > "$CALLS"
  _stub_api '[{"id":42,"config":{"url":"https://hooks.example.com"}}]'
  run _ensure_github acme app "https://hooks.example.com" "sekret" "tok"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'would UPDATE hook #42'
  ! grep -q 'WRITE' "$CALLS"
}

@test "ensure_gitlab: empty list → CREATE via POST (project path URL-encoded)" {
  DRY_RUN=0; CALLS="$BATS_TEST_TMPDIR/c"; : > "$CALLS"
  _stub_api '[]'
  run _ensure_gitlab gitlab.com group/sub app "https://hooks.example.com" "sekret" "tok"
  [ "$status" -eq 0 ]
  grep -q 'request = "POST"' "$CALLS"
  grep -q 'group%2Fsub%2Fapp' "$CALLS"    # @uri-encoded nested path
}

@test "reconcile_repo: URL with embedded credential is rejected (no leak, skip)" {
  # C1 regression: a token in the URL must never route auth or land in a log.
  DRY_RUN=1; CALLS="$BATS_TEST_TMPDIR/c"; : > "$CALLS"
  call_api() { printf 'CALLED\n' >> "$CALLS"; HTTP_CODE=200; BODY='[]'; }
  # host parses to 'ghp_SECRET@github.com' pre-fix; with the fix it is github.com,
  # but this repo has no matching token → skip. Either way: no secret in output.
  run reconcile_repo 'https://ghp_SECRETTOKEN@github.com/acme/app.git' "https://hooks.example.com" "sekret"
  [[ "$output" != *"ghp_SECRETTOKEN"* ]]
}

@test "repo_host: strips embedded userinfo/token from https URL" {
  [ "$(repo_host 'https://ghp_SECRET@github.com/acme/app.git')" = "github.com" ]
  [ "$(repo_host 'https://oauth2:glpat_x@gitlab.com/g/app.git')" = "gitlab.com" ]
}
