#!/usr/bin/env bats
# =============================================================================
# Unit tests for platform/lib/onboard-lib.sh — the pure helpers behind the
# v0.4 onboard primitives. Each function is exercised in isolation.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/onboard-lib.sh
  source "${INFRA_ROOT}/platform/lib/onboard-lib.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# ---- onboard_db_name --------------------------------------------------------
@test "onboard_db_name: a hyphen becomes an underscore" {
  [ "$(onboard_db_name 'hello-go')" = "hello_go" ]
}

@test "onboard_db_name: uppercase is lowercased" {
  [ "$(onboard_db_name 'MyApp')" = "myapp" ]
}

@test "onboard_db_name: a leading digit is prefixed app_" {
  [ "$(onboard_db_name '9lives')" = "app_9lives" ]
}

@test "onboard_db_name: dots and slashes become underscores" {
  [ "$(onboard_db_name 'a.b/c')" = "a_b_c" ]
}

# ---- onboard_json_esc -------------------------------------------------------
@test "onboard_json_esc: backslash and double-quote are escaped" {
  [ "$(onboard_json_esc 'a"b\c')" = 'a\"b\\c' ]
}

@test "onboard_json_esc: a newline becomes a space" {
  [ "$(onboard_json_esc "$(printf 'a\nb')")" = "a b" ]
}

# ---- onboard_emit_json ------------------------------------------------------
@test "onboard_emit_json: zero files yields an empty written_files array" {
  run onboard_emit_json db.create created "made it" "do the next thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"written_files":[]'* ]]
  [[ "$output" == *'"step":"db.create"'* ]]
}

@test "onboard_emit_json: two files both appear, output is valid JSON" {
  command -v jq >/dev/null || skip "jq not available"
  run onboard_emit_json manifest.scaffold scaffolded "did it" "review" /a/b.yaml /c/d.yaml
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  echo "$output" | jq -e '.written_files | length == 2' >/dev/null
  echo "$output" | jq -e '.written_files[0] == "/a/b.yaml"' >/dev/null
}

@test "onboard_emit_json: a value with a double-quote stays valid JSON" {
  command -v jq >/dev/null || skip "jq not available"
  run onboard_emit_json db.create error 'database "x" failed' "retry"
  echo "$output" | jq -e '.detail == "database \"x\" failed"' >/dev/null
}

# ---- onboard_files_identical ------------------------------------------------
@test "onboard_files_identical: identical files return 0" {
  printf 'same\n' > "$TMP/a"
  printf 'same\n' > "$TMP/b"
  run onboard_files_identical "$TMP/a" "$TMP/b"
  [ "$status" -eq 0 ]
}

@test "onboard_files_identical: differing files return non-zero" {
  printf 'one\n' > "$TMP/a"
  printf 'two\n' > "$TMP/b"
  run onboard_files_identical "$TMP/a" "$TMP/b"
  [ "$status" -ne 0 ]
}

@test "onboard_files_identical: a missing file returns non-zero" {
  printf 'one\n' > "$TMP/a"
  run onboard_files_identical "$TMP/a" "$TMP/nope"
  [ "$status" -ne 0 ]
}

# ---- onboard_render_subst ---------------------------------------------------
@test "onboard_render_subst: applies a sed expression to the output" {
  printf 'hello FOO world\n' > "$TMP/src"
  onboard_render_subst "$TMP/src" "$TMP/dst" 's|FOO|bar|g'
  [ "$(cat "$TMP/dst")" = "hello bar world" ]
}

@test "onboard_render_subst: applies multiple expressions in order" {
  printf 'a b c\n' > "$TMP/src"
  onboard_render_subst "$TMP/src" "$TMP/dst" 's|a|X|' 's|c|Z|'
  [ "$(cat "$TMP/dst")" = "X b Z" ]
}

@test "onboard_render_subst: with no expressions copies the file verbatim" {
  printf 'untouched\n' > "$TMP/src"
  onboard_render_subst "$TMP/src" "$TMP/dst"
  [ "$(cat "$TMP/dst")" = "untouched" ]
}

# ---- onboard_repos_add -------------------------------------------------------

@test "onboard_repos_add: empty current value → single entry, no branch" {
  [ "$(onboard_repos_add "" "https://gitee.com/org/a.git")" = "https://gitee.com/org/a.git" ]
}

@test "onboard_repos_add: empty current value → single entry WITH branch" {
  out=$(onboard_repos_add "" "https://gitee.com/org/a.git" "release")
  [ "$out" = "https://gitee.com/org/a.git#release" ]
}

@test "onboard_repos_add: appends to a non-empty list" {
  out=$(onboard_repos_add "https://gitee.com/org/a.git" "https://gitee.com/org/b.git")
  [ "$out" = "https://gitee.com/org/a.git,https://gitee.com/org/b.git" ]
}

@test "onboard_repos_add: idempotent — same URL already present (no branch) is unchanged" {
  cur="https://gitee.com/org/a.git,https://gitee.com/org/b.git"
  out=$(onboard_repos_add "$cur" "https://gitee.com/org/a.git")
  [ "$out" = "$cur" ]
}

@test "onboard_repos_add: idempotent — same URL already present WITH a branch is unchanged (no dupe, no branch drop)" {
  cur="https://gitee.com/org/a.git#release"
  out=$(onboard_repos_add "$cur" "https://gitee.com/org/a.git")
  [ "$out" = "$cur" ]
}

# ---- onboard_repos_remove ----------------------------------------------------

@test "onboard_repos_remove: removes the matching entry, keeps the rest" {
  cur="https://gitee.com/org/a.git,https://gitee.com/org/b.git"
  out=$(onboard_repos_remove "$cur" "https://gitee.com/org/a.git")
  [ "$out" = "https://gitee.com/org/b.git" ]
}

@test "onboard_repos_remove: matches regardless of the entry's branch suffix" {
  cur="https://gitee.com/org/a.git#release,https://gitee.com/org/b.git"
  out=$(onboard_repos_remove "$cur" "https://gitee.com/org/a.git")
  [ "$out" = "https://gitee.com/org/b.git" ]
}

@test "onboard_repos_remove: removing the only entry yields an empty string" {
  out=$(onboard_repos_remove "https://gitee.com/org/a.git" "https://gitee.com/org/a.git")
  [ "$out" = "" ]
}

@test "onboard_repos_remove: no match → list returned unchanged" {
  cur="https://gitee.com/org/a.git,https://gitee.com/org/b.git"
  out=$(onboard_repos_remove "$cur" "https://gitee.com/org/nope.git")
  [ "$out" = "$cur" ]
}

# ---- onboard_ci_instructions / onboard_ci_offboard_instructions -------------

@test "onboard_ci_instructions: mentions the workflow template copy + dual-push" {
  out=$(onboard_ci_instructions "https://gitee.com/org/a.git" "/opt/infras")
  [[ "$out" == *"templates/github/outpost-build.yml"* ]]
  [[ "$out" == *"dual-push"* ]]
  [[ "$out" == *"push-mirror"* ]]
}

@test "onboard_ci_offboard_instructions: mentions OUTPOST_REPOS + workflow cleanup" {
  out=$(onboard_ci_offboard_instructions "https://gitee.com/org/a.git")
  [[ "$out" == *"OUTPOST_REPOS"* ]]
  [[ "$out" == *"outpost-build.yml"* ]]
}
