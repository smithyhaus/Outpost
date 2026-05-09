#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${WECOM_WEBHOOK_URL:-}" ]]; then
  echo "[ERR] wecom plugin requires env: WECOM_WEBHOOK_URL" >&2
  exit 1
fi
exit 0
