#!/usr/bin/env bats
# =============================================================================
# Tests for platform/lib/cel-helpers.sh — WEBHOOK_REPO_WHITELIST → CEL list.
#
# A syntax error here breaks every PipelineRun admission. Worth fixture-locking.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/cel-helpers.sh
  source "${INFRA_ROOT}/platform/lib/cel-helpers.sh"
  unset WEBHOOK_REPO_WHITELIST CEL_WHITELIST_LIST
}

@test "empty WEBHOOK_REPO_WHITELIST → CEL_WHITELIST_LIST=[]" {
  unset WEBHOOK_REPO_WHITELIST
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "[]" ]
}

@test "empty-string WEBHOOK_REPO_WHITELIST → CEL_WHITELIST_LIST=[]" {
  export WEBHOOK_REPO_WHITELIST=""
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "[]" ]
}

@test "single URL → CEL list with one quoted element" {
  export WEBHOOK_REPO_WHITELIST="https://gitee.com/me/scm-mcp.git"
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "['https://gitee.com/me/scm-mcp.git']" ]
}

@test "two URLs → CEL list with both, comma-separated, no trailing comma" {
  export WEBHOOK_REPO_WHITELIST="https://a.git,https://b.git"
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "['https://a.git','https://b.git']" ]
}

@test "URLs with extra spaces are trimmed" {
  export WEBHOOK_REPO_WHITELIST="  https://a.git , https://b.git "
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "['https://a.git','https://b.git']" ]
}

@test "empty entries within the list are dropped" {
  export WEBHOOK_REPO_WHITELIST="https://a.git,,https://b.git"
  build_cel_whitelist
  [ "$CEL_WHITELIST_LIST" = "['https://a.git','https://b.git']" ]
}

@test "exports CEL_WHITELIST_LIST so envsubst sees it" {
  export WEBHOOK_REPO_WHITELIST="https://only.git"
  build_cel_whitelist
  bash -c 'echo "$CEL_WHITELIST_LIST"' | grep -q "only.git"
}

@test "rendered CEL is valid in the EventListener filter shape" {
  # The EventListener uses this rendered list inside:
  #   size(${CEL_WHITELIST_LIST}) == 0 || body.repository.git_http_url in ${CEL_WHITELIST_LIST}
  # Verify the resulting CEL is syntactically well-formed (matched brackets +
  # quoted strings).
  export WEBHOOK_REPO_WHITELIST="https://a.git,https://b.git"
  build_cel_whitelist
  # Count brackets — must be balanced [ ] pair.
  [ "$(echo "$CEL_WHITELIST_LIST" | tr -cd '[' | wc -c | tr -d ' ')" = "1" ]
  [ "$(echo "$CEL_WHITELIST_LIST" | tr -cd ']' | wc -c | tr -d ' ')" = "1" ]
  # Quotes count is 2 * num_entries (2 URLs → 4 single quotes).
  [ "$(echo "$CEL_WHITELIST_LIST" | tr -cd "'" | wc -c | tr -d ' ')" = "4" ]
}
