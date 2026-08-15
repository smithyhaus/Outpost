#!/usr/bin/env bash
set -euo pipefail
# Argo Rollouts has no required env. Controller-only (v0.3) — no dashboard,
# so no ROLLOUTS_DASHBOARD_HOST to derive or validate either.
exit 0
