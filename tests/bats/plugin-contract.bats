#!/usr/bin/env bats
# Verify every plugin satisfies the contract

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "every plugin has plugin.yaml + preflight.sh + README.md" {
  while IFS= read -r dir; do
    [ -f "$dir/plugin.yaml" ] || fail "missing plugin.yaml in $dir"
    [ -f "$dir/preflight.sh" ] || fail "missing preflight.sh in $dir"
    [ -x "$dir/preflight.sh" ] || fail "preflight.sh not executable in $dir"
    [ -f "$dir/README.md" ] || fail "missing README.md in $dir"
    # at least one of manifest.yaml / compose.yaml
    [ -f "$dir/manifest.yaml" ] || [ -f "$dir/compose.yaml" ] || \
      fail "missing manifest.yaml or compose.yaml in $dir"
  done < <(find "${INFRA_ROOT}/plugins" -mindepth 2 -maxdepth 2 -type d)
}

@test "plugin.yaml carries kind + name fields" {
  while IFS= read -r f; do
    grep -q "^kind:" "$f"  || fail "missing 'kind:' in $f"
    grep -q "^name:" "$f"  || fail "missing 'name:' in $f"
  done < <(find "${INFRA_ROOT}/plugins" -name plugin.yaml)
}

@test "self-hosted preflight passes with no env" {
  env -i bash "${INFRA_ROOT}/plugins/registry/self-hosted/preflight.sh"
}

@test "aliyun-acr preflight fails when env missing" {
  run env -i bash "${INFRA_ROOT}/plugins/registry/aliyun-acr/preflight.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "ALIYUN_ACR" ]]
}

@test "git-provider preflight fails when env missing" {
  for p in gitee github gitlab; do
    run env -i bash "${INFRA_ROOT}/plugins/git-provider/$p/preflight.sh"
    [ "$status" -ne 0 ] || fail "$p preflight should have failed without env"
  done
}

@test "manifests use \${VAR} envsubst form (no __VAR__ leftovers)" {
  ! grep -rEn '__[A-Z_]+__' "${INFRA_ROOT}/plugins" "${INFRA_ROOT}/core" \
                            "${INFRA_ROOT}/examples" 2>/dev/null
}
