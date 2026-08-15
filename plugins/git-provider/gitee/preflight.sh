#!/usr/bin/env bash
# =============================================================================
# git-provider / gitee — preflight
# -----------------------------------------------------------------------------
# v0.3: the inbound webhook path retired with Tekton, so there's no
# GIT_WEBHOOK_SECRET to check anymore. Instead this is a REAL authenticated
# `git ls-remote` probe: for every OUTPOST_REPOS entry whose host is
# gitee.com, resolve credentials (primary GIT_USER/GIT_TOKEN when the host
# matches GIT_HOST, else a GIT_CREDENTIALS_EXTRA entry) and confirm the
# token can actually list refs. A revoked/expired token now fails LOUDLY at
# bootstrap instead of silently breaking build triggers and verify.sh
# reconciliation weeks later.
# =============================================================================
set -euo pipefail

PROVIDER_HOST_PATTERN='gitee\.'

missing=0
for v in GIT_USER GIT_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERR] gitee plugin requires env: $v" >&2
    missing=1
  fi
done
[[ "$missing" -eq 1 ]] && exit 1

# Resolve "<user> <token>" for a bare hostname: the primary pair (GIT_HOST /
# GIT_USER / GIT_TOKEN) or a matching GIT_CREDENTIALS_EXTRA `host|user|token`
# entry. Prints nothing and returns 1 when no credential is found.
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
  # Bare host from https://host/... or git@host:...
  host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#^git@##; s#[:/].*$##')
  [[ "$host" =~ $PROVIDER_HOST_PATTERN ]] || continue

  probed=1
  creds=""
  if ! creds=$(_resolve_creds "$host"); then
    echo "[ERR] gitee plugin: no credentials for OUTPOST_REPOS host '$host' (set GIT_USER/GIT_TOKEN when GIT_HOST=$host, or add a GIT_CREDENTIALS_EXTRA entry)" >&2
    failed=1
    continue
  fi
  read -r c_user c_token <<< "$creds"
  auth_url=$(printf '%s' "$url" | sed -E "s#^https://#https://${c_user}:${c_token}@#")
  # SECURITY: $auth_url carries a cleartext token — never echo it.
  if ! git ls-remote "$auth_url" >/dev/null 2>&1; then
    echo "[ERR] gitee plugin: authenticated ls-remote FAILED for $url (bad/expired token, or host unreachable)" >&2
    failed=1
  fi
done

if [[ "$probed" -eq 0 ]]; then
  echo "[WARN] gitee plugin: no OUTPOST_REPOS entry matches host pattern 'gitee.*' — nothing to probe yet" >&2
fi

exit "$failed"
