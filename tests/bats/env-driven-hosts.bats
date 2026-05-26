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
  ARGOCD_ING="${INFRA_ROOT}/core/k8s/04-argocd/ingress.yaml"
  TEKTON_EL="${INFRA_ROOT}/core/k8s/05-tekton/eventlistener-base.yaml"
  REGISTRY_MANIFEST="${INFRA_ROOT}/plugins/registry/self-hosted/manifest.yaml"
  REGISTRY_CFG="${INFRA_ROOT}/platform/lib/registry-config.sh"
  CONFIG_PHASE="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  CLOUDFLARED_REF="${INFRA_ROOT}/core/compose/cloudflared/config.template.yml"
  ENV_EXAMPLE="${INFRA_ROOT}/.env.example"
}

@test "argocd ingress: Host() uses \${ARGOCD_HOST}, not literal 'argocd'" {
  [ -r "$ARGOCD_ING" ]
  run grep -E 'Host\(`\$\{ARGOCD_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$ARGOCD_ING"
  [ "$status" -eq 0 ]
  # Belt-and-suspenders: literal `argocd.${ROOT_DOMAIN}` must be gone.
  run grep -E 'Host\(`argocd\.\$\{ROOT_DOMAIN\}`\)' "$ARGOCD_ING"
  [ "$status" -ne 0 ]
}

@test "tekton eventlistener: Host() uses \${HOOKS_HOST}, not literal 'hooks'" {
  [ -r "$TEKTON_EL" ]
  run grep -E 'Host\(`\$\{HOOKS_HOST\}\.\$\{ROOT_DOMAIN\}`\)' "$TEKTON_EL"
  [ "$status" -eq 0 ]
  run grep -E 'Host\(`hooks\.\$\{ROOT_DOMAIN\}`\)' "$TEKTON_EL"
  [ "$status" -ne 0 ]
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

@test "bootstrap 02-config: exports defaults for ARGOCD_HOST / HOOKS_HOST / REGISTRY_SUBDOMAIN" {
  # Defaults must be set before render_template runs (its strict ${VAR}
  # residue check would otherwise reject the new template references).
  run grep -E 'ARGOCD_HOST="\$\{ARGOCD_HOST:-argocd\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
  run grep -E 'HOOKS_HOST="\$\{HOOKS_HOST:-hooks\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
  run grep -E 'REGISTRY_SUBDOMAIN="\$\{REGISTRY_SUBDOMAIN:-registry\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
}

@test "bootstrap 02-config: persists ARGOCD_HOST / HOOKS_HOST / REGISTRY_SUBDOMAIN to .env" {
  # Re-bootstrap should see the same values via .env source — without
  # these echo lines, a second run would re-default but break any
  # operator override set in the first run.
  run grep -E '^\s*echo "ARGOCD_HOST=\$\{ARGOCD_HOST\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
  run grep -E '^\s*echo "HOOKS_HOST=\$\{HOOKS_HOST\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
  run grep -E '^\s*echo "REGISTRY_SUBDOMAIN=\$\{REGISTRY_SUBDOMAIN\}"' "$CONFIG_PHASE"
  [ "$status" -eq 0 ]
}

@test ".env.example: documents the new overrides (commented, with default)" {
  for v in ARGOCD_HOST HOOKS_HOST REGISTRY_SUBDOMAIN; do
    run grep -E "^#\s*${v}=" "$ENV_EXAMPLE"
    [ "$status" -eq 0 ] || { echo "missing # ${v}= in .env.example"; return 1; }
  done
}

@test "cloudflared reference doc: uses templated hostnames (no .example.com literals)" {
  # The doc tells operators what to wire in the Cloudflare Dashboard. Using
  # template form makes the relationship to .env explicit.
  run grep -E 'hostname:\s+\$\{ARGOCD_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  run grep -E 'hostname:\s+\$\{HOOKS_HOST\}\.\$\{ROOT_DOMAIN\}' "$CLOUDFLARED_REF"
  [ "$status" -eq 0 ]
  # And the literal example.com hostnames should all be gone.
  run grep -E 'hostname:\s+(argocd|hooks|registry|search|mq)\.example\.com' "$CLOUDFLARED_REF"
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
