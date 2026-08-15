#!/usr/bin/env bats
# =============================================================================
# Built-in service subdomain prefixes — env-driven invariants.
#
# Guards Goal #1 of the v0.5 refactor: every built-in service public hostname
# (search, mq, argocd, hooks, registry) must be operator-overridable via .env,
# not hardcoded in a template. caddyfile-fragments.bats covers search/mq
# (which live in the Caddyfile); this file covers the k3s-tier ingress
# templates + the registry plugin + the cloudflared reference doc.
#
# Why a separate file: the search/mq vars are read by Caddy at runtime
# (via `{$VAR:default}` syntax inside the Caddyfile). The argocd/hooks/
# registry vars are substituted by render_template at install time. Different
# mechanisms, different assertions.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # ArgoCD (core/k8s/04-argocd/) and Tekton (core/k8s/05-tekton/) were fully
  # removed in v0.3.0 — ARGOCD_HOST/HOOKS_HOST no longer exist as concepts,
  # not just relocated files. See the CI/CD dispatcher-engine plan.
  REGISTRY_MANIFEST="${INFRA_ROOT}/plugins/registry/self-hosted/manifest.yaml"
  REGISTRY_CFG="${INFRA_ROOT}/platform/lib/registry-config.sh"
  CONFIG_PHASE="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  COMPOSE_PHASE="${INFRA_ROOT}/bootstrap.d/04-compose.sh"
  INGRESSROUTES="${INFRA_ROOT}/core/k8s/06-bridges/ingressroutes.template.yaml"
  CLOUDFLARED_REF="${INFRA_ROOT}/core/compose/cloudflared/config.template.yml"
  ENV_EXAMPLE="${INFRA_ROOT}/.env.example"
}

@test "bridges ingressroutes: Host() uses \${SEARCH_HOST}/\${MQ_HOST}, not literal 'search'/'mq'" {
  # search/mq moved off Caddy in v0.3.0 (data layer now in-cluster); this
  # Traefik IngressRoute is their new home. Same env-driven contract as
  # argocd/hooks below, just a different rendering mechanism (render_template
  # via bootstrap.d/04-compose.sh's export, not bootstrap.d/02-config.sh —
  # see the comment in ingressroutes.template.yaml for why).
  [ -r "$INGRESSROUTES" ]
  run grep -E 'Host\(`\$\{SEARCH_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -eq 0 ]
  run grep -E 'Host\(`\$\{MQ_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -eq 0 ]
  run grep -E 'Host\(`search\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -ne 0 ]
  run grep -E 'Host\(`mq\.\$\{ROOT_DOMAIN\}`\)' "$INGRESSROUTES"
  [ "$status" -ne 0 ]
}

@test "bootstrap 04-compose: exports defaults for SEARCH_HOST / MQ_HOST" {
  # Defaults must be set (and exported, so later-sourced phases inherit them)
  # before render_template renders ingressroutes.template.yaml — its strict
  # \${VAR} residue check would otherwise reject an unset SEARCH_HOST/MQ_HOST.
  run grep -E 'export SEARCH_HOST="\$\{SEARCH_HOST:-search\}"' "$COMPOSE_PHASE"
  [ "$status" -eq 0 ]
  run grep -E 'export MQ_HOST="\$\{MQ_HOST:-mq\}"' "$COMPOSE_PHASE"
  [ "$status" -eq 0 ]
}

@test "registry plugin manifest: Host() uses computed \${REGISTRY_HOST}" {
  [ -r "$REGISTRY_MANIFEST" ]
  # The manifest defers to the upstream-computed REGISTRY_HOST (set by
  # platform/lib/registry-config.sh based on REGISTRY_SUBDOMAIN). Plugin
  # template should not re-derive the host from raw subdomain + ROOT_DOMAIN.
  run grep -E 'Host\(`\$\{REGISTRY_HOST\}`\)' "$REGISTRY_MANIFEST"
  [ "$status" -eq 0 ]
  run grep -E 'Host\(`registry\.\$\{ROOT_DOMAIN\}`\)' "$REGISTRY_MANIFEST"
  [ "$status" -ne 0 ]
}

@test "registry-config.sh: REGISTRY_HOST honors REGISTRY_SUBDOMAIN override" {
  run grep -E 'REGISTRY_HOST="\$\{REGISTRY_SUBDOMAIN:-registry\}\.\$\{ROOT_DOMAIN\}"' "$REGISTRY_CFG"
  [ "$status" -eq 0 ]
}

