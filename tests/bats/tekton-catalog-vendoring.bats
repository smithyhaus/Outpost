#!/usr/bin/env bats
# =============================================================================
# Tekton catalog task vendoring.
#
# Guards: bootstrap MUST NOT fetch catalog tasks from
# raw.githubusercontent.com/tektoncd/catalog/main/...
#   - mutable ref (silent breakage when upstream re-edits a frozen version dir)
#   - intermittently throttled/blocked in CN (operator install fails)
#   - blocks offline bootstrap
#
# Vendored files live under core/k8s/05-tekton/catalog/ and are regenerated
# via scripts/vendor-tekton-catalog.sh. Each carries a SHA-pinned provenance
# header so an auditor can diff vendored vs upstream when bumping versions.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PHASE8="${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
  CATALOG="${INFRA_ROOT}/core/k8s/05-tekton/catalog"
  REGEN="${INFRA_ROOT}/scripts/vendor-tekton-catalog.sh"
}

@test "phase 8 does not curl tektoncd/catalog/main/ tasks" {
  # The pre-vendoring form was:
  #   kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/...
  # Any reintroduction of /main/ would re-open the silent-mutation hole.
  run grep -E 'tektoncd/catalog/main' "$PHASE8"
  [ "$status" -ne 0 ]
}

@test "phase 8 applies vendored catalog/*.yaml files" {
  grep -q 'core/k8s/05-tekton/catalog/git-clone-0\.10\.yaml' "$PHASE8"
  grep -q 'core/k8s/05-tekton/catalog/kaniko-0\.7\.yaml'    "$PHASE8"
}

@test "vendored catalog files exist, non-empty, and declare tekton.dev Task" {
  for f in git-clone-0.10.yaml kaniko-0.7.yaml; do
    [ -s "$CATALOG/$f" ] || { echo "missing or empty: $f"; return 1; }
    grep -qE '^apiVersion:\s*tekton\.dev/v1$' "$CATALOG/$f" \
      || { echo "$f: not tekton.dev/v1 Task"; return 1; }
    grep -qE '^kind:\s*Task$' "$CATALOG/$f" \
      || { echo "$f: not kind Task"; return 1; }
  done
}

@test "vendored catalog files carry a SHA-pinned provenance header" {
  for f in git-clone-0.10.yaml kaniko-0.7.yaml; do
    head -10 "$CATALOG/$f" | grep -q '^# VENDORED' \
      || { echo "$f: missing VENDORED header"; return 1; }
    head -10 "$CATALOG/$f" | grep -qE 'tektoncd/catalog @ [0-9a-f]{40}' \
      || { echo "$f: missing 40-char SHA in header"; return 1; }
  done
}

@test "regenerator script exists and is executable" {
  [ -x "$REGEN" ]
  # Sanity: the regenerator must point at the same paths we just asserted
  # exist. A divergence here would mean a future regen silently writes to
  # different files.
  grep -q 'git-clone-0.10.yaml' "$REGEN"
  grep -q 'kaniko-0.7.yaml'      "$REGEN"
}
