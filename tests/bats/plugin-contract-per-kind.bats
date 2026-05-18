#!/usr/bin/env bats
# =============================================================================
# Per-kind plugin contract: extras every plugin of a given `kind:` MUST ship.
# -----------------------------------------------------------------------------
# tests/bats/plugin-contract.bats enforces the universal contract (plugin.yaml
# + preflight.sh + README.md + manifest-or-compose). This file adds the
# kind-specific layer:
#
#   notification → argocd-cm-fragment.yaml + argocd-secret-fragment.yaml
#                  (consumed by bootstrap.d/09 when wiring argocd-notifications)
#   git-provider → trigger.yaml
#                  (consumed by platform/lib/eventlistener-assemble.sh to
#                  splice into the EventListener envelope)
#   everything else → (no extras)
#
# Why this matters: a contributor copying gitee/ to scaffold a new
# notification plugin would PASS plugin-contract.bats but produce a
# silently-broken install because bootstrap.d/09 would cat a missing
# argocd-cm-fragment.yaml.
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
    notification)
      echo "argocd-cm-fragment.yaml argocd-secret-fragment.yaml"
      ;;
    git-provider)
      echo "trigger.yaml"
      ;;
    registry|test-runner|rollout)
      echo ""   # no extras
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

# ---- 2. Per-kind extras: assert presence ------------------------------------

@test "every notification plugin ships argocd-cm-fragment.yaml + argocd-secret-fragment.yaml" {
  while IFS= read -r dir; do
    f="$dir/plugin.yaml"
    [ -f "$f" ] || continue
    kind=$(_plugin_kind "$f")
    [ "$kind" = "notification" ] || continue
    [ -f "$dir/argocd-cm-fragment.yaml" ] \
      || fail "notification plugin $(basename "$dir") missing argocd-cm-fragment.yaml"
    [ -f "$dir/argocd-secret-fragment.yaml" ] \
      || fail "notification plugin $(basename "$dir") missing argocd-secret-fragment.yaml"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

@test "every git-provider plugin ships trigger.yaml" {
  while IFS= read -r dir; do
    f="$dir/plugin.yaml"
    [ -f "$f" ] || continue
    kind=$(_plugin_kind "$f")
    [ "$kind" = "git-provider" ] || continue
    [ -f "$dir/trigger.yaml" ] \
      || fail "git-provider plugin $(basename "$dir") missing trigger.yaml — required by assemble_eventlistener since v0.3"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

# ---- 3. Negative: kinds without per-kind extras don't sprout surprises -----

@test "registry / test-runner / rollout plugins don't accidentally ship per-kind extras (would imply new contract)" {
  # If a plugin of kind X ships a file that's a known extra of some OTHER
  # kind, that's almost certainly a copy-paste leftover — flag it.
  while IFS= read -r dir; do
    f="$dir/plugin.yaml"
    [ -f "$f" ] || continue
    kind=$(_plugin_kind "$f")
    case "$kind" in
      registry|test-runner|rollout)
        [ ! -f "$dir/argocd-cm-fragment.yaml" ] \
          || fail "$(basename "$dir") (kind=$kind) ships argocd-cm-fragment.yaml — only notification plugins should"
        [ ! -f "$dir/trigger.yaml" ] \
          || fail "$(basename "$dir") (kind=$kind) ships trigger.yaml — only git-provider plugins should"
        ;;
    esac
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}
