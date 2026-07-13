#!/usr/bin/env bash
# =============================================================================
# register-webhooks.sh — idempotently register BOTH CI/CD webhook hops via the
# git provider APIs, so a fresh onboard never leaves the "9-day silent failure"
# gap where the cluster is green but no push ever reaches Tekton/ArgoCD.
#
# Two hops (see ARCHITECTURE.md):
#   1. Tekton  — every source app repo in WEBHOOK_REPO_WHITELIST gets a push
#                webhook → https://hooks.${ROOT_DOMAIN}, auth GIT_WEBHOOK_SECRET.
#   2. ArgoCD  — the MANIFEST_REPO_URL gets a push webhook →
#                https://argocd.${ROOT_DOMAIN}/api/webhook, auth
#                ARGOCD_WEBHOOK_SECRET (collapses the 3-min poll to ~5s).
#
# Idempotent: a hook is matched by its target URL. Present → updated in place
# (PUT/PATCH) so the secret/events stay correct; absent → created. Re-runnable.
# Matching is by URL only (gitee/github/gitlab webhook APIs expose no reliable
# free-text "owner" field to tag ours with). This is safe because the target is
# a deployment-unique subdomain (hooks./argocd.${ROOT_DOMAIN}) — a pre-existing
# hook at that exact URL is already an Outpost hook, which is precisely what we
# want to reconcile, not a third party's.
#
# Providers: gitee (v5), github (v3), gitlab (v4, incl. self-hosted host).
# Per-repo provider + credentials are derived from the repo's own host, so a
# stacked GIT_PROVIDER_PLUGIN=gitee,github works out of the box as long as the
# matching token is in GIT_TOKEN (manifest host) or GIT_CREDENTIALS_EXTRA.
#
# SECURITY:
#   - Tokens/secrets are NEVER echoed; plans print only a redacted `****abcd`.
#   - Every credential rides in a `curl -K -` config on STDIN, never in the
#     process argv (so `ps`/`/proc/<pid>/cmdline` can't leak it) and never in
#     our command line's URL. Caveat: the gitee v5 *list* call authenticates
#     only via an `access_token` query param, so on that one GET the token is
#     in the request URL on the wire (TLS-encrypted; visible only to a
#     server-side/proxy access log). Rotate GIT_TOKEN periodically.
#   - Repo URLs are parsed with userinfo stripped and the host/owner/repo
#     validated against a strict charset before use — a URL with embedded
#     credentials (https://<token>@host/…) can't route a token to the wrong
#     host or land in a log line.
#
# Usage:
#   bash scripts/register-webhooks.sh [--dry-run] [--yes] [--tekton-only|--argocd-only]
#   outpost register-webhooks [--dry-run]
#
# Exit: 0 all targets reconciled; 1 config/arg error (no side effects); 2 one or
# more API calls failed (partial — the rest still attempted).
# =============================================================================
set -euo pipefail

