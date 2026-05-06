#!/usr/bin/env bash
set -euo pipefail
missing=0
for v in GIT_USER GIT_TOKEN GIT_WEBHOOK_SECRET; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERR] gitee plugin requires env: $v" >&2
    missing=1
  fi
done
exit "$missing"
