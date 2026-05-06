#!/usr/bin/env bash
# aliyun-acr registry plugin: preflight validation
set -euo pipefail
missing=0
for v in ALIYUN_ACR_REGISTRY ALIYUN_ACR_NAMESPACE ALIYUN_ACR_USER ALIYUN_ACR_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    echo "[ERR] aliyun-acr plugin requires env: $v" >&2
    missing=1
  fi
done
exit "$missing"
