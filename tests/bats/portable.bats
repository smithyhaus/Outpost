#!/usr/bin/env bats
# Unit tests for platform/lib/portable.sh

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

# ----- detect_os -----
@test "detect_os sets SK_OS to one of supported values" {
  detect_os
  case "$SK_OS" in
    macos|linux|wsl2) : ;;
    *) fail "unexpected SK_OS=$SK_OS" ;;
  esac
}

# ----- gen_password -----
@test "gen_password returns 32 URL-safe chars" {
  out=$(gen_password)
  [ "${#out}" -eq 32 ]
  [[ "$out" =~ ^[A-Za-z0-9]+$ ]]
}

@test "gen_password is unique across calls" {
  a=$(gen_password); b=$(gen_password)
  [ "$a" != "$b" ]
}

# ----- render_template happy path -----
@test "render_template substitutes \${VAR}" {
  echo 'hello ${WHO}' > "$TMP/in.txt"
  WHO=world render_template "$TMP/in.txt" "$TMP/out.txt"
  run cat "$TMP/out.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

# ----- render_template anti-silent-failure (CRITICAL invariant #10) -----
@test "render_template aborts on unresolved \${VAR}" {
  echo 'value: ${UNSET_VAR_FOO_BAR}' > "$TMP/in.txt"
  unset UNSET_VAR_FOO_BAR || true
  run render_template "$TMP/in.txt" "$TMP/out.txt"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unresolved placeholders" ]]
  # Output file MUST be deleted on failure to avoid downstream confusion
  [ ! -e "$TMP/out.txt" ]
}

@test "render_template does not flag literal \$\$ escape" {
  printf 'literal: $$NOT_A_VAR\nvalue: ${OK_VAR}\n' > "$TMP/in.txt"
  OK_VAR=ok render_template "$TMP/in.txt" "$TMP/out.txt"
  run cat "$TMP/out.txt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "value: ok" ]]
}

# ----- portable_sed_i -----
@test "portable_sed_i replaces in place on current OS" {
  detect_os
  echo "old" > "$TMP/f.txt"
  portable_sed_i 's/old/new/' "$TMP/f.txt"
  run cat "$TMP/f.txt"
  [ "$output" = "new" ]
}

# ----- portable_stat_perm -----
@test "portable_stat_perm returns octal mode" {
  detect_os
  touch "$TMP/f.txt"
  chmod 600 "$TMP/f.txt"
  run portable_stat_perm "$TMP/f.txt"
  [ "$output" = "600" ]
}

# ----- require_cmd -----
@test "require_cmd succeeds for present commands" {
  run require_cmd bash sh
  [ "$status" -eq 0 ]
}

@test "require_cmd fails for missing commands" {
  run require_cmd bash this_command_definitely_does_not_exist_xyz123
  [ "$status" -ne 0 ]
}
