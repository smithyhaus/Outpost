#!/usr/bin/env bash
# =============================================================================
# Webhook signing helpers — mirrored from notify-task.yaml's inline fanout
# script. The Tekton Task can't easily source this file at runtime (cross-
# namespace + alpine container without our codebase), so the math lives in
# BOTH places. **Keep them in sync.**
# -----------------------------------------------------------------------------
# Tested by tests/bats/sign-webhook.bats with fixtures captured from DingTalk
# and Feishu public docs. If you change the math, the fixtures break — that's
# the point.
#
# Each helper writes the signature to stdout. Pure function: no exports.
# =============================================================================

# DingTalk signed webhook:
#   string_to_sign = "${timestamp}\n${secret}"
#   signature      = base64(HMAC-SHA256(string_to_sign, secret))
# URL gets `&timestamp=...&sign=<urlencoded>` appended.
sign_dingtalk() {
  local ts="$1" secret="$2"
  printf '%s\n%s' "$ts" "$secret" \
    | openssl dgst -sha256 -hmac "$secret" -binary \
    | base64
}

# Feishu signed webhook: SAME math as DingTalk (string_to_sign + HMAC-SHA256
# + base64), but the signature goes into the JSON body envelope (not the URL).
sign_feishu() {
  local ts="$1" secret="$2"
  printf '%s\n%s' "$ts" "$secret" \
    | openssl dgst -sha256 -hmac "$secret" -binary \
    | base64
}

# Minimal URL-encode for what HMAC-SHA256 base64 output produces: +, /, =.
# Used after sign_dingtalk to safely append the signature to a query string.
urlencode_sig() {
  local sig="$1"
  printf '%s' "$sig" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g'
}
