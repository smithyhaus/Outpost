#!/usr/bin/env bash
# =============================================================================
# git-provider / gitlab — preflight
# -----------------------------------------------------------------------------
# v0.3: the inbound webhook path retired with Tekton, so there's no
# GIT_WEBHOOK_SECRET to check anymore. Instead this is a REAL authenticated
# `git ls-remote` probe: for every OUTPOST_REPOS entry whose host looks like
# a GitLab host (gitlab.com OR self-hosted — matched by the "gitlab."
# substring heuristic, since self-hosted instances can use any hostname),
# resolve credentials and confirm the token can actually list refs. A
# revoked/expired token now fails LOUDLY at bootstrap instead of silently
# breaking build triggers and verify.sh reconciliation weeks later.
# =============================================================================
set -euo pipefail

PROVIDER_HOST_PATTERN='gitlab\.'

missing=0
for v in GIT_USER GIT_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERR] gitlab plugin requires env: $v" >&2
    missing=1
  fi
done
[[ "$missing" -eq 1 ]] && exit 1

_resolve_creds() {
  local host="$1"
  if [[ "$host" == "${GIT_HOST:-}" ]]; then
    printf '%s %s' "$GIT_USER" "$GIT_TOKEN"
    return 0
  fi
  local entry e_host e_user e_token
  local IFS=','
  for entry in ${GIT_CREDENTIALS_EXTRA:-}; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    IFS='|' read -r e_host e_user e_token <<< "$entry"
    if [[ "$e_host" == "$host" ]]; then
      printf '%s %s' "$e_user" "$e_token"
      return 0
    fi
  done
  return 1
}

probed=0
failed=0
IFS=','
for entry in ${OUTPOST_REPOS:-}; do
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [[ -z "$entry" ]] && continue
  url="${entry%%#*}"
  host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#^git@##; s#[:/].*$##')
  [[ "$host" =~ $PROVIDER_HOST_PATTERN ]] || continue

  probed=1
  creds=""
  if ! creds=$(_resolve_creds "$host"); then
    echo "[ERR] gitlab plugin: no credentials for OUTPOST_REPOS host '$host' (set GIT_USER/GIT_TOKEN when GIT_HOST=$host, or add a GIT_CREDENTIALS_EXTRA entry)" >&2
    failed=1
    continue
  fi
  read -r c_user c_token <<< "$creds"
  auth_url=$(printf '%s' "$url" | sed -E "s#^https://#https://${c_user}:${c_token}@#")
  # SECURITY: $auth_url carries a cleartext token — never echo it.
  if ! git ls-remote "$auth_url" >/dev/null 2>&1; then
    echo "[ERR] gitlab plugin: authenticated ls-remote FAILED for $url (bad/expired token, or host unreachable)" >&2
    failed=1
  fi
done

if [[ "$probed" -eq 0 ]]; then
  echo "[WARN] gitlab plugin: no OUTPOST_REPOS entry matches host pattern 'gitlab.*' — nothing to probe yet" >&2
fi

exit "$failed"
