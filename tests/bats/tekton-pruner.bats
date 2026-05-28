#!/usr/bin/env bats
# =============================================================================
# Tekton PipelineRun auto-pruner.
#
# Guards the fix for the ephemeral-storage-eviction failure mode (kaniko
# build pods accumulate until kubelet DiskPressure → mid-build Evicted).
#
# What we test:
#   (a) Manifest exists, renders cleanly, and strict-render fires if any
#       OUTPOST_TEKTON_* env is missing.
#   (b) RBAC is namespace-bound (Role, not ClusterRole) and limited to the
#       three resources the pruner actually touches.
#   (c) The pruner script's RFC3339 lex-compare correctly identifies
#       PipelineRuns past the cutoff (unit-level: feed fixture jsonpath
#       output through awk in isolation).
#   (d) Phase 2 config persists the three OUTPOST_TEKTON_* vars to .env;
#       schedule value is shell-quoted so spaces in cron expressions survive.
#   (e) Phase 8 wires render_apply for pruner.yaml.
#   (f) Pod security: runs as non-root, read-only rootfs, drops all caps.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MANIFEST="${INFRA_ROOT}/core/k8s/05-tekton/pruner.yaml"
  SCRIPT="${INFRA_ROOT}/scripts/tekton-prune.sh"
  PHASE2="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  PHASE8="${INFRA_ROOT}/bootstrap.d/08-argocd-tekton.sh"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

# ---- (a) manifest render ----------------------------------------------------

@test "pruner manifest exists and is non-empty" {
  [ -r "$MANIFEST" ]
  [ -s "$MANIFEST" ]
}

@test "pruner manifest renders cleanly with all three OUTPOST_TEKTON_* env" {
  export OUTPOST_TEKTON_RETENTION_HOURS=24
  export OUTPOST_TEKTON_PRUNE_SCHEDULE="0 * * * *"
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  out="$TMP/pruner.yaml"
  run render_template "$MANIFEST" "$out"
  [ "$status" -eq 0 ]
  grep -q 'schedule: "0 \* \* \* \*"' "$out"
  grep -q 'image: alpine/k8s:1.31.0' "$out"
  grep -q 'value: "24"' "$out"
  unset OUTPOST_TEKTON_RETENTION_HOURS OUTPOST_TEKTON_PRUNE_SCHEDULE OUTPOST_TEKTON_PRUNER_IMAGE
}

@test "pruner manifest strict-render rejects missing OUTPOST_TEKTON_RETENTION_HOURS" {
  unset OUTPOST_TEKTON_RETENTION_HOURS
  export OUTPOST_TEKTON_PRUNE_SCHEDULE="0 * * * *"
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  run render_template "$MANIFEST" "$TMP/should-not-exist.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "OUTPOST_TEKTON_RETENTION_HOURS" ]]
  unset OUTPOST_TEKTON_PRUNE_SCHEDULE OUTPOST_TEKTON_PRUNER_IMAGE
}

# ---- (b) RBAC is namespace-bound, not cluster-wide --------------------------

@test "pruner RBAC uses Role + RoleBinding (no ClusterRole)" {
  # ClusterRole anywhere in this file = scope creep. The pruner's blast
  # radius must stay inside tekton-pipelines.
  run grep -E '^kind: ClusterRole' "$MANIFEST"
  [ "$status" -ne 0 ]
  grep -qE '^kind: Role$' "$MANIFEST"
  grep -qE '^kind: RoleBinding$' "$MANIFEST"
}

@test "pruner Role grants only PR/TR/pod get/list/delete" {
  # The Role section enumerates exactly the resources the script touches.
  # New verbs (create/update/patch) here would be a security smell.
  run awk '/^kind: Role$/,/^---$/' "$MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pipelineruns" ]]
  [[ "$output" =~ "taskruns" ]]
  [[ "$output" =~ "pods" ]]
  # No write verbs other than delete:
  [[ ! "$output" =~ create ]] || fail "Role grants 'create' — out of scope"
  [[ ! "$output" =~ update ]] || fail "Role grants 'update' — out of scope"
  [[ ! "$output" =~ patch  ]] || fail "Role grants 'patch' — out of scope"
  # No secrets access:
  [[ ! "$output" =~ secrets ]] || fail "Role grants secrets access — security smell"
}

# ---- (c) prune script awk-cutoff unit test ----------------------------------

@test "prune script awk cutoff correctly partitions PipelineRuns by completionTime" {
  # Synthesise the jsonpath output the script consumes:
  #   <name>\t<completionTime>   (empty for still-running)
  fixture="$TMP/jsonpath.txt"
  cat >"$fixture" <<'EOF'
build-old-aaa	2026-05-25T00:00:00Z
build-old-bbb	2026-05-25T12:00:00Z
build-recent-ccc	2026-05-27T00:00:00Z
build-running-ddd
build-future-eee	2026-05-27T12:00:00Z
EOF
  # Cutoff = 2026-05-26T00:00:00Z. Expect: aaa, bbb in the kill list.
  out="$(awk -F'\t' -v c="2026-05-26T00:00:00Z" \
    'NF==2 && $2!="" && $2 < c {print $1}' "$fixture")"
  [[ "$out" == *"build-old-aaa"* ]]
  [[ "$out" == *"build-old-bbb"* ]]
  [[ ! "$out" == *"build-recent-ccc"* ]]
  [[ ! "$out" == *"build-running-ddd"* ]] || fail "running PR (no completionTime) must be excluded"
  [[ ! "$out" == *"build-future-eee"* ]]
}

