#!/usr/bin/env bats
# =============================================================================
# Registry GC — tag prune + blob garbage-collect.
#
# Guards the fix for the silent disk leak that motivated this CronJob:
# every CI push to docker-registry adds a tag, and nothing ever deletes
# old ones. A single-node k3d host fills the 50Gi PVC after ~10–20 builds
# per app, triggering DiskPressure → Evicted build pods.
#
# What we test:
#   (a) Manifest renders with all OUTPOST_REGISTRY_GC_* env vars set;
#       strict-render rejects missing ones.
#   (b) RBAC is namespace-scoped to `registry` (no ClusterRole). Verbs are
#       pinned to read pods + create exec — no write power on the registry
#       deployment itself.
#   (c) The inner GC script (runs inside docker-registry pod) handles the
#       three branches we care about: under-cap repos, over-cap repos
#       (DELETE oldest tail), 405 (DELETE_ENABLED missing) fatal.
#   (d) Phase 7 only wires the GC for REGISTRY_PLUGIN=self-hosted (aliyun-
#       acr has server-side retention).
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  MANIFEST="${INFRA_ROOT}/plugins/registry/self-hosted/gc.yaml"
  SCRIPT="${INFRA_ROOT}/scripts/registry-gc.sh"
  PHASE2="${INFRA_ROOT}/bootstrap.d/02-config.sh"
  PHASE7="${INFRA_ROOT}/bootstrap.d/07-registry-plugin.sh"
  command -v envsubst >/dev/null 2>&1 || skip "envsubst not available"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:-/tmp/__nonexistent}"
}

# ---- (a) manifest render ----------------------------------------------------

@test "registry-gc manifest exists and is non-empty" {
  [ -r "$MANIFEST" ]
  [ -s "$MANIFEST" ]
}

@test "registry-gc manifest renders with all required env" {
  export OUTPOST_REGISTRY_GC_SCHEDULE="0 */6 * * *"
  export OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO=5
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  out="$TMP/gc.yaml"
  run render_template "$MANIFEST" "$out"
  [ "$status" -eq 0 ]
  grep -q 'schedule: "0 \*/6 \* \* \*"' "$out"
  grep -q 'value: "5"' "$out"
  grep -q 'image: alpine/k8s:1.31.0' "$out"
  unset OUTPOST_REGISTRY_GC_SCHEDULE OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO OUTPOST_TEKTON_PRUNER_IMAGE
}

@test "registry-gc manifest strict-render rejects missing KEEP_TAGS_PER_REPO" {
  export OUTPOST_REGISTRY_GC_SCHEDULE="0 */6 * * *"
  unset OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO
  export OUTPOST_TEKTON_PRUNER_IMAGE="alpine/k8s:1.31.0"
  run render_template "$MANIFEST" "$TMP/should-not-exist.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO" ]]
  unset OUTPOST_REGISTRY_GC_SCHEDULE OUTPOST_TEKTON_PRUNER_IMAGE
}

# ---- (b) RBAC is namespace-scoped + minimal --------------------------------

@test "registry-gc RBAC uses Role + RoleBinding (no ClusterRole)" {
  run grep -E '^kind: ClusterRole' "$MANIFEST"
  [ "$status" -ne 0 ]
  grep -qE '^kind: Role$'        "$MANIFEST"
  grep -qE '^kind: RoleBinding$' "$MANIFEST"
}

@test "registry-gc Role grants only pods read + pods/exec + cm read" {
  # The role MUST NOT grant write power on the registry deployment, secrets,
  # or anything outside namespace `registry`. Compromise of the GC pod
  # therefore loses ONLY the ability to exec into the registry pod (which
  # already runs as root inside, but that's a separate concern).
  run awk '/^kind: Role$/,/^---$/' "$MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" =~ pods ]]
  [[ "$output" =~ "pods/exec" ]]
  [[ "$output" =~ configmaps ]]
  [[ ! "$output" =~ deployments ]] || fail "Role grants deployments — out of scope"
  [[ ! "$output" =~ secrets ]]     || fail "Role grants secrets — security smell"
}

