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
  [[ "$KANIKO_EXTRA_ARGS" == *"\"--skip-tls-verify\""* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"\"--insecure\""* ]]
}

@test "self-hosted: KANIKO_EXTRA_ARGS includes cache flags" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  [[ "$KANIKO_EXTRA_ARGS" == *"\"--cache=true\""* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *"docker-registry.registry.svc.cluster.local:5000/cache"* ]]
}

@test "self-hosted: KANIKO_EXTRA_ARGS is valid JSON-shape" {
  export REGISTRY_PLUGIN="self-hosted"
  resolve_registry_config
  # Must start with [ and end with ] — flow-style JSON array, envsubst-safe.
  [[ "$KANIKO_EXTRA_ARGS" == \[* ]]
  [[ "$KANIKO_EXTRA_ARGS" == *\] ]]
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
