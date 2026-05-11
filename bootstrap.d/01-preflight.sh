# shellcheck shell=bash
# =============================================================================
# Phase 1 — Preflight: tools, OS detection, docker daemon
# Sourced by bootstrap.sh. Inherits set -euo pipefail + INFRA_ROOT + helpers.
# =============================================================================
phase "Phase 1 / 10 Preflight"

require_cmd bash curl openssl envsubst sed grep awk

if ! detect_os; then
  exit 1
fi
ok "OS detected: $SK_OS"

# Source platform-specific hooks
# shellcheck source=/dev/null
source "${INFRA_ROOT}/platform/${SK_OS}.sh"

# Docker
sk_install_docker

# docker compose v2
if ! docker compose version >/dev/null 2>&1; then
  err "docker compose v2 plugin required (try: brew/apt install docker-compose-plugin)"
  exit 1
fi
ok "docker compose v2 available"
