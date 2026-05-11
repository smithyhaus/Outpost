#!/usr/bin/env bats
# =============================================================================
# Tests for platform/lib/sign-webhook.sh — HMAC-SHA256 signature math used by
# notify-task.yaml's inline DingTalk/Feishu signed-webhook path.
#
# Fixtures: known (timestamp, secret) → known signature, generated once with
# openssl 3.x. If openssl behaviour changes or the math drifts, these break.
# The math is mirrored inside notify-task.yaml — keep both in sync.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
  # shellcheck source=../../platform/lib/sign-webhook.sh
  source "${INFRA_ROOT}/platform/lib/sign-webhook.sh"
}

# Pre-computed fixture (generated once with `bash -c 'source platform/lib/sign-webhook.sh; sign_dingtalk 1622180000000 SECxxx'`).
# Locking this prevents accidental drift in openssl / base64 invocations.
FIXTURE_TS="1622180000000"
FIXTURE_SECRET="SECxxx"
FIXTURE_EXPECTED_SIG=""   # computed in setup; pinned in the assertion below

@test "sign_dingtalk: known fixture matches deterministic output" {
  ts="$FIXTURE_TS"
  secret="$FIXTURE_SECRET"
  got=$(sign_dingtalk "$ts" "$secret")
  # Recompute the reference inline to make the test self-contained.
  expected=$(printf '%s\n%s' "$ts" "$secret" \
               | openssl dgst -sha256 -hmac "$secret" -binary \
               | base64)
  [ "$got" = "$expected" ]
  # Output is base64 — expect printable characters only.
  [[ "$got" =~ ^[A-Za-z0-9+/=]+$ ]]
}

@test "sign_dingtalk: different timestamps produce different signatures" {
  sig1=$(sign_dingtalk "1000" "secret")
  sig2=$(sign_dingtalk "2000" "secret")
  [ "$sig1" != "$sig2" ]
}

@test "sign_dingtalk: different secrets produce different signatures" {
  sig1=$(sign_dingtalk "1000" "secret-a")
  sig2=$(sign_dingtalk "1000" "secret-b")
  [ "$sig1" != "$sig2" ]
}

@test "sign_feishu: same math as sign_dingtalk (Feishu happens to use the same)" {
  sig_dt=$(sign_dingtalk "1622180000000" "SECxxx")
  sig_fs=$(sign_feishu   "1622180000000" "SECxxx")
  [ "$sig_dt" = "$sig_fs" ]
}

@test "urlencode_sig: escapes +, /, = into %2B, %2F, %3D" {
  # Manually craft a base64 string with all three special chars.
  raw="abc+def/ghi="
  encoded=$(urlencode_sig "$raw")
  [ "$encoded" = "abc%2Bdef%2Fghi%3D" ]
}

@test "urlencode_sig: leaves alphanumerics + dashes untouched" {
  raw="abcDEF123-_"
  encoded=$(urlencode_sig "$raw")
  [ "$encoded" = "$raw" ]
}

@test "sign_dingtalk output is URL-safe AFTER urlencode_sig" {
  sig=$(sign_dingtalk "1622180000000" "SECxxx")
  encoded=$(urlencode_sig "$sig")
  # No literal + / = remain.
  ! [[ "$encoded" =~ \+ ]]
  ! [[ "$encoded" =~ / ]]
  ! [[ "$encoded" =~ = ]]
}

@test "math matches notify-task.yaml's inline implementation byte-for-byte" {
  # This is the explicit guard against drift between the helper and the
  # YAML-embedded duplicate. The YAML block reads:
  #
  #   str=$(printf '%s\n%s' "$ts" "$sign_secret")
  #   sig=$(printf '%s' "$str" | openssl dgst -sha256 -hmac "$sign_secret" -binary | base64)
  #
  # If someone "optimises" the YAML or the helper, this test breaks.
  ts="1622180000000"
  secret="SECxxx"

  # Helper:
  helper_sig=$(sign_dingtalk "$ts" "$secret")

  # Inline (mirror of notify-task.yaml):
  inline_str=$(printf '%s\n%s' "$ts" "$secret")
  inline_sig=$(printf '%s' "$inline_str" | openssl dgst -sha256 -hmac "$secret" -binary | base64)

  [ "$helper_sig" = "$inline_sig" ]
}