OUTPOST_HOME="${OUTPOST_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=platform/lib/portable.sh
source "$OUTPOST_HOME/platform/lib/portable.sh"
if [[ -f "$OUTPOST_HOME/.env" && "${OUTPOST_NO_ENV:-0}" != "1" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$OUTPOST_HOME/.env"; set +a
fi

# Bound every API call so a CN-egress flap (the exact failure this repo hardens
# elsewhere) can't hang the whole loop — a timeout returns 000 and moves on.
CURL_TIMEOUT=(--connect-timeout 5 --max-time 20)

# ---- redaction --------------------------------------------------------------
# Show only the last 4 chars of a secret so logs prove which key is in play
# without leaking it. Never print the raw value anywhere else.
redact() {
  local s="${1:-}"
  if [[ ${#s} -le 4 ]]; then printf '****'; else printf '****%s' "${s: -4}"; fi
}

# ---- repo URL parsing -------------------------------------------------------
# Accepts https://[user[:token]@]host/owner/repo(.git) and git@host:owner/repo.
# The userinfo (`user[:token]@`) is stripped so an embedded credential never
# contaminates the host (which would otherwise leak into logs / mis-route auth).
repo_host()  {
  local u="${1#git@}"; u="${u#https://}"; u="${u#http://}"
  u="${u%%/*}"        # authority
  u="${u##*@}"        # drop user[:pass]@ userinfo
  printf '%s' "${u%%:*}"
}
repo_path()  {
  local u="$1"
  u="${u#git@*:}"; u="${u#https://}"; u="${u#http://}"
  u="${u#*@}"                          # drop userinfo before host
  u="${u#*/}"                          # drop host, keep owner/…/repo
  u="${u%.git}"
  printf '%s' "$u"                     # owner/repo (gitlab may nest: group/sub/repo)
}
repo_owner() { local p; p="$(repo_path "$1")"; printf '%s' "${p%/*}"; }
repo_name()  { local p; p="$(repo_path "$1")"; printf '%s' "${p##*/}"; }

# ---- provider detection from host -------------------------------------------
# Anchored matches only (no loose `*gitlab*` substring) so a crafted host can't
# be coerced into a provider branch.
provider_for_host() {
  case "$1" in
    gitee.com)           printf 'gitee'  ;;
    github.com)          printf 'github' ;;
    gitlab.com|gitlab.*) printf 'gitlab' ;;
    *)                   printf 'unknown';;
  esac
}

# ---- credential resolution --------------------------------------------------
# Manifest host uses GIT_USER/GIT_TOKEN. Other hosts pull their token from
# GIT_CREDENTIALS_EXTRA (comma list of `host|user|token`). Public repos that
# need no auth to READ still need an admin token to REGISTER a webhook, so a
# missing token is a hard skip with a clear message (not a silent pass).
token_for_host() {
  local host="$1"
  if [[ -n "${GIT_HOST:-}" && "$host" == "$GIT_HOST" ]]; then
    printf '%s' "${GIT_TOKEN:-}"; return 0
  fi
  local entry h
  # `${arr[@]:-}` guards the empty-array expansion under `set -u` on bash 3.2
  # (macOS) — GIT_CREDENTIALS_EXTRA is empty by default, so this path is hot.
  IFS=',' read -ra _entries <<< "${GIT_CREDENTIALS_EXTRA:-}"
  for entry in "${_entries[@]:-}"; do
    [[ -z "$entry" ]] && continue
    h="${entry%%|*}"
    if [[ "$h" == "$host" ]]; then
      printf '%s' "${entry##*|}"; return 0
    fi
  done
  printf ''
}

# ---- input validation -------------------------------------------------------
# Reject anything outside a strict charset BEFORE it reaches a URL or a log line.
# On failure we print a generic message (never the raw, possibly secret-bearing
# value) and the caller skips the repo.
valid_field() {
  local kind="$1" val="$2" re="$3"
  if [[ "$val" =~ $re ]]; then return 0; fi
  warn "  skip — malformed ${kind} in a repo URL (rejected before use)"
  return 1
}

# ---- curl via -K config on stdin (keeps secrets out of argv) -----------------
# MUST be called as a plain statement (never `$(call_api ...)`) so the HTTP_CODE
# and BODY globals it sets are visible to the caller — a command-substitution
# subshell would swallow them. The curl subshell here only feeds the local `out`.
HTTP_CODE=0
BODY=""
call_api() {
  local cfg="$1" out
  out="$(printf '%s' "$cfg" | curl -sS "${CURL_TIMEOUT[@]}" -w $'\n%{http_code}' -K - 2>/dev/null || printf '\n000')"
  HTTP_CODE="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}
# Quote a value for a curl -K config line (escape backslash then doublequote).
_q() { local v="${1:-}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }
# URL-encode a single path segment via jq (owner/repo may contain '.', '-').
_uri() { printf '%s' "${1:-}" | jq -sRr @uri; }

# ---- per-provider hook reconciliation ---------------------------------------
# ensure_hook <provider> <host> <owner> <repo> <target_url> <secret> <token>
# Returns 0 on success (created/updated/already-correct), 2 on API failure.
ensure_hook() {
  local provider="$1" host="$2" owner="$3" repo="$4" target="$5" secret="$6" token="$7"
  local label="${owner}/${repo}"

  if [[ -z "$token" ]]; then
    warn "  skip ${label} (${provider}) — no admin token for host '${host}' (set GIT_TOKEN or GIT_CREDENTIALS_EXTRA)"
    return 2
  fi

  case "$provider" in
    gitee)  _ensure_gitee  "$owner" "$repo" "$target" "$secret" "$token" ;;
    github) _ensure_github "$owner" "$repo" "$target" "$secret" "$token" ;;
    gitlab) _ensure_gitlab "$host" "$owner" "$repo" "$target" "$secret" "$token" ;;
    *)      warn "  skip ${label} — unsupported provider for host '${host}'"; return 2 ;;
  esac
}

_ensure_gitee() {
  local owner="$1" repo="$2" target="$3" secret="$4" token="$5"
  local base id method="POST" url
  base="https://gitee.com/api/v5/repos/$(_uri "$owner")/$(_uri "$repo")/hooks"
  # gitee v5 authenticates the list call via an access_token query param only.
  call_api "url = $(_q "$base")
get
data-urlencode = $(_q "access_token=${token}")"
  [[ "$HTTP_CODE" =~ ^2 ]] || { err "  gitee GET hooks ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2; }
  id="$(printf '%s' "$BODY" | jq -r --arg u "$target" '.[] | select(.url==$u) | .id' 2>/dev/null | head -n1 || true)"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -n "$id" ]]; then log "  [dry-run] gitee ${owner}/${repo}: would UPDATE hook #${id} → ${target} (secret $(redact "$secret"))"
    else log "  [dry-run] gitee ${owner}/${repo}: would CREATE hook → ${target} (secret $(redact "$secret"))"; fi
    return 0
  fi

  url="$base"
  if [[ -n "$id" ]]; then method="PATCH"; url="${base}/${id}"; fi
  call_api "request = $(_q "$method")
