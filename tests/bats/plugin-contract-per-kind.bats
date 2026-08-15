#!/usr/bin/env bats
# =============================================================================
# Per-kind plugin contract: extras every plugin of a given `kind:` MUST ship.
# -----------------------------------------------------------------------------
# tests/bats/plugin-contract.bats enforces the universal contract (plugin.yaml
# + preflight.sh + README.md + manifest-or-compose). v0.3 (plugin contract v2)
# retired BOTH per-kind extras that existed pre-v0.3:
#
#   notification → argocd-cm-fragment.yaml + argocd-secret-fragment.yaml
#                  (ArgoCD is gone; manifest.yaml alone now describes what
#                  the manifest-sync CronJob / GitHub Actions workflow /
#                  verify.sh systemd timer consume)
#   git-provider → trigger.yaml
#                  (the inbound-webhook/EventListener path retired with
#                  Tekton; git-provider plugins are credential + host-
#                  matching contracts consumed by preflight.sh + verify.sh)
#
# No kind currently ships extras beyond the universal contract. This file is
# kept (rather than deleted) so a FUTURE kind that needs extras has a
# deliberate place to declare them — the dispatch test below fails loudly on
# an unrecognised kind instead of silently passing.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# Read the `kind:` field from a plugin.yaml. POSIX-ish; no yq dependency.
_plugin_kind() {
  awk '/^kind:[[:space:]]/ {print $2; exit}' "$1"
}

# Per-kind required extras (relative to the plugin's directory).
# Edit this map (and the dispatch test) when adding a new kind that ships
# extras beyond the universal contract.
_required_extras_for_kind() {
  case "$1" in
    notification|git-provider|registry|test-runner|rollout)
      echo ""   # no extras (v0.3 plugin contract v2)
      ;;
    *)
      # Unknown kind. The dispatch test below will flag this so a new
      # kind gets a deliberate entry instead of silently passing.
      echo "__UNKNOWN_KIND__"
      ;;
  esac
}

# ---- 1. Dispatch covers every kind currently in the repo --------------------

@test "every plugin kind is recognised by the dispatcher" {
  while IFS= read -r f; do
    kind=$(_plugin_kind "$f")
    [ -n "$kind" ] || fail "no 'kind:' in $f"
    extras=$(_required_extras_for_kind "$kind")
    [ "$extras" != "__UNKNOWN_KIND__" ] || fail "unhandled kind '$kind' in $f — add a branch to _required_extras_for_kind"
  done < <(find "${INFRA_ROOT}/plugins" -name plugin.yaml)
}

# ---- 2. Retired per-kind extras stay retired --------------------------------

@test "no notification plugin ships the retired argocd-cm-fragment.yaml / argocd-secret-fragment.yaml" {
  while IFS= read -r dir; do
    f="$dir/plugin.yaml"
    [ -f "$f" ] || continue
    kind=$(_plugin_kind "$f")
    [ "$kind" = "notification" ] || continue
    [ ! -f "$dir/argocd-cm-fragment.yaml" ] \
      || fail "notification plugin $(basename "$dir") still ships argocd-cm-fragment.yaml — retired in v0.3 (ArgoCD removed)"
    [ ! -f "$dir/argocd-secret-fragment.yaml" ] \
      || fail "notification plugin $(basename "$dir") still ships argocd-secret-fragment.yaml — retired in v0.3 (ArgoCD removed)"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

@test "no git-provider plugin ships the retired trigger.yaml" {
  while IFS= read -r dir; do
    f="$dir/plugin.yaml"
    [ -f "$f" ] || continue
    kind=$(_plugin_kind "$f")
    [ "$kind" = "git-provider" ] || continue
    [ ! -f "$dir/trigger.yaml" ] \
      || fail "git-provider plugin $(basename "$dir") still ships trigger.yaml — retired in v0.3 (inbound webhook/EventListener path removed)"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

# ---- 3. Negative: no kind ships either retired extra ------------------------

@test "no plugin of any kind ships argocd-*-fragment.yaml or trigger.yaml (v0.3: no per-kind extras)" {
  while IFS= read -r dir; do
    [ -f "$dir/plugin.yaml" ] || continue
    [ ! -f "$dir/argocd-cm-fragment.yaml" ] \
      || fail "$(basename "$dir") ships argocd-cm-fragment.yaml — retired in v0.3"
    [ ! -f "$dir/argocd-secret-fragment.yaml" ] \
      || fail "$(basename "$dir") ships argocd-secret-fragment.yaml — retired in v0.3"
    [ ! -f "$dir/trigger.yaml" ] \
      || fail "$(basename "$dir") ships trigger.yaml — retired in v0.3"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}
