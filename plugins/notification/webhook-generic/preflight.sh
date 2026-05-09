#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${GENERIC_WEBHOOK_URL:-}" ]]; then
  echo "[ERR] webhook-generic plugin requires env: GENERIC_WEBHOOK_URL" >&2
  exit 1
fi
exit 0