url = $(_q "$url")
data-urlencode = $(_q "access_token=${token}")
data-urlencode = $(_q "url=${target}")
data-urlencode = $(_q "password=${secret}")
data = \"push_events=true\""
  [[ "$HTTP_CODE" =~ ^2 ]] && { ok "  gitee ${owner}/${repo} → ${target}"; return 0; }
  err "  gitee write ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2
}

_ensure_github() {
  local owner="$1" repo="$2" target="$3" secret="$4" token="$5"
  local base hdr id payload method="POST" url
  base="https://api.github.com/repos/$(_uri "$owner")/$(_uri "$repo")/hooks"
  hdr="header = $(_q "Authorization: token ${token}")
header = \"Accept: application/vnd.github+json\""
  call_api "request = \"GET\"
url = $(_q "$base")
${hdr}"
  [[ "$HTTP_CODE" =~ ^2 ]] || { err "  github GET hooks ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2; }
  id="$(printf '%s' "$BODY" | jq -r --arg u "$target" '.[] | select(.config.url==$u) | .id' 2>/dev/null | head -n1 || true)"

  payload="$(jq -n --arg u "$target" --arg s "$secret" \
    '{name:"web",active:true,events:["push"],config:{url:$u,content_type:"json",secret:$s,insecure_ssl:"0"}}')"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -n "$id" ]]; then log "  [dry-run] github ${owner}/${repo}: would UPDATE hook #${id} → ${target} (secret $(redact "$secret"))"
    else log "  [dry-run] github ${owner}/${repo}: would CREATE hook → ${target} (secret $(redact "$secret"))"; fi
    return 0
  fi

  url="$base"
  if [[ -n "$id" ]]; then method="PATCH"; url="${base}/${id}"; fi
  call_api "request = $(_q "$method")
url = $(_q "$url")
${hdr}
data = $(_q "$payload")"
  [[ "$HTTP_CODE" =~ ^2 ]] && { ok "  github ${owner}/${repo} → ${target}"; return 0; }
  err "  github write ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2
}

_ensure_gitlab() {
  local host="$1" owner="$2" repo="$3" target="$4" secret="$5" token="$6"
  local enc base hdr id method="POST" url
  # GitLab addresses projects by URL-encoded full path (group/sub/repo).
  enc="$(_uri "${owner}/${repo}")"
  base="https://${host}/api/v4/projects/${enc}/hooks"
  hdr="header = $(_q "PRIVATE-TOKEN: ${token}")"
  call_api "request = \"GET\"
url = $(_q "$base")
${hdr}"
  [[ "$HTTP_CODE" =~ ^2 ]] || { err "  gitlab GET hooks ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2; }
  id="$(printf '%s' "$BODY" | jq -r --arg u "$target" '.[] | select(.url==$u) | .id' 2>/dev/null | head -n1 || true)"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -n "$id" ]]; then log "  [dry-run] gitlab ${owner}/${repo}: would UPDATE hook #${id} → ${target} (secret $(redact "$secret"))"
    else log "  [dry-run] gitlab ${owner}/${repo}: would CREATE hook → ${target} (secret $(redact "$secret"))"; fi
    return 0
  fi

  url="$base"
  if [[ -n "$id" ]]; then method="PUT"; url="${base}/${id}"; fi
  call_api "request = $(_q "$method")
url = $(_q "$url")
${hdr}
data-urlencode = $(_q "url=${target}")
data-urlencode = $(_q "token=${secret}")
data = \"push_events=true\""
  [[ "$HTTP_CODE" =~ ^2 ]] && { ok "  gitlab ${owner}/${repo} → ${target}"; return 0; }
  err "  gitlab write ${owner}/${repo} → HTTP ${HTTP_CODE}"; return 2
}

# ---- reconcile one repo against one target URL ------------------------------
reconcile_repo() {
  local repo_url="$1" target="$2" secret="$3"
  local host owner repo provider token
  host="$(repo_host "$repo_url")"
  owner="$(repo_owner "$repo_url")"
  repo="$(repo_name "$repo_url")"
  # Fail closed on anything outside a strict charset (never echo the raw value).
  valid_field host  "$host"  '^[A-Za-z0-9.-]+$'   || return 2
  valid_field owner "$owner" '^[A-Za-z0-9._/-]+$' || return 2
  valid_field repo  "$repo"  '^[A-Za-z0-9._-]+$'  || return 2
  provider="$(provider_for_host "$host")"
  token="$(token_for_host "$host")"
  ensure_hook "$provider" "$host" "$owner" "$repo" "$target" "$secret" "$token"
}

