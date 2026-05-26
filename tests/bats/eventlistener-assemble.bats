#!/usr/bin/env bats
# =============================================================================
# Tests for platform/lib/eventlistener-assemble.sh
#
# The EventListener is the public webhook entry point — a quietly-broken
# assembly produces a 200 OK that silently drops every push. Fixture-lock
# the assembled output per provider.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  # shellcheck source=../../platform/lib/cel-helpers.sh
  source "${INFRA_ROOT}/platform/lib/cel-helpers.sh"
  # shellcheck source=../../platform/lib/eventlistener-assemble.sh
  source "${INFRA_ROOT}/platform/lib/eventlistener-assemble.sh"

  # Required env for both render_template passes.
  export ROOT_DOMAIN="bats.example.com"
  export GIT_WEBHOOK_SECRET="batstoken"
  # trigger.yaml ref filter pins refs/heads/${OUTPOST_DEPLOY_BRANCH} — render_template
  # aborts on the unresolved placeholder if this is unset.
  export OUTPOST_DEPLOY_BRANCH="main"
  # v0.5+ eventlistener-base.yaml uses ${HOOKS_HOST}.${ROOT_DOMAIN} in the
  # IngressRoute host matcher; provide the default that bootstrap.d/02-config.sh
  # exports during a real install.
  export HOOKS_HOST="hooks"
  unset WEBHOOK_REPO_WHITELIST
  build_cel_whitelist          # → CEL_WHITELIST_LIST="[]"

  BASE="${INFRA_ROOT}/core/k8s/05-tekton/eventlistener-base.yaml"
  OUT=""
}

teardown() {
  [ -n "$OUT" ] && rm -f "$OUT" || true
}

# ---- 1. Bad-input contract ---------------------------------------------------

@test "assemble: missing args fail with usage" {
  run assemble_eventlistener "" "" ""
  [ "$status" -ne 0 ]
  [[ "$output" =~ usage ]]
}

@test "assemble: nonexistent plugin trigger fails clearly" {
  OUT=$(mktemp)
  run assemble_eventlistener "/no/such/file.yaml" "$BASE" "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not readable" ]]
}

@test "assemble: nonexistent base template fails clearly" {
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml" \
    "/no/such/base.yaml" \
    "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not readable" ]]
}

@test "assemble: base without marker fails (anti-silent-failure)" {
  local broken_base
  broken_base=$(mktemp)
  cat > "$broken_base" <<EOF
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: build-listener
spec:
  triggers: []
EOF
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml" \
    "$broken_base" \
    "$OUT"
  rm -f "$broken_base"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "exactly one" ]]
}

# ---- 2. Per-provider happy path ---------------------------------------------

@test "assemble gitee: produces EventListener with gitee-push trigger + el-build-listener service" {
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml" \
    "$BASE" "$OUT"
  [ "$status" -eq 0 ]
  grep -q "^kind: EventListener" "$OUT"
  grep -q "name: build-listener" "$OUT"
  grep -q "name: gitee-push" "$OUT"
  grep -q "ref: gitee-push-binding" "$OUT"
  grep -q "ref: build-template" "$OUT"
  grep -q "name: el-build-listener" "$OUT"
  # Provider-specific auth survived the splice
  grep -q "X-Gitee-Token" "$OUT"
  # Universal CEL whitelist survived envsubst
  grep -q "size(\[\]) == 0" "$OUT"
  # short_sha overlay survived
  grep -q 'key: short_sha' "$OUT"
  # C3: ref filter pins the deploy branch (no any-branch startsWith)
  grep -q "refs/heads/main" "$OUT"
  ! grep -qF "startsWith('refs/heads/')" "$OUT"
}

@test "assemble github: produces EventListener with github-push trigger + HMAC interceptor" {
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/github/trigger.yaml" \
    "$BASE" "$OUT"
  [ "$status" -eq 0 ]
  grep -q "name: github-push" "$OUT"
  grep -q "ref: github-push-binding" "$OUT"
  # github interceptor uses Tekton's built-in HMAC verifier
  grep -q "name: github" "$OUT"
  grep -q "secretName: github-webhook-secret" "$OUT"
  # GitHub payload uses clone_url, not git_http_url
  grep -q "body.repository.clone_url" "$OUT"
  grep -q "name: el-build-listener" "$OUT"
  # C3: ref filter pins the deploy branch (no any-branch startsWith)
  grep -q "refs/heads/main" "$OUT"
  ! grep -qF "startsWith('refs/heads/')" "$OUT"
}

@test "assemble gitlab: produces EventListener with gitlab-push trigger + X-Gitlab-Token compare" {
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitlab/trigger.yaml" \
    "$BASE" "$OUT"
  [ "$status" -eq 0 ]
  grep -q "name: gitlab-push" "$OUT"
  grep -q "ref: gitlab-push-binding" "$OUT"
  grep -q "X-Gitlab-Event" "$OUT"
  grep -q "X-Gitlab-Token" "$OUT"
  grep -q "name: el-build-listener" "$OUT"
  # C3: ref filter pins the deploy branch (no any-branch startsWith)
  grep -q "refs/heads/main" "$OUT"
  ! grep -qF "startsWith('refs/heads/')" "$OUT"
}

# ---- 3. envsubst + whitelist interactions -----------------------------------

@test "assemble: ROOT_DOMAIN gets substituted in IngressRoute host" {
  OUT=$(mktemp)
  assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml" \
    "$BASE" "$OUT"
  grep -q "hooks.bats.example.com" "$OUT"
  # Make sure no literal ${ROOT_DOMAIN} survived
  ! grep -qE '\$\{ROOT_DOMAIN\}' "$OUT"
}

@test "assemble: non-empty WEBHOOK_REPO_WHITELIST flows through to CEL filter" {
  export WEBHOOK_REPO_WHITELIST="https://github.com/a/b.git,https://github.com/c/d.git"
  build_cel_whitelist
  OUT=$(mktemp)
  assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/github/trigger.yaml" \
    "$BASE" "$OUT"
  # Single-quoted entries embedded inside the filter string
  grep -q "'https://github.com/a/b.git'" "$OUT"
  grep -q "'https://github.com/c/d.git'" "$OUT"
}

@test "assemble: missing GIT_WEBHOOK_SECRET aborts (render_template residue check)" {
  unset GIT_WEBHOOK_SECRET
  OUT=$(mktemp)
  run assemble_eventlistener \
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml" \
    "$BASE" "$OUT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ GIT_WEBHOOK_SECRET ]]
}
