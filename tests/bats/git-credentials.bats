#!/usr/bin/env bats
# =============================================================================
# Tests for platform/lib/git-credentials.sh (render_git_credentials_extra)
#
# Multi-host clone credentials. A wrong annotation index or a dropped host line
# means Tekton's git-clone silently fails to auth for that provider — so pin
# the emitted Secret's shape (host-N annotations + .git-credentials lines).
# Tokens below are SYNTHETIC.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  # shellcheck source=../../platform/lib/git-credentials.sh
  source "${INFRA_ROOT}/platform/lib/git-credentials.sh"

  export GIT_HOST="gitee.com"
  export GIT_USER="primaryuser"
  export GIT_TOKEN="primary_pat_000"
  unset GIT_CREDENTIALS_EXTRA
}

# ---- 1. primary-only (empty extras) -----------------------------------------

@test "extra empty: emits primary host-0 only, with .gitconfig" {
  run render_git_credentials_extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: git-credentials"* ]]
  [[ "$output" == *"tekton.dev/git-0: https://gitee.com"* ]]
  [[ "$output" != *"tekton.dev/git-1"* ]]
  [[ "$output" == *"https://primaryuser:primary_pat_000@gitee.com"* ]]
  # .gitconfig block must stay byte-compatible with secrets.template.yaml
  [[ "$output" == *"helper = store"* ]]
  [[ "$output" == *"name = Tekton CI"* ]]
}

# ---- 2. multi-host happy path -----------------------------------------------

@test "extra two hosts: emits git-0/git-1/git-2 + three credential lines" {
  export GIT_CREDENTIALS_EXTRA="github.com|ghuser|ghp_synthetic_111,gitlab.corp.example|gluser|glpat_synthetic_222"
  run render_git_credentials_extra
  [ "$status" -eq 0 ]
  # Exactly one Secret object.
  [ "$(grep -c '^kind: Secret' <<< "$output")" -eq 1 ]
  # Three host annotations, indexed 0..2.
  [[ "$output" == *"tekton.dev/git-0: https://gitee.com"* ]]
  [[ "$output" == *"tekton.dev/git-1: https://github.com"* ]]
  [[ "$output" == *"tekton.dev/git-2: https://gitlab.corp.example"* ]]
  # Three .git-credentials lines (primary + 2 extras).
  [ "$(grep -c 'https://[^ ]*@' <<< "$output")" -eq 3 ]
  [[ "$output" == *"https://ghuser:ghp_synthetic_111@github.com"* ]]
  [[ "$output" == *"https://gluser:glpat_synthetic_222@gitlab.corp.example"* ]]
}

@test "extra: surrounding whitespace between entries is tolerated" {
  export GIT_CREDENTIALS_EXTRA="github.com|ghuser|ghp_synthetic_111 , gitlab.corp.example|gluser|glpat_synthetic_222"
  run render_git_credentials_extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"tekton.dev/git-1: https://github.com"* ]]
  [[ "$output" == *"tekton.dev/git-2: https://gitlab.corp.example"* ]]
}

# ---- 3. malformed input fails loudly (no silent skip) -----------------------

@test "extra: entry missing the token field fails clearly" {
  export GIT_CREDENTIALS_EXTRA="github.com|ghuser"
  run render_git_credentials_extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "bad GIT_CREDENTIALS_EXTRA" ]]
}

@test "extra: host carrying a scheme is rejected" {
  export GIT_CREDENTIALS_EXTRA="https://github.com|ghuser|ghp_synthetic_111"
  run render_git_credentials_extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "bad GIT_CREDENTIALS_EXTRA" ]]
}

@test "extra: host carrying a path is rejected" {
  export GIT_CREDENTIALS_EXTRA="github.com/org|ghuser|ghp_synthetic_111"
  run render_git_credentials_extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "bad GIT_CREDENTIALS_EXTRA" ]]
}

@test "extra: missing primary GIT_HOST aborts" {
  unset GIT_HOST
  export GIT_CREDENTIALS_EXTRA="github.com|ghuser|ghp_synthetic_111"
  run render_git_credentials_extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GIT_HOST" ]]
}

# ---- 4. YAML-special chars in token are safe (literal-block scalar) ----------

@test "extra: token with '#' and '@' lands verbatim in the .git-credentials line" {
  # In a YAML literal block ('|'), '#' is NOT a comment and '@' is ordinary —
  # so a token carrying them must round-trip unchanged, not get truncated.
  export GIT_CREDENTIALS_EXTRA="github.com|ghuser|ghp_syn#th@etic"
  run render_git_credentials_extra
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://ghuser:ghp_syn#th@etic@github.com"* ]]
  # The token must not have leaked into any comment or been dropped.
  [ "$(grep -c 'https://[^ ]*@github.com' <<< "$output")" -eq 1 ]
}

# ---- 5. malformed entry never echoes the token (no PAT in logs) --------------

@test "extra: a bad entry's error message omits the token" {
  export GIT_CREDENTIALS_EXTRA="github.com:443|ghuser|ghp_secret_should_not_log"
  run render_git_credentials_extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "bad GIT_CREDENTIALS_EXTRA" ]]
  # The PAT must NOT appear anywhere in the error output.
  [[ "$output" != *"ghp_secret_should_not_log"* ]]
}