@test "registry-gc pod is hardened (non-root, read-only rootfs, dropped caps)" {
  grep -q 'runAsNonRoot: true'              "$MANIFEST"
  grep -q 'readOnlyRootFilesystem: true'    "$MANIFEST"
  grep -q 'allowPrivilegeEscalation: false' "$MANIFEST"
  grep -qE 'drop:\s*\["ALL"\]'              "$MANIFEST"
}

@test "registry-gc manifest has NO inline shell (envsubst-immune)" {
  # The bug that broke the first CronJob run: $POD inline in the YAML
  # command field was substituted by envsubst at render time (envsubst
  # does NOT honor $$VAR as a literal $VAR escape — that's a docker-
  # compose convention, not envsubst's). The fix is structural: take all
  # shell logic OUT of the YAML and put it in a script file mounted via
  # ConfigMap-from-file. Then envsubst only sees the simple ${OUTPOST_*}
  # variables it's supposed to substitute, and runtime shell vars
  # ($POD, $(date)) never enter its sight.
  cmd_field=$(awk '/^[[:space:]]*command:/,/^[[:space:]]*env:/' "$MANIFEST")
  ! [[ "$cmd_field" =~ "POD=" ]] \
    || fail "manifest still has inline shell with POD= — extract to scripts/registry-gc-outer.sh"
  ! [[ "$cmd_field" =~ '$$' ]] \
    || fail "manifest has $$ escape — envsubst does NOT honor this, use external script"
  # Positive: command must reference the outer driver script.
  grep -q 'registry-gc-outer.sh' "$MANIFEST" \
    || fail "manifest must invoke /script/registry-gc-outer.sh"
}

@test "registry-gc-outer.sh exists, executable, POSIX sh" {
  OUTER="${INFRA_ROOT}/scripts/registry-gc-outer.sh"
  [ -x "$OUTER" ] || fail "scripts/registry-gc-outer.sh missing or not executable"
  head -1 "$OUTER" | grep -qE '^#!/bin/sh$' \
    || fail "outer script must use #!/bin/sh shebang"
  grep -q 'kubectl -n .* exec -i' "$OUTER" \
    || fail "outer script must exec into the registry pod"
  grep -q 'registry-gc.sh' "$OUTER" \
    || fail "outer script must invoke the inner registry-gc.sh"
}

@test "phase 7 ConfigMap mounts BOTH outer and inner scripts" {
  grep -qE 'registry-gc-outer.sh=scripts/registry-gc-outer.sh' "$PHASE7" \
    || fail "phase 7 must mount the outer driver into the CM"
  grep -qE 'registry-gc.sh=scripts/registry-gc.sh' "$PHASE7" \
    || fail "phase 7 must mount the inner GC body into the CM"
}

@test "registry-gc requests ephemeral-storage (eviction-immune under DiskPressure)" {
  # The first attempt at running the GC hit exactly this: the GC pod (which
  # exists to relieve DiskPressure) was itself evicted by kubelet because
  # it didn't declare an ephemeral-storage request. Without this guard,
  # the cleanup loop deadlocks — the very pressure the GC is supposed to
  # fix prevents it from running.
  grep -qE 'requests:.*ephemeral-storage' "$MANIFEST" \
    || fail "registry-gc missing ephemeral-storage request — will be evicted first under DiskPressure"
}

@test "registry-gc tolerates node.kubernetes.io/disk-pressure taint (schedulable during incident)" {
  # Second chicken-and-egg layer: when kubelet enters DiskPressure, it
  # adds a NoSchedule taint to the node. New pods (including this GC
  # pod that exists to RELIEVE the pressure) refuse to schedule until
  # an operator manually intervenes. With the toleration, the GC pod
  # schedules anyway and breaks the deadlock.
  awk '/^kind: CronJob$/,EOF' "$MANIFEST" | grep -q 'node.kubernetes.io/disk-pressure' \
    || fail "registry-gc missing disk-pressure toleration — blocked by NoSchedule taint during exactly the incident it should fix"
}

# ---- (c) Inner script logic ------------------------------------------------

@test "registry-gc.sh exists, executable, POSIX sh shebang" {
  [ -x "$SCRIPT" ]
  head -1 "$SCRIPT" | grep -qE '^#!/bin/sh$'
}

@test "registry-gc.sh respects OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO with default 5" {
  grep -qE 'KEEP_N="\$\{OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO:-5\}"' "$SCRIPT"
}

