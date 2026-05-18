#!/bin/sh
# =============================================================================
# scripts/notify-fanout.sh — fan-out a normalized notification payload to
# every enabled provider plugin (DingTalk / Feishu / WeCom / generic webhook).
#
# Extracted from core/k8s/05-tekton/notify-task.yaml (v0.3). The Tekton Task
# now ConfigMap-mounts this script alongside platform/lib/sign-webhook.sh at
# /scripts, so signing math has ONE source of truth (sign-webhook.sh) instead
# of two (this file's interim previous-life inline copy in the Task YAML).
#
# Reads from environment:
#   PAYLOAD    — normalized JSON (event/level/app/env/commit/ref/url/text/pusher)
#   PROVIDERS  — comma-separated list of provider names
#
# Reads from filesystem (each plugin's mounts; `optional: true` in the Task):
#   /secrets/<p>/webhook-url        — REQUIRED to deliver to <p>
#   /secrets/<p>/sign-secret        — OPTIONAL (HMAC for dingtalk/feishu)
#   /secrets/generic/bearer         — OPTIONAL Bearer auth for generic webhook
#   /templates/<p>/body.tmpl        — REQUIRED envsubst template
#
# Delivery semantics:
#   - per-provider failures DON'T block other providers
#   - missing webhook-url / body.tmpl → skip provider (logged)
#   - script always exits 0; PipelineRun success isn't gated on delivery
#     (that would let a transient DingTalk outage fail every build).
#
# Required commands (must be on PATH inside the container):
#   jq, curl, envsubst, openssl, base64
#   alpine:3.20 ships none — the Task currently `apk add` them at runtime;
#   v0.4 will bake them into an outpost/notify-runner image.
# =============================================================================
set -eu

# Sourced for sign_dingtalk / sign_feishu / urlencode_sig. Mounted via
# the same ConfigMap as this script.
# shellcheck source=/dev/null  # /scripts/sign-webhook.sh — runtime mount path
. /scripts/sign-webhook.sh

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

IFS=','
for p in $PROVIDERS; do
  p=$(echo "$p" | tr -d ' ')
  [ -z "$p" ] && continue

  WEBHOOK="/secrets/$p/webhook-url"
  TEMPLATE="/templates/$p/body.tmpl"
  SIGN="/secrets/$p/sign-secret"

  if [ ! -s "$WEBHOOK" ]; then
    echo "[WARN] $p: no webhook-url Secret mounted; skipping"
    continue
  fi
  if [ ! -s "$TEMPLATE" ]; then
    echo "[WARN] $p: no body.tmpl ConfigMap mounted; skipping"
    continue
  fi
  url=$(cat "$WEBHOOK")
  body=$(envsubst < "$TEMPLATE")

  # Per-provider HMAC signing — math lives in sign-webhook.sh (sourced above).
  if [ -s "$SIGN" ]; then
    sign_secret=$(cat "$SIGN")
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

  # Generic-webhook optional Bearer token.
  curl_auth=""
  if [ "$p" = "generic" ] && [ -s "/secrets/generic/bearer" ]; then
    curl_auth="Authorization: Bearer $(cat /secrets/generic/bearer)"
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
