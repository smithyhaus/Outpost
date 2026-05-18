#!/usr/bin/env bats
# =============================================================================
# Tests for the top-level Makefile install/uninstall targets.
#
# Uses a per-test temp PREFIX so we never touch the host's /usr/local/bin.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PREFIX=$(mktemp -d)
  cd "$INFRA_ROOT"
}

teardown() {
  [ -n "${PREFIX:-}" ] && rm -rf "$PREFIX" || true
}

@test "make help: lists install + uninstall + version targets" {
  run make help PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ install ]]
  [[ "$output" =~ uninstall ]]
  [[ "$output" =~ version ]]
}

@test "make install: creates symlink pointing at scripts/outpost" {
  run make install PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [ -L "$PREFIX/outpost" ]
  cur=$(readlink "$PREFIX/outpost")
  [ "$cur" = "$INFRA_ROOT/scripts/outpost" ]
}

@test "make install: invoking through PREFIX runs the CLI" {
  make install PREFIX="$PREFIX" >/dev/null
  run "$PREFIX/outpost" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ outpost ]]
}

@test "make install: idempotent — second run is a no-op" {
  make install PREFIX="$PREFIX" >/dev/null
  run make install PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no-op" ]]
}

@test "make install: refuses to clobber a non-symlink stranger file" {
  echo "stranger" > "$PREFIX/outpost"
  run make install PREFIX="$PREFIX"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "refusing to clobber" ]]
  # File should remain untouched
  [ "$(cat "$PREFIX/outpost")" = "stranger" ]
}

@test "make install: replaces stale symlink pointing elsewhere" {
  ln -s /etc/hosts "$PREFIX/outpost"
  run make install PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "replacing" ]]
  cur=$(readlink "$PREFIX/outpost")
  [ "$cur" = "$INFRA_ROOT/scripts/outpost" ]
}

@test "make install: warns when PREFIX not on PATH (in temp dir, it isn't)" {
  run make install PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not on your PATH" ]]
}

@test "make uninstall: removes the symlink we installed" {
  make install PREFIX="$PREFIX" >/dev/null
  run make uninstall PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed" ]]
  [ ! -e "$PREFIX/outpost" ]
}

@test "make uninstall: clean no-op when nothing to remove" {
  run make uninstall PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing to do" ]]
}

@test "make uninstall: refuses to remove a symlink we don't own" {
  ln -s /etc/hosts "$PREFIX/outpost"
  run make uninstall PREFIX="$PREFIX"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "refusing to remove" ]]
  # The stranger symlink should still be there
  [ -L "$PREFIX/outpost" ]
}

@test "make version: invokes outpost CLI" {
  run make version PREFIX="$PREFIX"
  [ "$status" -eq 0 ]
  [[ "$output" =~ outpost ]]
}
