#!/usr/bin/env bash
# =============================================================================
# git-provider / github — preflight
# -----------------------------------------------------------------------------
# v0.3: the inbound webhook path retired with Tekton, so there's no
# GIT_WEBHOOK_SECRET to check anymore. Two independent checks:
#
#   1. Authenticated `git ls-remote` for every OUTPOST_REPOS entry whose host
#      is github.com — same contract as the other git-provider plugins.
#   2. When GITHUB_RUNNER_URL/GITHUB_RUNNER_PAT are set, validate the PAT can
#      actually authenticate against the GitHub API (curl, token masked in
#      all output/logs — never echoed). Both empty is a SUPPORTED state
#      (CI/e2e mode: runner install/checks are skipped) and only WARNs.
#      Exactly one set is a real misconfiguration and FAILs.
# =============================================================================
set -euo pipefail

PROVIDER_HOST_PATTERN='github\.'

missing=0
for v in GIT_USER GIT_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERR] github plugin requires env: $v" >&2
    missing=1
  fi
done
[[ "$missing" -eq 1 ]] && exit 1

failed=0

# ---- 1. Authenticated ls-remote per matching OUTPOST_REPOS entry -----------

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
    echo "[ERR] github plugin: no credentials for OUTPOST_REPOS host '$host' (set GIT_USER/GIT_TOKEN when GIT_HOST=$host, or add a GIT_CREDENTIALS_EXTRA entry)" >&2
    failed=1
    continue
  fi
  read -r c_user c_token <<< "$creds"
  auth_url=$(printf '%s' "$url" | sed -E "s#^https://#https://${c_user}:${c_token}@#")
  # SECURITY: $auth_url carries a cleartext token — never echo it.
  if ! git ls-remote "$auth_url" >/dev/null 2>&1; then
    echo "[ERR] github plugin: authenticated ls-remote FAILED for $url (bad/expired token, or host unreachable)" >&2
    failed=1
  fi
done

if [[ "$probed" -eq 0 ]]; then
  echo "[WARN] github plugin: no OUTPOST_REPOS entry matches host pattern 'github.*' — nothing to probe yet" >&2
fi

# ---- 2. GITHUB_RUNNER_URL / GITHUB_RUNNER_PAT shape + API auth check -------

if [[ -z "${GITHUB_RUNNER_URL:-}" && -z "${GITHUB_RUNNER_PAT:-}" ]]; then
  echo "[WARN] github plugin: GITHUB_RUNNER_URL/GITHUB_RUNNER_PAT both empty — runner install/checks skipped (CI/e2e mode)" >&2
elif [[ -z "${GITHUB_RUNNER_URL:-}" || -z "${GITHUB_RUNNER_PAT:-}" ]]; then
  echo "[ERR] github plugin: GITHUB_RUNNER_URL and GITHUB_RUNNER_PAT must both be set together (or both left empty for CI/e2e mode)" >&2
  failed=1
else
  if ! [[ "$GITHUB_RUNNER_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?/?$ ]]; then
    echo "[ERR] github plugin: GITHUB_RUNNER_URL must look like https://github.com/<org> (org-level, recommended) or https://github.com/<owner>/<repo>; got: $GITHUB_RUNNER_URL" >&2
    failed=1
  fi
  if command -v curl >/dev/null 2>&1; then
    # SECURITY: token goes only into the -H arg, never printed/logged.
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Authorization: token ${GITHUB_RUNNER_PAT}" \
      https://api.github.com/user 2>/dev/null || echo "000")
    if [[ "$http_code" != "200" ]]; then
      echo "[ERR] github plugin: GITHUB_RUNNER_PAT failed to authenticate against the GitHub API (HTTP ${http_code}) — check the token is valid, unexpired, and not revoked" >&2
      failed=1
    fi
  else
    echo "[WARN] github plugin: curl not on PATH — skipping GITHUB_RUNNER_PAT API check" >&2
  fi
fi

exit "$failed"
