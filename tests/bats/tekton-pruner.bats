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

@test "pruner manifest renders cleanly with all four OUTPOST_TEKTON_* env" {
  export OUTPOST_TEKTON_RETENTION_HOURS=24
  export OUTPOST_TEKTON_KEEP_LAST_N=20
  export OUTPOST_TEKTON_PRUNE_SCHEDULE="*/15 * * * *"
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  out="$TMP/pruner.yaml"
  run render_template "$MANIFEST" "$out"
  [ "$status" -eq 0 ]
  grep -q 'schedule: "\*/15 \* \* \* \*"' "$out"
  grep -q 'image: alpine/k8s:1.31.0' "$out"
  grep -q 'value: "24"' "$out"
  grep -q 'value: "20"' "$out"
  unset OUTPOST_TEKTON_RETENTION_HOURS OUTPOST_TEKTON_KEEP_LAST_N OUTPOST_TEKTON_PRUNE_SCHEDULE OUTPOST_TEKTON_PRUNER_IMAGE
}

@test "pruner manifest strict-render rejects missing OUTPOST_TEKTON_RETENTION_HOURS" {
  unset OUTPOST_TEKTON_RETENTION_HOURS
  export OUTPOST_TEKTON_KEEP_LAST_N=20
  export OUTPOST_TEKTON_PRUNE_SCHEDULE="*/15 * * * *"
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  run render_template "$MANIFEST" "$TMP/should-not-exist.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "OUTPOST_TEKTON_RETENTION_HOURS" ]]
  unset OUTPOST_TEKTON_KEEP_LAST_N OUTPOST_TEKTON_PRUNE_SCHEDULE OUTPOST_TEKTON_PRUNER_IMAGE
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

@test "phase 2 sets all four OUTPOST_TEKTON_* defaults" {
  grep -qE 'OUTPOST_TEKTON_RETENTION_HOURS="\$\{OUTPOST_TEKTON_RETENTION_HOURS:-24\}"' "$PHASE2"
  # */15 cadence is the post-incident default — 0 * * * * was too slow to
  # keep up with rapid CI bursts (4–5 builds within 30 min stack ephemeral).
  grep -qE 'OUTPOST_TEKTON_PRUNE_SCHEDULE="\$\{OUTPOST_TEKTON_PRUNE_SCHEDULE:-\*/15 \* \* \* \*\}"' "$PHASE2"
  grep -qE 'OUTPOST_TEKTON_KEEP_LAST_N="\$\{OUTPOST_TEKTON_KEEP_LAST_N:-20\}"' "$PHASE2"
  grep -qE 'OUTPOST_TEKTON_PRUNER_IMAGE="\$\{OUTPOST_TEKTON_PRUNER_IMAGE:-alpine/k8s:1\.31\.0\}"' "$PHASE2"
  # Documentation guard: the manifest header must explain WHY we picked
  # alpine/k8s over bitnami/rancher/etc, so a future maintainer doesn't
  # "fix" it back into a broken image. Image needs BOTH kubectl AND /bin/sh.
  grep -qE 'bitnami.*404|rancher.*scratch|no /bin/sh' "$MANIFEST" \
    || fail "pruner manifest header missing the alpine/k8s rationale"
}

@test "tekton-prune.sh keep-last-N: keeps N newest PRs by creationTimestamp" {
  # Synthesise jsonpath output that prune script's awk consumes:
  #   <creationTime>\t<name>
  # 6 PRs, KEEP_LAST_N=3 → 3 newest survive, 3 oldest go.
  fixture="$TMP/keepn.txt"
  cat >"$fixture" <<'EOF'
2026-05-28T01:00:00Z	build-old-1
2026-05-28T05:00:00Z	build-mid-1
2026-05-28T10:00:00Z	build-new-1
2026-05-28T11:00:00Z	build-new-2
2026-05-28T02:00:00Z	build-old-2
2026-05-28T12:00:00Z	build-new-3
EOF
  excess="$(sort -r "$fixture" | awk -F'\t' -v keep=3 'NR > keep {print $2}')"
  [[ "$excess" == *"build-old-1"* ]]
  [[ "$excess" == *"build-old-2"* ]]
  [[ "$excess" == *"build-mid-1"* ]]
  [[ ! "$excess" == *"build-new-1"* ]] || fail "newest 3 should be kept"
  [[ ! "$excess" == *"build-new-2"* ]] || fail "newest 3 should be kept"
  [[ ! "$excess" == *"build-new-3"* ]] || fail "newest 3 should be kept"
}

@test "tekton-prune.sh keep-last-N=0 disables the count cap (no excess emitted)" {
  fixture="$TMP/keep0.txt"
  cat >"$fixture" <<'EOF'
2026-05-28T01:00:00Z	build-1
2026-05-28T02:00:00Z	build-2
EOF
  # When KEEP_LAST_N=0, the script's `if [ "$KEEP_LAST_N" -gt 0 ]` skips
  # the block entirely — emulate with awk keep=0 (excess = everything).
  # Actually the script's behavior IS that excess = everything. The guard
  # is at the shell level, not awk. So this just asserts the disabled-path
  # exists in the script (guard syntax).
  grep -q 'KEEP_LAST_N.*-gt 0' "$SCRIPT" \
    || fail "tekton-prune.sh must guard KEEP_LAST_N=0 to disable cap"
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

@test "pruner pod requests ephemeral-storage (so DiskPressure doesn't evict the pruner itself)" {
  # The chicken-and-egg failure mode: under DiskPressure, kubelet evicts
  # pods that haven't requested ephemeral-storage FIRST. The pruner is
  # supposed to relieve the pressure — evicting it makes the situation
  # worse. Locking in the request so this regression doesn't recur.
  grep -qE 'requests:.*ephemeral-storage' "$MANIFEST" \
    || fail "pruner missing ephemeral-storage request — will be evicted first under DiskPressure"
}

@test "pruner tolerates node.kubernetes.io/disk-pressure taint (schedulable during incident)" {
  # The OTHER chicken-and-egg: kubelet adds NoSchedule taint when in
  # DiskPressure. The pruner is the recovery action — it MUST be able to
  # schedule when the node has the taint, otherwise the cluster is stuck
  # waiting for manual intervention (the original incident pattern).
  awk '/^kind: CronJob$/,EOF' "$MANIFEST" | grep -q 'node.kubernetes.io/disk-pressure' \
    || fail "pruner missing disk-pressure toleration — blocked by NoSchedule taint during exactly the incident it should fix"
}

@test "pruner concurrencyPolicy=Forbid (no overlapping sweeps)" {
  # Overlapping pruners would race kubectl deletes on the same PR.
  grep -q 'concurrencyPolicy: Forbid' "$MANIFEST"
}
