#!/usr/bin/env bash
# =============================================================================
# resolve_registry_config — single source of truth for plugin-aware
# Pipeline defaults (REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS).
# -----------------------------------------------------------------------------
# Tested by tests/bats/registry-config.bats — modifying the case branches
# here REQUIRES adding/updating fixture-matched test cases.
#
# Side effects: exports REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS.
# Returns: 1 (with err) if REGISTRY_PLUGIN is unknown.
# Inputs : REGISTRY_PLUGIN, ROOT_DOMAIN (always), ALIYUN_ACR_REGISTRY +
#          ALIYUN_ACR_NAMESPACE (aliyun-acr only).
#
# KANIKO_EXTRA_ARGS shape — IMPORTANT, do not "fix" back to JSON:
#   Stored as a SPACE-SEPARATED string ("--skip-tls-verify --cache=true ..."),
#   NOT a JSON array literal. Tekton v0.50+ has a ParamValue handler that
#   re-parses any string matching the shape `[a,b,c]` as a YAML flow
#   sequence and then stringifies it without inner quotes — silently
#   turning a legitimate JSON array param into invalid JSON by the time the
#   consumer Task reads it. Space-separated text never matches the flow-seq
#   pattern, so the Tekton coercion never triggers. read-build-config.sh
#   converts back to JSON internally for yq merging. Anyone bringing this
#   back to JSON-array form WILL re-introduce the silent-coercion class of
#   bugs the project has hit twice already; the only correct change here
#   is space-separated tokens.
#
# Ephemeral-compression flags — IMPORTANT, single-node k3d dev hosts:
#   --single-snapshot: kaniko takes ONE filesystem snapshot at the end
#     instead of one per Dockerfile command. Cuts per-build transient
#     ephemeral by roughly half for multi-RUN Dockerfiles (e.g. SCM
#     MCP's Python+Node multi-stage was ~2 GB per build before this).
#     Trade-off: final image has fewer layers, slightly less cross-build
#     layer cache reuse on pull side — acceptable for dev CI/CD where
#     builds run on the same host that already has the layers cached.
#   --snapshot-mode=redo: detect file changes via filesystem mtime instead
#     of inode metadata. Less RAM + faster.
#   --use-new-run: kaniko's newer file-change tracker (recommended).
#   These are platform defaults — if a future app NEEDS the full per-
#   command snapshot semantics (e.g. weird COPY semantics across stages),
#   they can override by setting KANIKO_EXTRA_ARGS in .env before bootstrap.
# =============================================================================

resolve_registry_config() {
  case "${REGISTRY_PLUGIN:-}" in
    self-hosted)
      # Subdomain prefix is operator-overridable via REGISTRY_SUBDOMAIN in .env;
      # defaults to "registry". The full REGISTRY_HOST is then exported and
      # consumed by templates (k8s ingress, kaniko args) — they trust the
      # computed value instead of re-deriving from the prefix themselves.
      REGISTRY_HOST="${REGISTRY_SUBDOMAIN:-registry}.${ROOT_DOMAIN}"
      # Push to in-cluster Service to bypass cloudflared HTTP/2 large-blob limit.
      REGISTRY_PUSH_HOST="docker-registry.registry.svc.cluster.local:5000"
      # Insecure (HTTP, anonymous) + cache under /cache. Space-separated —
      # see header for why this MUST NOT be a JSON array. Ephemeral-
      # compression flags (single-snapshot et al) — see header for why.
      KANIKO_EXTRA_ARGS='--skip-tls-verify --insecure --cache=true --cache-repo=docker-registry.registry.svc.cluster.local:5000/cache --single-snapshot --snapshot-mode=redo --use-new-run'
      ;;
    aliyun-acr)
      REGISTRY_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      REGISTRY_PUSH_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      # ACR is HTTPS-only — no --insecure (would force HTTP, which ACR refuses).
      # Same ephemeral-compression rationale as self-hosted — see header.
      KANIKO_EXTRA_ARGS="--cache=true --cache-repo=${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}/cache --single-snapshot --snapshot-mode=redo --use-new-run"
      ;;
    *)
      err "REGISTRY_PLUGIN '${REGISTRY_PLUGIN:-(unset)}' lacks a kaniko config block in platform/lib/registry-config.sh"
      err "Add a case branch setting REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS"
      return 1
      ;;
  esac
  export REGISTRY_HOST REGISTRY_PUSH_HOST KANIKO_EXTRA_ARGS
}
