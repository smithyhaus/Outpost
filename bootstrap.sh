#!/usr/bin/env bash
# =============================================================================
# Outpost / bootstrap.sh — orchestrator (refactored 2026-05-11).
# -----------------------------------------------------------------------------
# Cross-platform one-command installer (macOS / Linux / WSL2).
#
# Two modes (set via OUTPOST_MODE in .env):
#
#   local : Compose data services only (PG / Redis / RabbitMQ / Manticore
#           on localhost). No CF Tunnel, no k3s, no GitOps. Zero required
#           input — every value either has a sensible default or gets
#           auto-generated. Phase 1 → 4 → 10-local.
#
#   full  : Everything in local + Cloudflare Tunnel + k3s + ArgoCD + Tekton
#           CI/CD + Testkube + Argo Rollouts + multi-channel notifications.
#           Requires ROOT_DOMAIN, CF_TUNNEL_TOKEN, GIT_USER, GIT_TOKEN
#           and MANIFEST_REPO_URL. Phase 1 → 10-full.
#
# Each phase lives in its own bootstrap.d/NN-*.sh file:
#   01-preflight        tools, OS detection, docker daemon
#   02-config           prompt/load .env, plugin selection, .env persist
#   03-render-infra     INFRA.md / INFRA.zh-CN.md
#   04-compose          PG / Redis / RabbitMQ / Manticore (+ tunnel)
#   ──── full mode only below ────
#   05-k3s              k3s install + namespaces + apps quota
#   06-sealed-secrets   controller + master-key backup/restore
#   07-registry-plugin  registry plugin + containerd mirror
#   08-argocd-tekton    ArgoCD + Tekton + Dashboard + BasicAuth
#   09-test-gate        Testkube + Argo Rollouts + notifications
#   ────────────────────────────────
#   10-summary-{local,full}
#
# Each phase script is sourced (not exec'd) so variables flow through to
# subsequent phases. The orchestrator inherits set -euo pipefail; phase
# scripts must NOT set their own.
# =============================================================================
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_ROOT"

# Source portable helpers + extracted lib functions (must come before any
# log/ok/warn calls or any phase script).
# shellcheck source=platform/lib/portable.sh
source "${INFRA_ROOT}/platform/lib/portable.sh"
# shellcheck source=platform/lib/registry-config.sh
source "${INFRA_ROOT}/platform/lib/registry-config.sh"
# shellcheck source=platform/lib/cel-helpers.sh
source "${INFRA_ROOT}/platform/lib/cel-helpers.sh"
# shellcheck source=platform/lib/eventlistener-assemble.sh
source "${INFRA_ROOT}/platform/lib/eventlistener-assemble.sh"
# shellcheck source=platform/lib/git-credentials.sh
source "${INFRA_ROOT}/platform/lib/git-credentials.sh"
# shellcheck source=platform/lib/host-capacity.sh
source "${INFRA_ROOT}/platform/lib/host-capacity.sh"

export SK_INFRA_DIR="$INFRA_ROOT"

# Phases 1-4 always run (local + full).
# shellcheck source=bootstrap.d/01-preflight.sh
source "${INFRA_ROOT}/bootstrap.d/01-preflight.sh"
# shellcheck source=bootstrap.d/02-config.sh
source "${INFRA_ROOT}/bootstrap.d/02-config.sh"
# shellcheck source=bootstrap.d/03-render-infra.sh
source "${INFRA_ROOT}/bootstrap.d/03-render-infra.sh"
# shellcheck source=bootstrap.d/04-compose.sh
source "${INFRA_ROOT}/bootstrap.d/04-compose.sh"

# Local mode short-circuit: Phases 5-9 require k3s + GitOps. Skip them.
if [[ "$OUTPOST_MODE" == "local" ]]; then
  # shellcheck source=bootstrap.d/10-summary-local.sh
  source "${INFRA_ROOT}/bootstrap.d/10-summary-local.sh"
  exit 0
fi

# Full-mode phases.
# shellcheck source=bootstrap.d/05-k3s.sh
source "${INFRA_ROOT}/bootstrap.d/05-k3s.sh"
# shellcheck source=bootstrap.d/06-sealed-secrets.sh
source "${INFRA_ROOT}/bootstrap.d/06-sealed-secrets.sh"
# shellcheck source=bootstrap.d/07-registry-plugin.sh
source "${INFRA_ROOT}/bootstrap.d/07-registry-plugin.sh"
# shellcheck source=bootstrap.d/08-argocd-tekton.sh
source "${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
# shellcheck source=bootstrap.d/09-test-gate.sh
source "${INFRA_ROOT}/bootstrap.d/09-test-gate.sh"
# shellcheck source=bootstrap.d/10-summary-full.sh
source "${INFRA_ROOT}/bootstrap.d/10-summary-full.sh"