# ---- main -------------------------------------------------------------------
main() {
  DRY_RUN=0; local ASSUME_YES=0 SCOPE="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     DRY_RUN=1 ;;
      --yes|-y)      ASSUME_YES=1 ;;
      --tekton-only) SCOPE="tekton" ;;
      --argocd-only) SCOPE="argocd" ;;
      -h|--help)     grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)             err "unknown arg: $1"; return 1 ;;
    esac
    shift
  done

  require_cmd curl jq || return 1

  local domain="${ROOT_DOMAIN:-}"
  [[ -z "$domain" ]] && { err "ROOT_DOMAIN unset — run bootstrap.sh first"; return 1; }

  local hooks_host="${HOOKS_HOST:-hooks}" argocd_host="${ARGOCD_HOST:-argocd}"
  local tekton_url="https://${hooks_host}.${domain}"
  local argocd_url="https://${argocd_host}.${domain}/api/webhook"
  local git_secret="${GIT_WEBHOOK_SECRET:-}" argocd_secret="${ARGOCD_WEBHOOK_SECRET:-}"

  # Validate required secrets UP FRONT (before any mutating call) so a non-zero
  # exit here reliably means "no webhooks were touched".
  if [[ "$SCOPE" == "all" || "$SCOPE" == "tekton" ]] \
     && [[ -n "${WEBHOOK_REPO_WHITELIST:-}" && -z "$git_secret" ]]; then
    err "GIT_WEBHOOK_SECRET unset — required for the Tekton hop"; return 1
  fi
  if [[ "$SCOPE" == "all" || "$SCOPE" == "argocd" ]] \
     && [[ -n "${MANIFEST_REPO_URL:-}" && -z "$argocd_secret" ]]; then
    err "ARGOCD_WEBHOOK_SECRET unset — required for the ArgoCD hop"; return 1
  fi

  phase "Webhook registration${DRY_RUN:+ (dry-run)}"
  log "Tekton  target: ${tekton_url}   secret $(redact "$git_secret")"
  log "ArgoCD  target: ${argocd_url}   secret $(redact "$argocd_secret")"

  # Confirm before any mutating run (idempotent, but it writes to external repos).
  if [[ "$DRY_RUN" != "1" && "$ASSUME_YES" != "1" ]]; then
    confirm "Register/update the above webhooks on your git repos now?" || { warn "aborted"; return 1; }
  fi

  local rc=0 url

  if [[ "$SCOPE" == "all" || "$SCOPE" == "tekton" ]]; then
    log "── Tekton hop (source app repos) ──"
    if [[ -z "${WEBHOOK_REPO_WHITELIST:-}" ]]; then
      warn "  WEBHOOK_REPO_WHITELIST empty — no source repos to register. List your"
      warn "  app repos there (comma-separated https URLs) so pushes trigger builds."
    else
      IFS=',' read -ra _repos <<< "$WEBHOOK_REPO_WHITELIST"
      for url in "${_repos[@]:-}"; do
        url="${url// /}"; [[ -z "$url" ]] && continue
        reconcile_repo "$url" "$tekton_url" "$git_secret" || rc=2
      done
      # The provider-side webhook above is independent of the EventListener's
      # CEL filter, which only reflects WEBHOOK_REPO_WHITELIST as of the last
      # `bash bootstrap.sh` run. A repo just added to .env and registered here
      # will show a 200 OK delivery yet have its pushes silently dropped by
      # CEL until bootstrap.sh re-runs — this is the exact "9-day silent
      # failure" gap this script exists to close on the provider side.
      warn "  Reminder: re-run 'bash bootstrap.sh' if any repo above was just"
      warn "  added to WEBHOOK_REPO_WHITELIST — the EventListener's CEL filter"
      warn "  only picks up whitelist changes on the next bootstrap, not on registration."
    fi
  fi

  if [[ "$SCOPE" == "all" || "$SCOPE" == "argocd" ]]; then
    log "── ArgoCD hop (manifest repo) ──"
    if [[ -z "${MANIFEST_REPO_URL:-}" ]]; then
      warn "  MANIFEST_REPO_URL unset — skipping ArgoCD webhook."
    else
      reconcile_repo "$MANIFEST_REPO_URL" "$argocd_url" "$argocd_secret" || rc=2
    fi
  fi

  if [[ "$rc" == "0" ]]; then ok "All webhook targets reconciled."
  else warn "Some targets were skipped/failed — see lines above. Re-run after fixing tokens."; fi
  return "$rc"
}

# Only run main when executed directly, so bats/tests can source the helpers.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
