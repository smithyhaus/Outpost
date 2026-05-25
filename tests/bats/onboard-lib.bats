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
