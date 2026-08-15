#!/bin/sh
# =============================================================================
# scripts/notify-fanout.sh — fan-out a normalized notification payload to
# every enabled provider plugin (DingTalk / Feishu / WeCom / generic webhook).
#
# v0.3 callers: the manifest-sync CronJob (in-cluster, ns outpost-ci — mounts
# this script + provider Secrets/ConfigMaps as files, same as the retired
# Tekton Task did), the GitHub Actions workflow's build-failed step, and the
# host verify.sh systemd timer's verify-failed check (both run OUTSIDE the
# cluster — see the --env-file flag below).
#
# Reads from environment:
#   PAYLOAD    — normalized JSON (event/level/app/env/commit/ref/url/text/pusher)
#   PROVIDERS  — comma-separated list of provider names
#
# Provider config resolution — FILE first, ENV fallback (host callers have no
# volume mounts; the sync pod gets the same vars via the notify-secrets
# Secret's envFrom, so BOTH paths deliver without any /secrets volume):
#   webhook-url : /secrets/<p>/webhook-url   else ${<P>_WEBHOOK_URL}
#   sign-secret : /secrets/<p>/sign-secret   else ${<P>_SIGN_SECRET}   (dingtalk/feishu)
#   bearer      : /secrets/generic/bearer    else ${GENERIC_WEBHOOK_BEARER}
#   body.tmpl   : /templates/<p>/body.tmpl   else a built-in per-provider default
# Provider names: plugin dir name `webhook-generic` is normalized to `generic`.
#
# Optional flag (host-run callers — no /secrets or /templates volume mount):
#   --env-file PATH   sourced BEFORE dispatch, so PAYLOAD/PROVIDERS (and any
#                      provider env vars a caller-side wrapper stages into
#                      the referenced file) are available the same way a
#                      `PAYLOAD=... PROVIDERS=... notify-fanout.sh` in-cluster
#                      invocation gets them. Everything else about the
#                      dispatch loop (file paths, signing, delivery) is
#                      UNCHANGED — this is purely an extra way to populate
#                      the environment before the existing logic runs.
#
# Delivery semantics:
#   - per-provider failures DON'T block other providers
#   - missing webhook-url / body.tmpl → skip provider (logged)
#   - script always exits 0; caller success isn't gated on delivery
#     (that would let a transient DingTalk outage fail every build).
#
# Required commands (must be on PATH):
#   jq, curl, envsubst, openssl, base64
# =============================================================================
set -eu

# ---- Optional --env-file PATH flag ------------------------------------------
# Must run BEFORE the sign-webhook.sh source below stays untouched — this
# only affects how PAYLOAD/PROVIDERS/provider env vars reach the process.
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --env-file=*)
      ENV_FILE="${1#--env-file=}"
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$ENV_FILE" ]; then
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090  # caller-supplied path by design
    . "$ENV_FILE"
    set +a
  else
    echo "[WARN] --env-file $ENV_FILE not found; continuing without it" >&2
  fi
fi

# Sourced for sign_dingtalk / sign_feishu / urlencode_sig. Resolution order:
# SIGN_WEBHOOK_LIB override → next to this script (in-cluster: the sync-scripts
# ConfigMap packs both at /scripts) → repo layout (scripts/ → ../platform/lib).
# Missing lib disables HMAC with a LOUD warning instead of killing the run
# under set -eu — unsigned delivery still gets attempted and logged.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SIGN_LIB="${SIGN_WEBHOOK_LIB:-}"
if [ -z "$SIGN_LIB" ]; then
  for _cand in "$SCRIPT_DIR/sign-webhook.sh" \
               "$SCRIPT_DIR/../platform/lib/sign-webhook.sh" \
               "/scripts/sign-webhook.sh"; do
    if [ -f "$_cand" ]; then SIGN_LIB="$_cand"; break; fi
  done
fi
HAVE_SIGN=0
if [ -n "$SIGN_LIB" ] && [ -f "$SIGN_LIB" ]; then
  # shellcheck source=/dev/null  # resolved at runtime by design
  . "$SIGN_LIB"
  HAVE_SIGN=1
else
  echo "[WARN] sign-webhook.sh not found (SIGN_WEBHOOK_LIB, script dir, ../platform/lib, /scripts) — HMAC signing disabled this run" >&2
fi

# Extract NOTIFY_* env vars from the payload. envsubst inside the per-provider
# body templates picks them up. `// ""` defaults missing keys to empty string
# so the JSON shape doesn't have to be exhaustive.
NOTIFY_EVENT=$(echo "$PAYLOAD"  | jq -r '.event   // ""')
NOTIFY_LEVEL=$(echo "$PAYLOAD"  | jq -r '.level   // "info"')
NOTIFY_APP=$(echo "$PAYLOAD"    | jq -r '.app     // ""')
NOTIFY_ENV=$(echo "$PAYLOAD"    | jq -r '.env     // "dev"')
NOTIFY_COMMIT=$(echo "$PAYLOAD" | jq -r '.commit  // ""')
NOTIFY_REF=$(echo "$PAYLOAD"    | jq -r '.ref     // ""')
NOTIFY_URL=$(echo "$PAYLOAD"    | jq -r '.url     // ""')
NOTIFY_TEXT=$(echo "$PAYLOAD"   | jq -r '.text    // ""')
NOTIFY_PUSHER=$(echo "$PAYLOAD" | jq -r '.pusher  // ""')
export NOTIFY_EVENT NOTIFY_LEVEL NOTIFY_APP NOTIFY_ENV \
       NOTIFY_COMMIT NOTIFY_REF NOTIFY_URL NOTIFY_TEXT NOTIFY_PUSHER