@test "bootstrap 02-config: exports default for REGISTRY_SUBDOMAIN" {
  # ARGOCD_HOST / HOOKS_HOST retired with ArgoCD/Tekton in v0.3.0 — no
  # ingress references them anymore (see the setup() comment above).
  # Default must be set before render_template runs (its strict ${VAR}
  # residue check would otherwise reject the template references).
  run grep -E 'REGISTRY_SUBDOMAIN="\$\{REGISTRY_SUBDOMAIN:-registry\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
}

@test "bootstrap 02-config: persists REGISTRY_SUBDOMAIN to .env" {
  # Re-bootstrap should see the same value via .env source — without this
  # echo line, a second run would re-default but break any operator
  # override set in the first run.
  run grep -E '^\s*echo "REGISTRY_SUBDOMAIN=\$\{REGISTRY_SUBDOMAIN\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
}

@test ".env.example: documents the new overrides (commented, with default)" {
  for v in REGISTRY_SUBDOMAIN; do
    run grep -E "^#\s*${v}=" "$ENV_EXAMPLE"
    [ "$status" -eq 0 ] || { echo "missing # ${v}= in .env.example"; return 1; }
  done
}

@test "cloudflared reference doc: uses templated hostnames (no .example.com literals)" {
  # The doc tells operators what to wire in the Cloudflare Dashboard. Using
  # template form makes the relationship to .env explicit.
  run grep -E 'hostname:\s+\$\{SEARCH_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  run grep -E 'hostname:\s+\$\{MQ_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  # And the literal example.com hostnames should all be gone.
  run grep -E 'hostname:\s+(argocd|hooks|registry|search|mq)\.example\.com' "$CLOUDFLARED_REF"
  [ "$status" -ne 0 ]
}

@test "cloudflared reference doc: retired v0.2 routes (argocd/hooks/tekton/rollouts) are ABSENT" {
  # v0.3 removed ArgoCD, the webhook receiver and both dashboards. A route
  # entry teaching operators to wire them again is a doc-code lie — assert
  # the live-route form never comes back (the retirement NOTE may mention
  # the names, so match the yaml `- hostname:` route form specifically).
  run grep -E '^\s*-\s+hostname:\s+.*(ARGOCD_HOST|HOOKS_HOST|tekton\.|rollouts\.)' "$CLOUDFLARED_REF"
  [ "$status" -ne 0 ]
}

@test "cloudflared reference doc: search/mq route to k3s Traefik NodePort, not caddy" {
  # v0.3.0: search/mq are in-cluster now (core/k8s/06-bridges/), reached the
  # same way every other k3s route is — not proxied through caddy anymore.
  run grep -E 'hostname:\s+\$\{SEARCH_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  run grep -E 'hostname:\s+\$\{MQ_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  run grep -E 'service:\s+http://caddy:80' "$CLOUDFLARED_REF"
  [ "$status" -ne 0 ]
}

@test "REGISTRY_SUBDOMAIN override end-to-end: registry-config.sh respects override" {
  # Source the lib and invoke resolve_registry_config in a clean subshell;
  # verify REGISTRY_HOST reflects the overridden subdomain.
  run bash -c '
    set -euo pipefail
    cd "'"$INFRA_ROOT"'"
    # shellcheck disable=SC1091
    source platform/lib/portable.sh
    source platform/lib/registry-config.sh
    REGISTRY_PLUGIN=self-hosted
    ROOT_DOMAIN=example.com
    REGISTRY_SUBDOMAIN=docker
    resolve_registry_config
    [[ "$REGISTRY_HOST" == "docker.example.com" ]] || { echo "got: $REGISTRY_HOST"; exit 1; }
  '
  [ "$status" -eq 0 ]
}

@test "REGISTRY_SUBDOMAIN default: registry-config.sh falls back to 'registry'" {
  run bash -c '
    set -euo pipefail
    cd "'"$INFRA_ROOT"'"
    # shellcheck disable=SC1091
    source platform/lib/portable.sh
    source platform/lib/registry-config.sh
    REGISTRY_PLUGIN=self-hosted
    ROOT_DOMAIN=example.com
    unset REGISTRY_SUBDOMAIN
    resolve_registry_config
    [[ "$REGISTRY_HOST" == "registry.example.com" ]] || { echo "got: $REGISTRY_HOST"; exit 1; }
  '
  [ "$status" -eq 0 ]
}
