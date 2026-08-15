#!/usr/bin/env bash
# =============================================================================
# outpost-verify-run.sh — payload of outpost-verify.service (the dead-man
# switch timer). Anti-silence layer 3: lives on the HOST, outside both the
# cluster and GitHub, so it still fires when either of those is what broke.
#
#   1. run ./verify.sh --quiet
#   2. exit 0 (all PASS) / 2 (WARN-only) → propagate silently
#   3. exit 1 (any FAIL)                → fan out a `verify-failed`
#      notification via scripts/notify-fanout.sh --env-file .env, then STILL
#      exit 1 so `systemctl status outpost-verify` shows red (honest exit).
#
# Notification delivery is best-effort (|| true): a dead DingTalk must not
# mask the FAIL exit code, which is the primary signal.
# bash-3.2 compatible.
# =============================================================================
set -uo pipefail

# Resolve the infra root from this script's location (platform/systemd/../..);
# OUTPOST_ROOT env wins when set (the rendered systemd unit sets WorkingDirectory).
_SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INFRA_ROOT="${OUTPOST_ROOT:-$(cd "$_SELF_DIR/../.." && pwd)}"
cd "$INFRA_ROOT" || { echo "ERROR: cannot cd to $INFRA_ROOT" >&2; exit 1; }

RC=0
bash ./verify.sh --quiet || RC=$?

if [[ "$RC" -eq 1 ]]; then
  # Any FAIL → notify. PROVIDERS/webhook config come from .env via --env-file.
  _HOSTNAME=$(hostname 2>/dev/null || echo unknown-host)
  PAYLOAD=$(printf '{"event":"verify-failed","level":"error","app":"outpost","env":"%s","commit":"","ref":"","url":"","text":"verify.sh reported FAIL on %s — run ./verify.sh for details"}' \
    "${OUTPOST_ENV:-dev}" "$_HOSTNAME")
  export PAYLOAD
  # PROVIDERS is populated by --env-file (NOTIFICATION_PROVIDERS in .env) —
  # export the mapping for fanout's env-based API.
  if [[ -f .env ]]; then
    # Detect a broken .env LOUDLY before quietly resolving providers from it —
    # a swallowed source error here would silently disable all alerting.
    # shellcheck disable=SC1091
    if ! (. ./.env >/dev/null 2>&1); then
      echo "[WARN] outpost-verify: .env failed to source (syntax error?) — provider resolution may be incomplete" >&2
    fi
    # shellcheck disable=SC1091
    NOTIFICATION_PROVIDERS=$(. ./.env 2>/dev/null; printf '%s' "${NOTIFICATION_PROVIDERS:-}")
  fi
  if [[ -z "${NOTIFICATION_PROVIDERS:-}" ]]; then
    echo "[WARN] outpost-verify: NOTIFICATION_PROVIDERS empty — verify-failed alert is LOG-ONLY (no push notification will arrive)" >&2
  fi
  export PROVIDERS="${NOTIFICATION_PROVIDERS:-}"
  bash scripts/notify-fanout.sh --env-file "$INFRA_ROOT/.env" || \
    echo "[WARN] verify-failed notification delivery failed (FAIL exit code still propagates)" >&2
fi

exit "$RC"
