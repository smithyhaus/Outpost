#!/usr/bin/env bats
# =============================================================================
# outpost.app.yaml schema integrity.
#
#  - Schema file is valid JSON Schema 2020-12.
#  - Both shipped examples (minimal + multi-product) validate against it.
#  - Negative cases: missing required fields, conflicting routes+caddy_fragment.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCHEMA="${INFRA_ROOT}/tests/schema/outpost-app.schema.json"
  [ -r "$SCHEMA" ] || skip "schema not found"
  # ajv-cli is the standard validator in the project; fall back to skip
  # rather than fail if it's missing — gives a soft-pass on dev machines
  # where node tooling isn't installed.
  if ! command -v ajv >/dev/null 2>&1; then
    skip "ajv-cli not installed (install: npm i -g ajv-cli ajv-formats)"
  fi
  # yq required to convert the YAML examples to JSON for ajv.
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq not installed"
  fi
}

@test "schema file is itself valid JSON" {
  run jq empty "$SCHEMA"
  [ "$status" -eq 0 ]
}

@test "minimal example validates against schema" {
  local ex="${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example"
  [ -r "$ex" ]
  local tmp; tmp="$(mktemp)"
  yq -o=json '.' "$ex" > "$tmp"
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "multi-product example validates against schema" {
  local ex="${INFRA_ROOT}/examples/outpost.app.yaml.multiproduct.example"
  [ -r "$ex" ]
  local tmp; tmp="$(mktemp)"
  yq -o=json '.' "$ex" > "$tmp"
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "rejects: missing metadata.name" {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{ "apiVersion": "outpost.dev/v1", "kind": "App", "metadata": {}, "spec": { "tier": "compose" } }
EOF
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

@test "rejects: tier not in enum" {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{ "apiVersion": "outpost.dev/v1", "kind": "App", "metadata": { "name": "x" }, "spec": { "tier": "vm" } }
EOF
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

@test "rejects: both routes and caddy_fragment set" {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{
  "apiVersion": "outpost.dev/v1", "kind": "App",
  "metadata": { "name": "x" },
  "spec": {
    "tier": "compose",
    "compose": { "image": "nginx" },
    "routes": [ { "host": "x.{$ROOT_DOMAIN}", "default_upstream": "x:80" } ],
    "caddy_fragment": "@x host x.{$ROOT_DOMAIN}\nhandle @x { reverse_proxy x:80 }"
  }
}
EOF
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

@test "rejects: metadata.name with invalid DNS chars" {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
{ "apiVersion": "outpost.dev/v1", "kind": "App",
  "metadata": { "name": "Foo_Bar" },
  "spec": { "tier": "compose", "compose": { "image": "nginx" } } }
EOF
  run ajv validate -s "$SCHEMA" -d "$tmp" --spec=draft2020
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}