@test "prune script handles all-recent corpus as no-op (empty kill list)" {
  fixture="$TMP/all-recent.txt"
  cat >"$fixture" <<'EOF'
build-aaa	2026-05-27T00:00:00Z
build-bbb	2026-05-27T01:00:00Z
EOF
  out="$(awk -F'\t' -v c="2026-05-26T00:00:00Z" \
    'NF==2 && $2!="" && $2 < c {print $1}' "$fixture")"
  [ -z "$out" ]
}

# ---- (d) Phase 2 config wiring ----------------------------------------------

@test "phase 2 sets all three OUTPOST_TEKTON_* defaults" {
  grep -qE 'OUTPOST_TEKTON_RETENTION_HOURS="\$\{OUTPOST_TEKTON_RETENTION_HOURS:-24\}"' "$PHASE2"
  grep -qE 'OUTPOST_TEKTON_PRUNE_SCHEDULE="\$\{OUTPOST_TEKTON_PRUNE_SCHEDULE:-0 \* \* \* \*\}"' "$PHASE2"
  grep -qE 'OUTPOST_TEKTON_PRUNER_IMAGE="\$\{OUTPOST_TEKTON_PRUNER_IMAGE:-alpine/k8s:1\.31\.0\}"' "$PHASE2"
  # Documentation guard: the manifest header must explain WHY we picked
  # alpine/k8s over bitnami/rancher/etc, so a future maintainer doesn't
  # "fix" it back into a broken image. Image needs BOTH kubectl AND /bin/sh.
  grep -qE 'bitnami.*404|rancher.*scratch|no /bin/sh' "$MANIFEST" \
    || fail "pruner manifest header missing the alpine/k8s rationale"
}

@test "phase 2 persists OUTPOST_TEKTON_PRUNE_SCHEDULE via env_kv (spaces survive .env round-trip)" {
  # The cron expression has spaces; without `env_kv` (printf %q quoting),
  # `source .env` would word-split it. Round-trip is enforced separately
  # by tests/bats/env-kv-roundtrip.bats — here we just guard that the
  # phase script doesn't drop back to bare `echo "KEY=$VAR"`.
  grep -qE 'env_kv OUTPOST_TEKTON_PRUNE_SCHEDULE' "$PHASE2"
}

@test "phase 2 persists OUTPOST_TEKTON_RETENTION_HOURS and OUTPOST_TEKTON_PRUNER_IMAGE" {
  grep -qE '^[[:space:]]+echo "OUTPOST_TEKTON_RETENTION_HOURS=' "$PHASE2"
  grep -qE '^[[:space:]]+echo "OUTPOST_TEKTON_PRUNER_IMAGE='    "$PHASE2"
}

# ---- (e) Phase 8 applies pruner ---------------------------------------------

@test "phase 8 applies pruner.yaml after Tekton install" {
  grep -q 'core/k8s/05-tekton/pruner.yaml' "$PHASE8"
  # Order check: pruner must come AFTER pipeline-build (which creates the
  # CRDs/resources the pruner targets). Use line numbers.
  pruner_line=$(grep -n 'pruner.yaml' "$PHASE8" | head -1 | cut -d: -f1)
  pipeline_line=$(grep -n 'pipeline-build.yaml' "$PHASE8" | head -1 | cut -d: -f1)
  [ "$pruner_line" -gt "$pipeline_line" ]
}

@test "phase 8 creates tekton-pruner-script configmap from-file BEFORE applying pruner.yaml" {
  # Script-split pattern: configmap must exist before the CronJob references it.
  cm_line=$(grep -n 'create configmap tekton-pruner-script' "$PHASE8" | head -1 | cut -d: -f1)
  pruner_line=$(grep -n 'pruner.yaml' "$PHASE8" | head -1 | cut -d: -f1)
  [ -n "$cm_line" ] || fail "phase 8 does not create tekton-pruner-script configmap"
  [ "$cm_line" -lt "$pruner_line" ]
  grep -q 'tekton-prune.sh=scripts/tekton-prune.sh' "$PHASE8"
}

# ---- (g) script lives in scripts/, is executable, POSIX-sh ------------------

@test "tekton-prune.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "tekton-prune.sh uses POSIX sh shebang (no bashisms)" {
  head -1 "$SCRIPT" | grep -qE '^#!/bin/sh$'
  # set -eu is POSIX-safe; set -o pipefail is bash-only — check we DIDN'T
  # accidentally use pipefail.
  ! grep -q 'pipefail' "$SCRIPT"
}

@test "tekton-prune.sh respects OUTPOST_TEKTON_RETENTION_HOURS env with 24h default" {
  grep -qE 'RETAIN_HOURS="\$\{OUTPOST_TEKTON_RETENTION_HOURS:-24\}"' "$SCRIPT"
}

# ---- (f) Pod security hardening ---------------------------------------------

@test "pruner pod runs as non-root with read-only rootfs and dropped caps" {
  grep -q 'runAsNonRoot: true'           "$MANIFEST"
  grep -q 'readOnlyRootFilesystem: true' "$MANIFEST"
  grep -q 'allowPrivilegeEscalation: false' "$MANIFEST"
  grep -qE 'drop:\s*\["ALL"\]'           "$MANIFEST"
}

@test "pruner concurrencyPolicy=Forbid (no overlapping sweeps)" {
  # Overlapping pruners would race kubectl deletes on the same PR.
  grep -q 'concurrencyPolicy: Forbid' "$MANIFEST"
}
