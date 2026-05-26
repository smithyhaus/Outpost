#!/usr/bin/env bats
# =============================================================================
# ArgoCD instant-sync + notifications wiring.
#
# Guards:
#   (a) argocd-cm webhook patch template — ARGOCD_WEBHOOK_SECRET propagates
#       into all three provider keys; strict render check fires if env unset.
#   (b) notifications-cm.template.yaml has all 5 triggers (on-deployed,
#       on-sync-failed, on-degraded, on-deleted, on-rollback) and references
#       them all in the subscriptions list — without these, future renames
#       silently break the substitution pipeline downstream.
#   (c) Every notification plugin contributes app-deployed-<short> AND
#       app-deleted-<short> templates (i.e. the new triggers have bodies).
#       Without this, on-deployed/on-deleted fire but log
#       `template not found` and silently swallow notifications.
#   (d) The placeholder-substitution sed in 09-test-gate.sh covers every
#       _PLUGIN_TEMPLATES_*_ placeholder in the cm template. A new template
#       placeholder without a sed branch would leave a literal `_PLUGIN_...`
#       string in the rendered cm and break argocd-notifications-controller.
#   (e) `outpost setup-argocd-webhook` reads .env and prints the URL +
#       secret + provider hint (smoke-level — full IT belongs in e2e).
#   (f) bootstrap.d/02-config.sh auto-generates ARGOCD_WEBHOOK_SECRET when
#       blank and persists it to .env.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PATCH_TMPL="${INFRA_ROOT}/core/k8s/04-argocd/webhook-cm-patch.template.yaml"
  CM_TMPL="${INFRA_ROOT}/core/k8s/04-argocd/notifications-cm.template.yaml"
  PLUGIN_DIR="${INFRA_ROOT}/plugins/notification"
  PHASE9="${INFRA_ROOT}/bootstrap.d/09-test-gate.sh"
  PHASE2="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  OUTPOST="${INFRA_ROOT}/scripts/outpost"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"

  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

# ---- (a) webhook-cm-patch template ------------------------------------------

@test "webhook-cm-patch template exists and is non-empty" {
  [ -r "$PATCH_TMPL" ]
  [ -s "$PATCH_TMPL" ]
}

@test "webhook-cm-patch renders ARGOCD_WEBHOOK_SECRET into all three provider keys" {
  export ARGOCD_WEBHOOK_SECRET="test-secret-abc123"
  out="$TMP/patch.yaml"
  run render_template "$PATCH_TMPL" "$out"
  [ "$status" -eq 0 ]
  grep -q 'webhook.gitee.secret: "test-secret-abc123"'  "$out"
  grep -q 'webhook.github.secret: "test-secret-abc123"' "$out"
  grep -q 'webhook.gitlab.secret: "test-secret-abc123"' "$out"
  unset ARGOCD_WEBHOOK_SECRET
}

@test "webhook-cm-patch fails strict render when ARGOCD_WEBHOOK_SECRET unset" {
  # Unset the variable explicitly — render_template's strict check should reject.
  unset ARGOCD_WEBHOOK_SECRET
  run render_template "$PATCH_TMPL" "$TMP/should-not-exist.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "ARGOCD_WEBHOOK_SECRET" ]]
}

# ---- (b) notifications-cm.template all 5 triggers + subscriptions -----------

@test "notifications-cm has all 5 triggers (deployed, sync-failed, degraded, deleted, rollback)" {
  [ -r "$CM_TMPL" ]
  for t in on-deployed on-sync-failed on-degraded on-deleted on-rollback; do
    grep -qE "^\s*trigger\.${t}:" "$CM_TMPL" || \
      { echo "missing trigger: $t"; return 1; }
  done
}

@test "notifications-cm subscriptions list references all 5 triggers" {
  for t in on-deployed on-sync-failed on-degraded on-deleted on-rollback; do
    grep -qE "${t}" "$CM_TMPL" || { echo "subscription missing: $t"; return 1; }
  done
  # Defensive: the subscriptions block must literally include the 5 names
  # comma-joined. A naïve search above could pass if only the trigger header
  # uses the name. Grep the subscriptions line specifically.
  grep -qE 'triggers:.*on-deployed.*on-sync-failed.*on-degraded.*on-deleted.*on-rollback' "$CM_TMPL"
}

@test "notifications-cm on-deployed uses oncePer revision (no spam)" {
  # Without oncePer the controller fires every reconciliation while the
  # condition holds — that floods every channel each ArgoCD poll cycle.
  run sed -n '/trigger.on-deployed:/,/trigger\./p' "$CM_TMPL"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "oncePer" ]]
}

# ---- (c) per-plugin templates for deployed/deleted --------------------------

