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
      # Insecure (HTTP, anonymous) + cache under /cache.
      KANIKO_EXTRA_ARGS='["--skip-tls-verify","--insecure","--cache=true","--cache-repo=docker-registry.registry.svc.cluster.local:5000/cache"]'
      ;;
    aliyun-acr)
      REGISTRY_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      REGISTRY_PUSH_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      # ACR is HTTPS-only — no --insecure (would force HTTP, which ACR refuses).
      # shellcheck disable=SC2089  # literal quotes are intended — value is a JSON-shape string for envsubst
      KANIKO_EXTRA_ARGS="[\"--cache=true\",\"--cache-repo=${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}/cache\"]"
      ;;
    *)
      err "REGISTRY_PLUGIN '${REGISTRY_PLUGIN:-(unset)}' lacks a kaniko config block in platform/lib/registry-config.sh"
      err "Add a case branch setting REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS"
      return 1
      ;;
  esac
  # shellcheck disable=SC2090  # intentional literal quotes; consumed by envsubst into pipeline-build.yaml
  export REGISTRY_HOST REGISTRY_PUSH_HOST KANIKO_EXTRA_ARGS
}
