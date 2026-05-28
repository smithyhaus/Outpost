#!/usr/bin/env bats
# =============================================================================
# env_kv → .env → source round-trip safety.
#
# Guards a class of silent .env corruption that has bitten the project before:
# values containing shell metacharacters (spaces, &, =, ", [, ], ', $) would
# survive into .env via a naive `echo "KEY=$VAR"` BUT come back wrong on the
# next `source .env`. Concrete failure modes covered here:
#   - URLs with & : `URL=https://x?a=1&b=2` reads as TWO commands, dropping
#     the tail; the new bootstrap then re-renders templates with the
#     truncated URL and silently delivers wrong notifications.
#   - Kaniko args with spaces : `--cache=true --skip-tls-verify` re-sources
#     to `KANIKO_EXTRA_ARGS=--cache=true` then runs `--skip-tls-verify` as
#     a foreground command (which `command not found`s).
#   - JSON arrays with " : CEL_WHITELIST_LIST defaulting to [] is safe,
#     but a populated `["a/b","c/d"]` would corrupt on round-trip.
#
# Each test writes a value through env_kv to a temp file, sources it back,
# and asserts the assigned value equals the original byte-for-byte.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  TMP="$(mktemp -d)"
  ENV_FILE="${TMP}/test.env"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

# Helper: write KEY=VALUE via env_kv, source it back, echo what landed.
_roundtrip() {
  local key="$1" expected="$2"
  env_kv "$key" "$expected" > "$ENV_FILE"
  # Source in a subshell so test env stays clean.
  ( set -a; source "$ENV_FILE"; set +a; eval "printf '%s' \"\$$key\"" )
}

@test "env_kv: plain value (no metacharacters) round-trips" {
  v="$(_roundtrip MY_VAR 'hello-world-123')"
  [ "$v" = "hello-world-123" ]
}

@test "env_kv: empty value round-trips to empty string" {
  v="$(_roundtrip MY_VAR '')"
  [ "$v" = "" ]
}

@test "env_kv: value with single space survives" {
  v="$(_roundtrip KANIKO_EXTRA_ARGS '--cache=true --skip-tls-verify')"
  [ "$v" = "--cache=true --skip-tls-verify" ]
}

@test "env_kv: value with multiple spaces survives" {
  # cron expressions in the wild — 5 fields separated by spaces.
  v="$(_roundtrip OUTPOST_TEKTON_PRUNE_SCHEDULE '0 * * * *')"
  [ "$v" = "0 * * * *" ]
}

@test "env_kv: URL with & (webhook query string) survives" {
  # The pre-fix bug: re-sourcing would execute &b=2 as background command,
  # truncating the URL.
  v="$(_roundtrip DINGTALK_WEBHOOK_URL 'https://oapi.dingtalk.com/robot/send?access_token=xyz&sign=abc')"
  [ "$v" = "https://oapi.dingtalk.com/robot/send?access_token=xyz&sign=abc" ]
}

@test "env_kv: URL with multiple query params + reserved chars" {
  v="$(_roundtrip GENERIC_WEBHOOK_URL 'https://api.example.com/v1/hook?a=1&b=2&c=3+4&d=foo%20bar')"
  [ "$v" = 'https://api.example.com/v1/hook?a=1&b=2&c=3+4&d=foo%20bar' ]
}

@test "env_kv: JSON array string with embedded \" round-trips" {
  v="$(_roundtrip CEL_WHITELIST_LIST '["org/repo-a","org/repo-b"]')"
  [ "$v" = '["org/repo-a","org/repo-b"]' ]
}

@test "env_kv: value with single quote survives" {
  v="$(_roundtrip MY_VAR "it's a test")"
  [ "$v" = "it's a test" ]
}

@test "env_kv: value with $ (literal dollar sign, no expansion)" {
  # If env_kv quoted with double-quotes, $foo would expand. With %q (which
  # uses backslash or single quotes), the literal $ survives.
  v="$(_roundtrip MY_VAR 'cost is $5.99')"
  [ "$v" = 'cost is $5.99' ]
}

@test "env_kv: value with backslash" {
  v="$(_roundtrip MY_VAR 'C:\path\to\file')"
  [ "$v" = 'C:\path\to\file' ]
}

@test "env_kv: value with leading/trailing whitespace" {
  v="$(_roundtrip MY_VAR '  spaces around  ')"
  [ "$v" = '  spaces around  ' ]
}

@test "env_kv output is one line (no trailing newline within the value)" {
  env_kv MY_VAR "single-line" > "$ENV_FILE"
  [ "$(wc -l <"$ENV_FILE" | tr -d ' ')" = "1" ]
}

# ---- Regression guard: phase 2 uses env_kv for known-risky vars -------------

@test "phase 2 routes KANIKO_EXTRA_ARGS through env_kv (was line 240 bug)" {
  # The original report. A future maintainer reverting to bare `echo
  # "KANIKO_EXTRA_ARGS=$VAR"` would re-introduce silent corruption when
  # the value contains a space (which kaniko configs commonly do).
  grep -qE 'env_kv KANIKO_EXTRA_ARGS' "${INFRA_ROOT}/bootstrap.d/02-config.sh" \
    || fail "KANIKO_EXTRA_ARGS no longer routed through env_kv"
}

@test "phase 2 routes all NOTIFY_*_WEBHOOK_URL through env_kv (& in URL)" {
  for var in DINGTALK_WEBHOOK_URL FEISHU_WEBHOOK_URL WECOM_WEBHOOK_URL GENERIC_WEBHOOK_URL; do
    grep -qE "env_kv ${var}" "${INFRA_ROOT}/bootstrap.d/02-config.sh" \
      || { echo "$var no longer routed through env_kv"; return 1; }
  done
}

@test "phase 2 routes CEL_WHITELIST_LIST through env_kv (JSON array)" {
  grep -qE 'env_kv CEL_WHITELIST_LIST' "${INFRA_ROOT}/bootstrap.d/02-config.sh"
}
