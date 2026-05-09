#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${FEISHU_WEBHOOK_URL:-}" ]]; then
  echo "[ERR] feishu plugin requires env: FEISHU_WEBHOOK_URL" >&2
  exit 1
fi
exit 0
