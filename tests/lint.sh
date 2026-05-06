#!/usr/bin/env bash
# Static analysis: shellcheck + yamllint + docker compose config
# Run from repo root: bash tests/lint.sh
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INFRA_ROOT"

# shellcheck source=../platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"

FAILED=0

phase "shellcheck"
if ! command -v shellcheck >/dev/null; then
  warn "shellcheck not installed — skipping (brew install shellcheck / apt install shellcheck)"
else
  while IFS= read -r -d '' f; do
    if ! shellcheck -x -S warning "$f"; then
      FAILED=1
      err "shellcheck failed: $f"
    fi
  done < <(find . -type f \( -name '*.sh' -o -name '*.bash' \) \
             -not -path './tests/.bats-tmp/*' \
             -not -path './secrets-backup/*' -print0)
fi

phase "yamllint"
if ! command -v yamllint >/dev/null; then
  warn "yamllint not installed — skipping (pip install yamllint)"
else
  yamllint -d "{extends: relaxed, rules: {line-length: {max: 200}}}" \
    core/ plugins/ examples/ .github/ || FAILED=1
fi

phase "docker compose config"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  # Provide minimal env so docker compose config doesn't bail
  export ROOT_DOMAIN=lint.example.com CF_TUNNEL_TOKEN=lint
  export POSTGRES_USER=postgres POSTGRES_PASSWORD=lint POSTGRES_DB=postgres
  export REDIS_PASSWORD=lint RABBITMQ_USER=admin RABBITMQ_PASSWORD=lint
  export MEILI_MASTER_KEY=lintlintlintlintlintlint MEILI_ENV=development
  if ! (cd core/compose && docker compose config -q); then
    FAILED=1
    err "docker compose config failed"
  fi
else
  warn "docker compose not available — skipping"
fi

phase "i18n filename parity"
en_files=$(find i18n/en -type f -name '*.md' -o -name '*.template' 2>/dev/null | sed 's#^i18n/en/##' | sort)
zh_files=$(find i18n/zh-CN -type f -name '*.md' -o -name '*.template' 2>/dev/null | sed 's#^i18n/zh-CN/##' | sort)
en_only=$(comm -23 <(echo "$en_files") <(echo "$zh_files") | grep -v '^$' || true)
zh_only=$(comm -13 <(echo "$en_files") <(echo "$zh_files") | grep -v '^$' || true)
if [[ -n "$en_only$zh_only" ]]; then
  warn "i18n drift detected:"
  [[ -n "$en_only" ]] && echo "  EN-only: $en_only"
  [[ -n "$zh_only" ]] && echo "  zh-CN-only: $zh_only"
  # WARN, not FAIL — translations may legitimately lag by one PR
fi

phase "no committed secrets"
# Examples directory is exempt — placeholders there are documentation, not secrets.
# We also tolerate placeholders of the form <REPLACE_FOO> (explicit user-edit markers).
hits=$(grep -rE 'CHANGE_ME|TODO_FILL|BEGIN PRIVATE KEY' \
   --include='*.sh' --include='*.yaml' --include='*.yml' --include='*.md' \
   --exclude-dir='examples' --exclude-dir='tests' \
   . 2>/dev/null | grep -v ':# ' | grep -v ':\#' || true)
if [[ -n "$hits" ]]; then
  err "secret-shaped strings found in tracked content:"
  echo "$hits"
  FAILED=1
fi

if [[ $FAILED -eq 0 ]]; then
  ok "lint passed"
  exit 0
else
  err "lint failed"
  exit 1
fi
