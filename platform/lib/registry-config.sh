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
# Cache + snapshot flags — IMPORTANT:
#   NO --single-snapshot. It was here to halve per-build transient ephemeral
#     (one final snapshot instead of one per command), but it is MUTUALLY
#     EXCLUSIVE with --cache=true/--cache-repo: with a single end-of-build
#     snapshot kaniko never writes per-command layers to the cache-repo, so
#     nothing is ever cached — measured CACHE HIT=0 on a 41-min build. Removing
#     it restores per-layer caching, so an unchanged-lockfile rebuild reuses the
#     (7.8min + 20.7min) pnpm-install layers instead of re-downloading. The cost
#     is more transient ephemeral per build (was ~2 GB for the worst Python+Node
#     multi-stage); bump the shared-workspace volumeClaimTemplate in
#     triggertemplate.yaml if a large build hits the 5Gi cap.
#   --cache-copy-layers: also cache COPY layers (the `COPY package.json
#     pnpm-lock.yaml` layer that gates the install cache), not just RUN.
#   --snapshotMode=redo: detect file changes via filesystem mtime instead
#     of inode metadata. Less RAM + faster.
#   --use-new-run: kaniko's newer file-change tracker (recommended).
#   NOTE on correctness: layer caching is only safe when the deps install is
#     reproducible. App Dockerfiles that do `pnpm update "@hy/*"` float internal
#     packages and, once cached, ship STALE @hy/* — pin @hy/* in the lockfile
#     and drop the `pnpm update` line (app-repo change) before relying on cache.
#   Override by setting KANIKO_EXTRA_ARGS in .env before bootstrap.
# =============================================================================

resolve_registry_config() {
  # HY_REGISTRY (in-cluster Verdaccio for @hy/* npm packages) is independent
  # of which OCI image registry plugin is selected — Verdaccio ships
  # unconditionally (core/k8s/07-verdaccio) and Phase 8 renders it into both
  # the kaniko build args (self-hosted branch below) and the npm-publish
  # stack (task-npm-publish / pipeline-publish), which every cluster gets.
  # Default it here, NOT inside a case branch, or an aliyun-acr bootstrap
  # aborts in Phase 8 on the unresolved ${HY_REGISTRY} placeholder.
  HY_REGISTRY="${HY_REGISTRY:-http://verdaccio.registry.svc.cluster.local:4873/}"

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
      # see header for why this MUST NOT be a JSON array. Caching flags
      # (NO --single-snapshot, +--cache-copy-layers) — see header for why.
      # --registry-mirror: Dockerfile base images (FROM node:22-alpine, …) live
      # on Docker Hub (index.docker.io), which is reset/unreachable in CN — route
      # those pulls through the DaoCloud Docker Hub mirror. kaniko falls back to
      # index.docker.io if the mirror misses. Drop this flag for non-CN clusters.
      # --build-arg HY_REGISTRY: app Dockerfiles fetch the private @hy/* packages
      # from a Verdaccio registry (ARG HY_REGISTRY, dev-default
      # host.docker.internal:4873 — unresolvable in a build pod). Point every
      # build at the in-cluster Verdaccio (core/k8s/07-verdaccio). Overridable
      # via HY_REGISTRY in .env (unlike KANIKO_EXTRA_ARGS, which is unconditional).
      # (HY_REGISTRY itself is defaulted above the case — plugin-independent.)
      KANIKO_EXTRA_ARGS="--skip-tls-verify --insecure --registry-mirror=docker.m.daocloud.io --build-arg=HY_REGISTRY=${HY_REGISTRY} --cache=true --cache-repo=docker-registry.registry.svc.cluster.local:5000/cache --cache-copy-layers --snapshotMode=redo --use-new-run"
      ;;
    aliyun-acr)
      REGISTRY_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      REGISTRY_PUSH_HOST="${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}"
      # ACR is HTTPS-only — no --insecure (would force HTTP, which ACR refuses).
      # Same ephemeral-compression rationale as self-hosted — see header.
      # --registry-mirror: same rationale as self-hosted (see above) — Dockerfile
      # base images (FROM node:22-alpine, …) live on Docker Hub, unreachable in
      # CN. Route through the DaoCloud mirror regardless of which OCI registry
      # the built image is pushed to; kaniko falls back to index.docker.io on miss.
      KANIKO_EXTRA_ARGS="--registry-mirror=docker.m.daocloud.io --cache=true --cache-repo=${ALIYUN_ACR_REGISTRY}/${ALIYUN_ACR_NAMESPACE}/cache --cache-copy-layers --snapshotMode=redo --use-new-run"
      ;;
    *)
      err "REGISTRY_PLUGIN '${REGISTRY_PLUGIN:-(unset)}' lacks a kaniko config block in platform/lib/registry-config.sh"
      err "Add a case branch setting REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS"
      return 1
      ;;
  esac
  export REGISTRY_HOST REGISTRY_PUSH_HOST KANIKO_EXTRA_ARGS HY_REGISTRY
}