# Built-in body templates — used when no /templates/<p>/body.tmpl file is
# mounted (host callers, or a sync pod without provider CM mounts). Content
# mirrors the plugin ConfigMaps; envsubst expands the NOTIFY_* vars.
builtin_template() {
  case "$1" in
    dingtalk) cat <<'EOF'
{"msgtype":"markdown","markdown":{"title":"[${NOTIFY_LEVEL}] ${NOTIFY_APP} ${NOTIFY_EVENT}","text":"### ${NOTIFY_APP} `${NOTIFY_COMMIT}` in `${NOTIFY_ENV}`\n\n- **event**: ${NOTIFY_EVENT}\n- **ref**: ${NOTIFY_REF}\n- **pusher**: ${NOTIFY_PUSHER}\n\n${NOTIFY_TEXT}"}}
EOF
      ;;
    feishu) cat <<'EOF'
{"msg_type":"text","content":{"text":"[${NOTIFY_LEVEL}] ${NOTIFY_APP} ${NOTIFY_EVENT} (${NOTIFY_ENV}) commit=${NOTIFY_COMMIT} ref=${NOTIFY_REF}\n${NOTIFY_TEXT}"}}
EOF
      ;;
    wecom) cat <<'EOF'
{"msgtype":"markdown","markdown":{"content":"**[${NOTIFY_LEVEL}] ${NOTIFY_APP} ${NOTIFY_EVENT}**\n> env: ${NOTIFY_ENV}\n> commit: ${NOTIFY_COMMIT}\n> ref: ${NOTIFY_REF}\n\n${NOTIFY_TEXT}"}}
EOF
      ;;
    generic)
      # The generic receiver gets the raw normalized payload verbatim.
      printf '%s' "$PAYLOAD"
      ;;
    *) return 1 ;;
  esac
}

IFS=','
for p in $PROVIDERS; do
  p=$(echo "$p" | tr -d ' ')
  [ -z "$p" ] && continue
  # Plugin dir name → canonical provider name (env prefix + /secrets layout).
  [ "$p" = "webhook-generic" ] && p="generic"
  case "$p" in
    dingtalk) _pfx="DINGTALK" ;;
    feishu)   _pfx="FEISHU"   ;;
    wecom)    _pfx="WECOM"    ;;
    generic)  _pfx="GENERIC"  ;;
    *)        _pfx="" ;;
  esac

  # webhook-url: mounted file first, env var fallback.
  url=""
  [ -s "/secrets/$p/webhook-url" ] && url=$(cat "/secrets/$p/webhook-url")
  if [ -z "$url" ] && [ -n "$_pfx" ]; then
    eval "url=\${${_pfx}_WEBHOOK_URL:-}"
  fi
  if [ -z "$url" ]; then
    echo "[WARN] $p: no webhook-url (no /secrets/$p mount and \$${_pfx:-?}_WEBHOOK_URL unset); skipping"
    continue
  fi

  # body: mounted template first, built-in default fallback.
  if [ -s "/templates/$p/body.tmpl" ]; then
    body=$(envsubst < "/templates/$p/body.tmpl")
  elif body=$(builtin_template "$p") && [ -n "$body" ]; then
    body=$(printf '%s' "$body" | envsubst)
  else
    echo "[WARN] $p: no body.tmpl mounted and no built-in template; skipping"
    continue
  fi

  # sign-secret: mounted file first, env var fallback (dingtalk/feishu only).
  sign_secret=""
  [ -s "/secrets/$p/sign-secret" ] && sign_secret=$(cat "/secrets/$p/sign-secret")
  if [ -z "$sign_secret" ] && [ -n "$_pfx" ]; then
    eval "sign_secret=\${${_pfx}_SIGN_SECRET:-}"
  fi

  # Per-provider HMAC signing — math lives in sign-webhook.sh (sourced above).
  if [ -n "$sign_secret" ] && [ "$HAVE_SIGN" -ne 1 ]; then
    echo "[WARN] $p: sign-secret configured but sign-webhook.sh missing — attempting UNSIGNED delivery (provider will likely reject)"
  fi
  if [ -n "$sign_secret" ] && [ "$HAVE_SIGN" -eq 1 ]; then
    ts=$(date +%s%3N)
    case "$p" in
      dingtalk)
        sig=$(sign_dingtalk "$ts" "$sign_secret")
        sig_enc=$(urlencode_sig "$sig")
        url="${url}&timestamp=${ts}&sign=${sig_enc}"
        ;;
      feishu)
        # Feishu injects timestamp + sign INTO the body envelope, not the URL.
        sig=$(sign_feishu "$ts" "$sign_secret")
        body=$(echo "$body" | jq --arg ts "$ts" --arg sg "$sig" \
          '. + {timestamp: $ts, sign: $sg}')
        ;;
      *)
        # WeCom and generic-webhook don't support HMAC.
        ;;
    esac
  fi

  # Generic-webhook optional Bearer token (file first, env fallback).
  curl_auth=""
  if [ "$p" = "generic" ]; then
    _bearer=""
    [ -s "/secrets/generic/bearer" ] && _bearer=$(cat /secrets/generic/bearer)
    [ -z "$_bearer" ] && _bearer="${GENERIC_WEBHOOK_BEARER:-}"
    [ -n "$_bearer" ] && curl_auth="Authorization: Bearer $_bearer"
  fi

  echo "[INFO] notify $p"
  if [ -n "$curl_auth" ]; then
    curl -fsS --max-time 10 -X POST \
      -H "Content-Type: application/json" -H "$curl_auth" \
      -d "$body" "$url" \
      || echo "[WARN] $p delivery failed (continuing)"
  else
    curl -fsS --max-time 10 -X POST \
      -H "Content-Type: application/json" \
      -d "$body" "$url" \
      || echo "[WARN] $p delivery failed (continuing)"
  fi
done

echo "[OK] notify-fanout done"