@test "every notification plugin defines template.app-deployed-<short> and app-deleted-<short>" {
  # Bash 3.2-portable mapping (no associative arrays): parallel `plugin:short` pairs.
  # Short name = template suffix + service.webhook.<short> name. Must match
  # _to_short() in bootstrap.d/09-test-gate.sh exactly.
  for pair in "dingtalk:dingtalk" "feishu:feishu" "wecom:wecom" "webhook-generic:generic"; do
    p="${pair%%:*}"
    s="${pair##*:}"
    f="${PLUGIN_DIR}/${p}/argocd-cm-fragment.yaml"
    grep -qE "^\s*template\.app-deployed-${s}:" "$f" || \
      { echo "${p}: missing template.app-deployed-${s}"; return 1; }
    grep -qE "^\s*template\.app-deleted-${s}:"  "$f" || \
      { echo "${p}: missing template.app-deleted-${s}"; return 1; }
  done
}

@test "every notification plugin's deployed template contains the app name placeholder" {
  for p in dingtalk feishu wecom webhook-generic; do
    f="${PLUGIN_DIR}/${p}/argocd-cm-fragment.yaml"
    # Tail after the deployed template up to the next template heading.
    run sed -n '/template\.app-deployed-/,/template\./p' "$f"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "{{.app.metadata.name}}" ]] || \
      { echo "${p}: deployed template missing app name interpolation"; return 1; }
  done
}

# ---- (d) Phase 9 sed-substitution coverage ----------------------------------

@test "phase 9 substitutes every _PLUGIN_TEMPLATES_*_ placeholder appearing in the cm template" {
  # Extract distinct placeholders used in the cm template.
  placeholders="$(grep -oE '_PLUGIN_TEMPLATES_[A-Z_]+_' "$CM_TMPL" | sort -u)"
  [ -n "$placeholders" ] || { echo "no placeholders found in cm template"; return 1; }
  while IFS= read -r ph; do
    grep -q "$ph" "$PHASE9" || \
      { echo "phase 9 does NOT substitute $ph — would leave literal in cm"; return 1; }
  done <<< "$placeholders"
}

@test "phase 9 substitutes _PLUGIN_RECIPIENTS_" {
  grep -q "_PLUGIN_RECIPIENTS_" "$PHASE9"
  grep -q "_recipients" "$PHASE9"
}

@test "phase 9 has a defensive grep-and-fail if any _PLUGIN_*_ placeholder survives" {
  # Without this guardrail, future template additions without sed updates
  # would silently break notifications.
  run grep -nE 'grep -q .*_PLUGIN_\[A-Z_\]\*_' "$PHASE9"
  [ "$status" -eq 0 ]
}

# ---- (e) outpost setup-argocd-webhook ---------------------------------------

@test "outpost setup-argocd-webhook prints URL, secret, and provider hint" {
  # OUTPOST_NO_ENV=1 so we control the environment fully (no .env interference).
  run env -i OUTPOST_NO_ENV=1 PATH="$PATH" \
    ROOT_DOMAIN=example.com \
    ARGOCD_HOST=argocd \
    ARGOCD_WEBHOOK_SECRET=top-secret-xyz \
    GIT_PROVIDER_PLUGIN=gitee \
    MANIFEST_REPO_URL="https://gitee.com/u/manifests.git" \
    bash "$OUTPOST" setup-argocd-webhook
  [ "$status" -eq 0 ]
  [[ "$output" =~ "https://argocd.example.com/api/webhook" ]]
  [[ "$output" =~ "top-secret-xyz" ]]
  [[ "$output" =~ "gitee" ]]
}

@test "outpost setup-argocd-webhook fails clean when ARGOCD_WEBHOOK_SECRET missing" {
  run env -i OUTPOST_NO_ENV=1 PATH="$PATH" \
    ROOT_DOMAIN=example.com \
    bash "$OUTPOST" setup-argocd-webhook
  [ "$status" -ne 0 ]
  [[ "$output" =~ "ARGOCD_WEBHOOK_SECRET" ]]
}

# ---- (f) bootstrap auto-generates ARGOCD_WEBHOOK_SECRET ---------------------

@test "phase 2 config auto-generates ARGOCD_WEBHOOK_SECRET when blank" {
  # The auto-generation branch lives next to GIT_WEBHOOK_SECRET. Verify both
  # the gen line and the persist-to-.env line are present.
  grep -qE 'ARGOCD_WEBHOOK_SECRET=\$\(gen_password\)' "$PHASE2"
  grep -qE 'echo "ARGOCD_WEBHOOK_SECRET=' "$PHASE2"
}

@test "phase 8 patches argocd-cm with the webhook receiver template" {
  PHASE8="${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
  grep -q "webhook-cm-patch.template.yaml" "$PHASE8"
  grep -q "kubectl patch -n argocd configmap argocd-cm" "$PHASE8"
}
