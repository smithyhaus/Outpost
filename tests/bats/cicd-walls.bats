#!/usr/bin/env bats
# ===========================================================================
# Regression locks for the 6 CI/CD onboarding walls hit during the first
# real-project onboarding (SCM MCP, Apr–May 2026). B1/B2/B3/B5/B6 were fixed
# in the v0.3 cycle; C3 in Outpost v0.4 Phase 1. These tests fail loudly if a
# fix is ever silently reverted.
#
# Wall catalog: docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md
# All assertions are static-file greps — no cluster required, CI-safe.
# ===========================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PIPELINE="${INFRA_ROOT}/core/k8s/05-tekton/pipeline-build.yaml"
  TRIGGERTPL="${INFRA_ROOT}/core/k8s/05-tekton/triggertemplate.yaml"
  SECRETS="${INFRA_ROOT}/core/k8s/05-tekton/secrets.template.yaml"
  PHASE8="${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
  TRIGGERS=(
    "${INFRA_ROOT}/plugins/git-provider/gitee/trigger.yaml"
    "${INFRA_ROOT}/plugins/git-provider/github/trigger.yaml"
    "${INFRA_ROOT}/plugins/git-provider/gitlab/trigger.yaml"
  )
}

# ---- B1: pipeline params present ------------------------------------------
@test "B1: pipeline-build.yaml declares the registry-push param" {
  grep -qE '^[[:space:]]*- name: registry-push' "$PIPELINE"
}
@test "B1: pipeline-build.yaml declares the pusher param" {
  grep -qE '^[[:space:]]*- name: pusher' "$PIPELINE"
}
@test "B1: triggertemplate passes image-tag into the PipelineRun" {
  grep -qE '^[[:space:]]*- name: image-tag' "$TRIGGERTPL"
}

# ---- B2: kaniko pushes to registry-push host (in-cluster Service) ---------
@test "B2: build-and-push IMAGE uses params.registry-push" {
  grep -qF '$(params.registry-push)/$(params.repo-name)' "$PIPELINE"
}
@test "B2: registry-push param defaults to REGISTRY_PUSH_HOST" {
  grep -qF 'default: ${REGISTRY_PUSH_HOST}' "$PIPELINE"
}

# ---- B3: PipelineRun + per-task timeouts bumped ---------------------------
@test "B3: triggertemplate sets a pipeline-level timeout in hours" {
  grep -qE 'pipeline:[[:space:]]*"[0-9]+h' "$TRIGGERTPL"
}
@test "B3: build-and-push task carries an explicit timeout" {
  grep -qE 'timeout:[[:space:]]*"[0-9]+m"' "$PIPELINE"
}

# ---- B5: git-credentials secret carries .gitconfig ------------------------
@test "B5: secrets template ships .gitconfig with a credential helper" {
  grep -qF '.gitconfig:' "$SECRETS"
  grep -qF 'helper = store' "$SECRETS"
}

# ---- B6: tekton-pipelines namespace PSA downgraded to baseline ------------
@test "B6: phase 8 labels tekton-pipelines ns PSA enforce=baseline" {
  grep -qF 'pod-security.kubernetes.io/enforce=baseline' "$PHASE8"
}

# ---- C3: webhook triggers only the deploy branch --------------------------
@test "C3: no trigger.yaml accepts arbitrary branches via startsWith" {
  for f in "${TRIGGERS[@]}"; do
    if grep -qF "startsWith('refs/heads/')" "$f"; then
      echo "wall C3 regressed: $f still matches any branch" >&2
      return 1
    fi
  done
}
@test "C3: every trigger.yaml pins to OUTPOST_DEPLOY_BRANCH" {
  for f in "${TRIGGERS[@]}"; do
    if ! grep -qF "body.ref == 'refs/heads/\${OUTPOST_DEPLOY_BRANCH}'" "$f"; then
      echo "wall C3: $f does not pin the deploy branch" >&2
      return 1
    fi
  done
}
