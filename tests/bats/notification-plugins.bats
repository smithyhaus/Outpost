#!/usr/bin/env bats
# =============================================================================
# Tests for plugins/notification/*
# Verifies:
#   - Each plugin satisfies the plugin-contract (already covered by
#     plugin-contract.bats; here we verify shape specific to notification kind)
#   - manifest.yaml renders cleanly with sample env (no unresolved ${VAR})
#   - preflight behavior matches required_env
#
# v0.3: ArgoCD is gone, so argocd-cm-fragment.yaml / argocd-secret-fragment.yaml
# are RETIRED (see tests/bats/plugin-contract-per-kind.bats for the repo-wide
# assertion that they never reappear). manifest.yaml's Secret/ConfigMap now
# target ns outpost-ci (the manifest-sync CronJob), consumed there via
# volume mount and by host callers via scripts/notify-fanout.sh --env-file.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PLUGIN_DIR="${INFRA_ROOT}/plugins/notification"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

@test "every notification plugin has the expected file shape" {
  for p in dingtalk feishu wecom webhook-generic; do
    [ -f "${PLUGIN_DIR}/${p}/plugin.yaml" ] || fail "${p}: plugin.yaml missing"
    [ -f "${PLUGIN_DIR}/${p}/manifest.yaml" ] || fail "${p}: manifest.yaml missing"
    [ -x "${PLUGIN_DIR}/${p}/preflight.sh" ] || fail "${p}: preflight.sh missing/not executable"
    [ -f "${PLUGIN_DIR}/${p}/README.md" ] || fail "${p}: README.md missing"
    grep -q '^kind: notification' "${PLUGIN_DIR}/${p}/plugin.yaml" || fail "${p}: plugin.yaml kind is not 'notification'"
  done
}

@test "no notification plugin ships the retired argocd-*-fragment.yaml files" {
  for p in dingtalk feishu wecom webhook-generic; do
    [ ! -f "${PLUGIN_DIR}/${p}/argocd-cm-fragment.yaml" ] || fail "${p}: argocd-cm-fragment.yaml should be retired in v0.3"
    [ ! -f "${PLUGIN_DIR}/${p}/argocd-secret-fragment.yaml" ] || fail "${p}: argocd-secret-fragment.yaml should be retired in v0.3"
  done
}

@test "every notification manifest targets the outpost-ci namespace (tekton-pipelines is gone in v0.3)" {
  for p in dingtalk feishu wecom webhook-generic; do
    f="${PLUGIN_DIR}/${p}/manifest.yaml"
    grep -q 'namespace: outpost-ci' "$f" || fail "${p}: manifest.yaml should target ns outpost-ci"
    ! grep -qE '^\s*namespace:\s*tekton-pipelines' "$f" || fail "${p}: manifest.yaml still references tekton-pipelines"
  done
}

@test "dingtalk preflight fails without DINGTALK_WEBHOOK_URL" {
  run env -i bash "${PLUGIN_DIR}/dingtalk/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "DINGTALK_WEBHOOK_URL" ]]
}

@test "dingtalk preflight passes when URL set; sign secret optional" {
  run env -i DINGTALK_WEBHOOK_URL="https://oapi.dingtalk.com/robot/send?access_token=x" \
    bash "${PLUGIN_DIR}/dingtalk/preflight.sh"
  [ "$status" -eq 0 ]
}

@test "feishu preflight fails without FEISHU_WEBHOOK_URL" {
  run env -i bash "${PLUGIN_DIR}/feishu/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "FEISHU_WEBHOOK_URL" ]]
}

@test "wecom preflight fails without WECOM_WEBHOOK_URL" {
  run env -i bash "${PLUGIN_DIR}/wecom/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "WECOM_WEBHOOK_URL" ]]
}

@test "webhook-generic preflight fails without GENERIC_WEBHOOK_URL" {
  run env -i bash "${PLUGIN_DIR}/webhook-generic/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "GENERIC_WEBHOOK_URL" ]]
}

@test "all notification manifests render cleanly with sample env (targeted subst)" {
  # Notification body.tmpl mixes install-time vars (e.g. ${DINGTALK_WEBHOOK_URL})
  # with runtime ${NOTIFY_*} placeholders. We use render_template_only so the
  # runtime placeholders survive into the ConfigMap for notify-fanout.sh to
  # render at fanout time.
  export DINGTALK_WEBHOOK_URL="https://example.dingtalk/test"
  export DINGTALK_SIGN_SECRET="SECsmoke"
  export FEISHU_WEBHOOK_URL="https://example.feishu/test"
  export FEISHU_SIGN_SECRET="SECsmoke"
  export WECOM_WEBHOOK_URL="https://example.wecom/test"
  export GENERIC_WEBHOOK_URL="https://example.generic/test"
  export GENERIC_WEBHOOK_BEARER="bearer-smoke"
  export ROOT_DOMAIN="smoke.example.test"

  ALLOW="DINGTALK_WEBHOOK_URL DINGTALK_SIGN_SECRET FEISHU_WEBHOOK_URL FEISHU_SIGN_SECRET WECOM_WEBHOOK_URL GENERIC_WEBHOOK_URL GENERIC_WEBHOOK_BEARER ROOT_DOMAIN"

  for p in dingtalk feishu wecom webhook-generic; do
    out="${TMP}/${p}.yaml"
    render_template_only "${PLUGIN_DIR}/${p}/manifest.yaml" "$out" "$ALLOW"
    # Should resolve install-time vars and PRESERVE ${NOTIFY_*} runtime placeholders.
    grep -q '${NOTIFY_APP}' "$out" || fail "${p}: \${NOTIFY_APP} should survive install-time render"
    grep -q '${NOTIFY_EVENT}' "$out" || fail "${p}: \${NOTIFY_EVENT} should survive install-time render"
    # Install-time vars must be resolved for the active provider.
    case "$p" in
      dingtalk)        grep -qF "https://example.dingtalk/test" "$out" || fail "dingtalk: webhook URL not substituted" ;;
      feishu)          grep -qF "https://example.feishu/test"   "$out" || fail "feishu: webhook URL not substituted" ;;
      wecom)           grep -qF "https://example.wecom/test"    "$out" || fail "wecom: webhook URL not substituted" ;;
      webhook-generic) grep -qF "https://example.generic/test"  "$out" || fail "generic: webhook URL not substituted" ;;
    esac
  done
}
