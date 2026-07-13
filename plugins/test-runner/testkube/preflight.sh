#!/usr/bin/env bash
set -euo pipefail
# Testkube has no required env in OSS mode. Cloud mode requires an API key.
mode="${TESTKUBE_MODE:-skip}"
case "$mode" in
  skip|oss) ;;
  cloud)
    if [[ -z "${TESTKUBE_CLOUD_API_KEY:-}" ]]; then
      echo "[ERR] TESTKUBE_MODE=cloud requires TESTKUBE_CLOUD_API_KEY" >&2
      exit 1
    fi
    ;;
  *)
    echo "[ERR] TESTKUBE_MODE must be 'skip', 'oss' or 'cloud' (got '$mode')" >&2
    exit 1
    ;;
esac
exit 0