@test "registry-gc.sh aborts FATAL on 405 (DELETE not enabled)" {
  # The biggest foot-gun: if the registry config doesn't have
  # REGISTRY_STORAGE_DELETE_ENABLED=true, the HTTP DELETE returns 405.
  # The script must surface this clearly, not silently no-op.
  grep -qE '405\)[[:space:]]*echo.*FATAL' "$SCRIPT" \
    || fail "script must FATAL on 405 with helpful hint"
  grep -q 'REGISTRY_STORAGE_DELETE_ENABLED' "$SCRIPT"
}

@test "registry-gc.sh uses nc raw HTTP (registry:2 lacks curl AND --method-capable wget)" {
  # registry:2 (alpine) ships only busybox. busybox wget does NOT support
  # --method=DELETE; curl is not installed. nc + raw HTTP is the only
  # available primitive. Reverting to curl/wget will silently fail every
  # DELETE call (the script's first cluster run hit exactly that).
  grep -qE 'nc -w [0-9]+ localhost 5000' "$SCRIPT" \
    || fail "script must use nc raw HTTP — curl/wget --method not available in registry:2"
  grep -qE 'DELETE /v2/' "$SCRIPT" \
    || fail "raw HTTP DELETE request line missing"
  # Negative checks — pattern at LINE START (so comments documenting why
  # we don't use curl/wget don't false-positive).
  ! grep -qE '^[[:space:]]*curl[[:space:]].*-X[[:space:]]+DELETE' "$SCRIPT" \
    || fail "script reverted to curl — registry:2 alpine image does not ship curl"
  ! grep -qE '^[[:space:]]*wget[[:space:]].*--method' "$SCRIPT" \
    || fail "script using wget --method — not supported by busybox wget in registry:2"
}

@test "registry-gc.sh runs blob garbage-collect with --delete-untagged" {
  # Without --delete-untagged, manifests that lost all tags in step 1
  # would orphan their blobs but never get reclaimed. Test the flag survives.
  grep -qE 'registry garbage-collect.*--delete-untagged' "$SCRIPT"
}

@test "registry-gc.sh sorts tags by FS mtime (ls -t)" {
  # The retention is BY MTIME, not lex order. Tags are SHA strings —
  # lex sort would be random. Lock in the mtime-based selection.
  grep -qE 'ls -t.*tags_dir' "$SCRIPT"
}

@test "registry-gc.sh reports disk usage before/after the run" {
  # Operator-visible signal that GC actually reclaimed space.
  grep -qE 'du -sh /var/lib/registry' "$SCRIPT"
  grep -qE 'disk: \$\{before\} → \$\{after\}' "$SCRIPT"
}

# ---- (d) Phase 7 wiring ----------------------------------------------------

@test "phase 7 only deploys registry-gc when REGISTRY_PLUGIN=self-hosted" {
  # aliyun-acr has its own retention story — the GC CronJob would be a no-op
  # at best and waste a CronJob slot at worst.
  grep -qE 'REGISTRY_PLUGIN.*==.*self-hosted' "$PHASE7"
  grep -q 'plugins/registry/self-hosted/gc.yaml' "$PHASE7"
}

@test "phase 7 refreshes the script ConfigMap from scripts/registry-gc.sh" {
  grep -qE 'kubectl create configmap registry-gc-script' "$PHASE7"
  grep -qE 'registry-gc.sh=scripts/registry-gc.sh' "$PHASE7"
}

@test "phase 2 sets OUTPOST_REGISTRY_GC_SCHEDULE + KEEP_TAGS_PER_REPO defaults" {
  grep -qE 'OUTPOST_REGISTRY_GC_SCHEDULE="\$\{OUTPOST_REGISTRY_GC_SCHEDULE:-0 \*/6 \* \* \*\}"' "$PHASE2"
  grep -qE 'OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO="\$\{OUTPOST_REGISTRY_KEEP_TAGS_PER_REPO:-5\}"' "$PHASE2"
}

@test "phase 2 persists OUTPOST_REGISTRY_GC_SCHEDULE via env_kv (cron spaces)" {
  grep -qE 'env_kv OUTPOST_REGISTRY_GC_SCHEDULE' "$PHASE2"
}
