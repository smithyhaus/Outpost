#!/usr/bin/env bats
# =============================================================================
# Unit tests for platform/wsl2.sh — sk_assert_systemd preflight guard.
#
# WSL2's docker + k3s install both drive `systemctl`. If the distro was not
# booted with systemd as init, those calls fail half-applied mid-bootstrap.
# sk_assert_systemd fails fast with the exact remediation. The marker path is
# injectable via SK_SYSTEMD_MARKER so we can test both branches without a live
# systemd.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # log/ok/warn/err helpers live in portable.sh; wsl2.sh sources linux.sh.
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  # shellcheck source=../../platform/wsl2.sh
  source "${INFRA_ROOT}/platform/wsl2.sh"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
}

@test "sk_assert_systemd passes when the systemd marker dir exists" {
  SK_SYSTEMD_MARKER="$TMP" run sk_assert_systemd
  [ "$status" -eq 0 ]
  [[ "$output" =~ "systemd is active" ]]
}

@test "sk_assert_systemd fails fast with remediation when marker is missing" {
  SK_SYSTEMD_MARKER="$TMP/not-here" run sk_assert_systemd
  [ "$status" -ne 0 ]
  # Must surface the exact fix, not a bare failure.
  [[ "$output" =~ "wsl --shutdown" ]]
  [[ "$output" =~ "systemd=true" ]]
}

@test "sk_assert_systemd defaults to /run/systemd/system when marker unset" {
  # Without injection it must reference the canonical PID-1 systemd path.
  run grep -F '/run/systemd/system' "${INFRA_ROOT}/platform/wsl2.sh"
  [ "$status" -eq 0 ]
}
