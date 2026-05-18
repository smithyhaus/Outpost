#!/usr/bin/env bats
# =============================================================================
# Tests for scripts/notify-fanout.sh — extracted from notify-task.yaml v0.3.
#
# Real webhook delivery is mocked (curl stubbed). What we lock down:
#   - POSIX sh syntax (shellcheck + sh -n)
#   - PAYLOAD JSON parsing → NOTIFY_* env exports
#   - per-provider skip semantics when secrets/templates aren't mounted
#   - signing math is sourced from sign-webhook.sh (no duplication)
#   - graceful no-op when PROVIDERS is empty
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${INFRA_ROOT}/scripts/notify-fanout.sh"

  command -v jq >/dev/null 2>&1      || skip "jq not installed"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not installed"

  # Stage a fake /scripts dir holding sign-webhook.sh so the script's
  # `. /scripts/sign-webhook.sh` resolves under test. We patch the script
  # source path by running it through a small wrapper that pre-sets
  # /scripts to the test dir.
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/scripts" "$STAGE/secrets" "$STAGE/templates" "$STAGE/bin"
  cp "${INFRA_ROOT}/platform/lib/sign-webhook.sh" "$STAGE/scripts/"

  # Make a per-test copy of the script with the source path rewritten
  # to the staged location (avoids needing actual /scripts on the host).
  TEST_SCRIPT="$STAGE/notify-fanout.sh"
  sed "s|/scripts/sign-webhook.sh|${STAGE}/scripts/sign-webhook.sh|g; s|/secrets|${STAGE}/secrets|g; s|/templates|${STAGE}/templates|g" \
    "$SCRIPT" > "$TEST_SCRIPT"
  chmod +x "$TEST_SCRIPT"

  # Stub curl that records calls instead of actually hitting the network.
  cat > "$STAGE/bin/curl" <<'EOF'
#!/bin/sh
# Capture all args + stdin into a log we can assert on.
echo "CURL_CALL: $*" >> "$STAGE/curl.log"
[ -t 0 ] || cat >> "$STAGE/curl.log"
exit 0
EOF
  chmod +x "$STAGE/bin/curl"
  export STAGE
  export PATH="$STAGE/bin:$PATH"
}

teardown() {
  [ -n "${STAGE:-}" ] && rm -rf "$STAGE" || true
}

# ---- 1. Syntax + portability ------------------------------------------------

@test "POSIX sh: sh -n parses notify-fanout.sh" {
  run sh -n "${INFRA_ROOT}/scripts/notify-fanout.sh"
  [ "$status" -eq 0 ]
}

@test "shellcheck: notify-fanout.sh has zero warnings (sh dialect)" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run shellcheck -s sh "${INFRA_ROOT}/scripts/notify-fanout.sh"
  [ "$status" -eq 0 ]
}

# ---- 2. Empty provider list — clean no-op ----------------------------------

@test "empty PROVIDERS → exits cleanly with no curl calls" {
  PAYLOAD='{"event":"x","app":"a"}' PROVIDERS="" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "notify-fanout done" ]]
  [ ! -f "$STAGE/curl.log" ]
}

# ---- 3. Provider with no webhook → skipped (not failed) --------------------

@test "provider with no webhook-url mounted → [WARN] skip, continues" {
  PAYLOAD='{"event":"x","app":"a"}' PROVIDERS="dingtalk,feishu" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dingtalk: no webhook-url" ]]
  [[ "$output" =~ "feishu: no webhook-url" ]]
  [ ! -f "$STAGE/curl.log" ]
}

@test "provider with webhook but no template → [WARN] skip" {
  mkdir -p "$STAGE/secrets/dingtalk"
  echo "https://example.com/hook" > "$STAGE/secrets/dingtalk/webhook-url"
  PAYLOAD='{"event":"x"}' PROVIDERS="dingtalk" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dingtalk: no body.tmpl" ]]
  [ ! -f "$STAGE/curl.log" ]
}

# ---- 4. Happy path: wecom (no signing) -------------------------------------

