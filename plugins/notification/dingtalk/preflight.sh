#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DINGTALK_WEBHOOK_URL:-}" ]]; then
  echo "[ERR] dingtalk plugin requires env: DINGTALK_WEBHOOK_URL" >&2
  exit 1
fi
exit 0
