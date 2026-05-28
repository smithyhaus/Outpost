#!/usr/bin/env bats
# =============================================================================
# Tests for platform/lib/registry-config.sh — the REGISTRY_PLUGIN case branch
# that drives REGISTRY_HOST / REGISTRY_PUSH_HOST / KANIKO_EXTRA_ARGS.
#
# This is the central plugin-config switch. Every committed Pipeline default
# flows from this function. Review #1 (aliyun-acr end-to-end broken) was
# fundamentally a regression here that had no test protecting it.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  # shellcheck source=../../platform/lib/registry-config.sh
  source "${INFRA_ROOT}/platform/lib/registry-config.sh"

  # Reset state — each test starts clean.
  unset REGISTRY_PLUGIN REGISTRY_HOST REGISTRY_PUSH_HOST KANIKO_EXTRA_ARGS
  unset ALIYUN_ACR_REGISTRY ALIYUN_ACR_NAMESPACE
  export ROOT_DOMAIN="example.test"
}

@test "self-hosted: REGISTRY_HOST is registry.<root>" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [ "$REGISTRY_HOST" = "registry.example.test" ]
}

@test "self-hosted: REGISTRY_PUSH_HOST is in-cluster Service ClusterIP form" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [ "$REGISTRY_PUSH_HOST" = "docker-registry.registry.svc.cluster.local:5000" ]
}

@test "self-hosted: KANIKO_EXTRA_ARGS includes --skip-tls-verify + --insecure" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"--skip-tls-verify"* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"--insecure"* ]]
}

@test "self-hosted: KANIKO_EXTRA_ARGS includes cache flags" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"--cache=true"* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"docker-registry.registry.svc.cluster.local:5000/cache"* ]]
}

@test "self-hosted: KANIKO_EXTRA_ARGS includes ephemeral-compression flags" {
  # --single-snapshot is the highest-impact lever for ephemeral on
  # single-node k3d (cuts per-build transient by ~half for multi-RUN
  # Dockerfiles). Lock it in — removing it would re-introduce the
  # DiskPressure-evicted-mid-build failure mode that motivated this layer.
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"--single-snapshot"* ]] \
    || fail "missing --single-snapshot — kaniko will burn ephemeral per command"
  [[ "$KANIKO_EXTRA_ARGS" == *"--snapshot-mode=redo"* ]] \
    || fail "missing --snapshot-mode=redo — slower + more RAM than necessary"
  [[ "$KANIKO_EXTRA_ARGS" == *"--use-new-run"* ]] \
    || fail "missing --use-new-run — older execution mode, more memory"
}

@test "aliyun-acr: KANIKO_EXTRA_ARGS includes ephemeral-compression flags" {
  # Same compression applies regardless of registry backend — the limiting
  # factor is the k3d node's ephemeral budget, not the registry.
  export REGISTRY_PLUGIN="aliyun-acr"
  export ALIYUN_ACR_REGISTRY="registry.cn-test.aliyuncs.com"
  export ALIYUN_ACR_NAMESPACE="t"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"--single-snapshot"* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"--snapshot-mode=redo"* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"--use-new-run"* ]]
}

@test "self-hosted: KANIKO_EXTRA_ARGS is space-separated (NOT JSON array)" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  # Tekton v0.50+ coerces flow-array-shaped strings, stripping inner quotes.
  # Space-separated tokens avoid that coercion entirely. Any future change
  # to JSON-array form would re-introduce the silent-corruption class of
  # bugs — see registry-config.sh header for the full root cause.
  ! [[ "$KANIKO_EXTRA_ARGS" == \[* ]] \
    || fail "KANIKO_EXTRA_ARGS is [...]-shaped — Tekton WILL coerce it"
  ! [[ "$KANIKO_EXTRA_ARGS" == *\] ]] \
    || fail "KANIKO_EXTRA_ARGS ends with ] — Tekton WILL coerce it"
  ! [[ "$KANIKO_EXTRA_ARGS" =~ \" ]] \
    || fail "KANIKO_EXTRA_ARGS contains \" — must be plain tokens"
  # Sanity: tokens separated by single spaces.
  [[ "$KANIKO_EXTRA_ARGS" =~ " " ]] \
    || fail "KANIKO_EXTRA_ARGS has no spaces — not multi-arg"
  # Must NOT have stray ${VAR} from incomplete envsubst.
  ! [[ "$KANIKO_EXTRA_ARGS" =~ \$\{ ]]
}

@test "aliyun-acr: REGISTRY_HOST combines ACR_REGISTRY + ACR_NAMESPACE" {
  export REGISTRY_PLUGIN="aliyun-acr"
  export ALIYUN_ACR_REGISTRY="registry.cn-test.aliyuncs.com"
  export ALIYUN_ACR_NAMESPACE="my-team"
  resolve_registry_config
  [ "$REGISTRY_HOST" = "registry.cn-test.aliyuncs.com/my-team" ]
}

@test "aliyun-acr: REGISTRY_PUSH_HOST matches REGISTRY_HOST (public endpoint for push)" {
  export REGISTRY_PLUGIN="aliyun-acr"
  export ALIYUN_ACR_REGISTRY="registry.cn-test.aliyuncs.com"
  export ALIYUN_ACR_NAMESPACE="my-team"
  resolve_registry_config
  [ "$REGISTRY_PUSH_HOST" = "$REGISTRY_HOST" ]
}

@test "aliyun-acr: KANIKO_EXTRA_ARGS does NOT include --insecure (ACR is HTTPS-only)" {
  export REGISTRY_PLUGIN="aliyun-acr"
  export ALIYUN_ACR_REGISTRY="registry.cn-test.aliyuncs.com"
  export ALIYUN_ACR_NAMESPACE="my-team"
  resolve_registry_config
  ! [[ "$KANIKO_EXTRA_ARGS" == *"--insecure"* ]]
  ! [[ "$KANIKO_EXTRA_ARGS" == *"--skip-tls-verify"* ]]
}

@test "aliyun-acr: KANIKO_EXTRA_ARGS includes cache repo under namespace" {
  export REGISTRY_PLUGIN="aliyun-acr"
  export ALIYUN_ACR_REGISTRY="registry.cn-test.aliyuncs.com"
  export ALIYUN_ACR_NAMESPACE="my-team"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"registry.cn-test.aliyuncs.com/my-team/cache"* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"--cache=true"* ]]
}

@test "unknown REGISTRY_PLUGIN: function returns non-zero with helpful err" {
  export REGISTRY_PLUGIN="quay-io"
  run resolve_registry_config
  [ "$status" -ne 0 ]
  [[ "$output" =~ "quay-io" ]] || [[ "$output" =~ "kaniko config block" ]]
}

@test "missing REGISTRY_PLUGIN: function returns non-zero" {
  unset REGISTRY_PLUGIN
  run resolve_registry_config
  [ "$status" -ne 0 ]
}

@test "exports propagate to subshell (envsubst pipeline-build.yaml reads them)" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  # Verify they are export-marked, not local.
  bash -c 'echo "$REGISTRY_HOST $REGISTRY_PUSH_HOST"' | grep -q "registry.example.test docker-registry"
}