@test "wecom provider with webhook + template → curl invoked with body" {
  mkdir -p "$STAGE/secrets/wecom" "$STAGE/templates/wecom"
  echo "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x" \
    > "$STAGE/secrets/wecom/webhook-url"
  cat > "$STAGE/templates/wecom/body.tmpl" <<'EOF'
{"msgtype":"text","text":{"content":"${NOTIFY_APP}@${NOTIFY_COMMIT}"}}
EOF
  PAYLOAD='{"app":"hello-go","commit":"abc1234"}' PROVIDERS="wecom" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/curl.log" ]
  grep -q "hello-go@abc1234" "$STAGE/curl.log"
}

# ---- 5. Signing: dingtalk URL gets timestamp + sign appended ---------------

@test "dingtalk signing: URL gets &timestamp= and &sign= when sign-secret present" {
  mkdir -p "$STAGE/secrets/dingtalk" "$STAGE/templates/dingtalk"
  echo "https://oapi.dingtalk.com/robot/send?access_token=t" \
    > "$STAGE/secrets/dingtalk/webhook-url"
  echo "SECxxx" > "$STAGE/secrets/dingtalk/sign-secret"
  cat > "$STAGE/templates/dingtalk/body.tmpl" <<'EOF'
{"msgtype":"text","text":{"content":"${NOTIFY_APP}"}}
EOF
  PAYLOAD='{"app":"signed"}' PROVIDERS="dingtalk" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/curl.log" ]
  # URL appended with timestamp + URL-encoded sign. Regex permits non-digit
  # chars in timestamp because BSD `date` (macOS test runner) doesn't honour
  # `%3N` — it returns the literal `%3N`, which would still POST correctly
  # on alpine where `date` is GNU coreutils, but trips up a digits-only regex.
  grep -qE "access_token=t&timestamp=[^&]+&sign=" "$STAGE/curl.log"
}

# ---- 6. Signing: feishu injects ts + sign INTO body envelope ---------------

@test "feishu signing: body gains timestamp + sign keys when sign-secret present" {
  mkdir -p "$STAGE/secrets/feishu" "$STAGE/templates/feishu"
  echo "https://open.feishu.cn/open-apis/bot/v2/hook/x" \
    > "$STAGE/secrets/feishu/webhook-url"
  echo "FEIxxx" > "$STAGE/secrets/feishu/sign-secret"
  cat > "$STAGE/templates/feishu/body.tmpl" <<'EOF'
{"msg_type":"text","content":{"text":"${NOTIFY_APP}"}}
EOF
  PAYLOAD='{"app":"feishu-signed"}' PROVIDERS="feishu" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  # curl received the body on stdin; check log contains both keys
  grep -q '"timestamp"' "$STAGE/curl.log"
  grep -q '"sign"' "$STAGE/curl.log"
}

# ---- 7. Generic webhook: bearer header when /secrets/generic/bearer present -

@test "generic webhook + bearer token → curl gets Authorization header" {
  mkdir -p "$STAGE/secrets/generic" "$STAGE/templates/generic"
  echo "https://example.com/hook" > "$STAGE/secrets/generic/webhook-url"
  echo "bearer-token-xyz" > "$STAGE/secrets/generic/bearer"
  echo '{"app":"${NOTIFY_APP}"}' > "$STAGE/templates/generic/body.tmpl"
  PAYLOAD='{"app":"gen"}' PROVIDERS="generic" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer bearer-token-xyz' "$STAGE/curl.log"
}

# ---- 8. Multiple providers: each gets its own delivery ---------------------

@test "two providers configured → both fired independently" {
  for p in dingtalk wecom; do
    mkdir -p "$STAGE/secrets/$p" "$STAGE/templates/$p"
    echo "https://example.com/$p" > "$STAGE/secrets/$p/webhook-url"
    echo '{"to":"${NOTIFY_APP}"}' > "$STAGE/templates/$p/body.tmpl"
  done
  PAYLOAD='{"app":"two"}' PROVIDERS="dingtalk,wecom" run "$TEST_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "https://example.com/dingtalk" "$STAGE/curl.log"
  grep -q "https://example.com/wecom" "$STAGE/curl.log"
}
