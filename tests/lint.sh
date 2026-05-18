#!/usr/bin/env bash
# Static analysis: shellcheck + yamllint + docker compose config
# Run from repo root: bash tests/lint.sh
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }

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
# `find -type f \( -name A -o -name B \)` — explicit grouping so -type f
# applies to both name patterns.
en_files=$(find i18n/en -type f \( -name '*.md' -o -name '*.template' \) 2>/dev/null | sed 's#^i18n/en/##' | sort)
zh_files=$(find i18n/zh-CN -type f \( -name '*.md' -o -name '*.template' \) 2>/dev/null | sed 's#^i18n/zh-CN/##' | sort)
en_only=$(comm -23 <(echo "$en_files") <(echo "$zh_files") | grep -v '^$' || true)
zh_only=$(comm -13 <(echo "$en_files") <(echo "$zh_files") | grep -v '^$' || true)
if [[ -n "$en_only$zh_only" ]]; then
  warn "i18n drift detected:"
  [[ -n "$en_only" ]] && echo "  EN-only: $en_only"
  [[ -n "$zh_only" ]] && echo "  zh-CN-only: $zh_only"
  # WARN, not FAIL — translations may legitimately lag by one PR
fi

phase "i18n edit-time drift"
# For each EN file with a zh-CN peer, compare the commit timestamp of the
# most recent commit touching each. If EN was edited more recently than
# its peer, the translation is potentially stale — WARN (not FAIL, since a
# one-PR lag during review is normal). Skips files where one side is
# missing (already flagged by the filename-parity check above).
if command -v git >/dev/null && git -C "$INFRA_ROOT" rev-parse >/dev/null 2>&1; then
  stale_count=0
  # Iterate over files that exist in BOTH locales.
  comm -12 <(echo "$en_files") <(echo "$zh_files") | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    en_path="i18n/en/$rel"
    zh_path="i18n/zh-CN/$rel"
    en_ts=$(git log -1 --format=%ct -- "$en_path" 2>/dev/null || echo 0)
    zh_ts=$(git log -1 --format=%ct -- "$zh_path" 2>/dev/null || echo 0)
    # Only flag when EN is strictly newer. Equal timestamps (same commit
    # touched both) is the in-sync state — that's the goal.
    if [[ "$en_ts" -gt "$zh_ts" && "$zh_ts" -gt 0 ]]; then
      delta_days=$(( (en_ts - zh_ts) / 86400 ))
      warn "  EN newer than zh by ${delta_days}d: $rel"
      stale_count=$((stale_count + 1))
    fi
  done
  # `wc -l` to count outside the subshell since the loop's vars don't escape.
  drift=$(comm -12 <(echo "$en_files") <(echo "$zh_files") | while read -r rel; do
    [[ -z "$rel" ]] && continue
    en_ts=$(git log -1 --format=%ct -- "i18n/en/$rel" 2>/dev/null || echo 0)
    zh_ts=$(git log -1 --format=%ct -- "i18n/zh-CN/$rel" 2>/dev/null || echo 0)
    [[ "$en_ts" -gt "$zh_ts" && "$zh_ts" -gt 0 ]] && echo "$rel"
  done | wc -l | tr -d ' ')
  if [[ "$drift" -gt 0 ]]; then
    warn "i18n edit-time drift: $drift file(s) where EN was edited after zh — translations may be stale"
  fi
else
  warn "git not available or not a repo — skipping edit-time drift check"
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
