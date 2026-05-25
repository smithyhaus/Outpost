#!/usr/bin/env bats
# =============================================================================
# End-to-end tests for the v0.4 onboard primitives via the outpost CLI:
#   outpost db create / seal-from-template / manifest scaffold
# Arg validation + `manifest scaffold` file output run hermetically (writes
# only under $TMP). docker / kubeseal-dependent paths `skip` when absent.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLI="${INFRA_ROOT}/scripts/outpost"
  [ -x "$CLI" ] || skip "scripts/outpost not executable"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# ---- arg validation (no external deps) --------------------------------------
@test "db: no subcommand exits non-zero" {
  run bash "$CLI" db
  [ "$status" -ne 0 ]
}

@test "db create: no app name exits non-zero" {
  run bash "$CLI" db create
  [ "$status" -ne 0 ]
}

@test "seal-from-template: no app exits non-zero" {
  run bash "$CLI" seal-from-template
  [ "$status" -ne 0 ]
}

@test "seal-from-template: missing --template exits non-zero" {
  run bash "$CLI" seal-from-template myapp --output "$TMP/out.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template"* ]]
}

@test "manifest: no subcommand exits non-zero" {
  run bash "$CLI" manifest
  [ "$status" -ne 0 ]
}

@test "manifest scaffold: unknown --lang is rejected with the supported list" {
  mkdir -p "$TMP/m"
  run bash "$CLI" manifest scaffold myapp --lang klingon --manifests-dir "$TMP/m"
  [ "$status" -ne 0 ]
  [[ "$output" == *"klingon"* ]]
  [[ "$output" == *"go"* ]]
}

@test "manifest scaffold: a non-existent --manifests-dir is rejected" {
  run bash "$CLI" manifest scaffold myapp --lang go --manifests-dir "$TMP/does-not-exist"
  [ "$status" -ne 0 ]
}

# ---- manifest scaffold: file output + idempotency (hermetic) ----------------
@test "manifest scaffold: fresh run writes the 5 manifest files" {
  mkdir -p "$TMP/m"
  run bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m"
  [ "$status" -eq 0 ]
  [ -f "$TMP/m/apps/demo/deployment.yaml" ]
  [ -f "$TMP/m/apps/demo/service.yaml" ]
  [ -f "$TMP/m/apps/demo/ingress.yaml" ]
  [ -f "$TMP/m/apps/demo/kustomization.yaml" ]
  [ -f "$TMP/m/argocd-apps/demo.yaml" ]
}

@test "manifest scaffold: substitutes the app name into the manifests" {
  mkdir -p "$TMP/m"
  bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m"
  grep -q 'app: demo' "$TMP/m/apps/demo/deployment.yaml"
  # the hello-go placeholder must be fully gone
  ! grep -rq 'hello-go' "$TMP/m/apps/demo/"
}

@test "manifest scaffold: rerun on identical state reports unchanged" {
  mkdir -p "$TMP/m"
  bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m"
  run bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"unchanged"'* ]]
  [[ "$output" == *'"written_files":[]'* ]]
}

@test "manifest scaffold: a hand-edited file is reported as drift, not clobbered" {
  mkdir -p "$TMP/m"
  bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m"
  echo "# hand edit" >> "$TMP/m/apps/demo/service.yaml"
  run bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m" --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'"status":"drift"'* ]]
  # the hand edit survives
  grep -q '# hand edit' "$TMP/m/apps/demo/service.yaml"
}

@test "manifest scaffold: --force overwrites drifted files" {
  mkdir -p "$TMP/m"
  bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m"
  echo "# hand edit" >> "$TMP/m/apps/demo/service.yaml"
  run bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m" --force
  [ "$status" -eq 0 ]
  ! grep -q '# hand edit' "$TMP/m/apps/demo/service.yaml"
}

@test "manifest scaffold --json: output conforms to the onboard schema shape" {
  command -v jq >/dev/null || skip "jq not available"
  mkdir -p "$TMP/m"
  run bash "$CLI" manifest scaffold demo --lang go --manifests-dir "$TMP/m" --json
  echo "$output" | jq -e . >/dev/null
  echo "$output" | jq -e '.step == "manifest.scaffold"' >/dev/null
  echo "$output" | jq -e 'has("status") and has("detail") and has("written_files") and has("next_action")' >/dev/null
  echo "$output" | jq -e '.status as $s | (["created","exists","sealed","scaffolded","unchanged","drift","error"] | index($s)) != null' >/dev/null
}

# ---- seal-from-template: residue path (needs kubeseal installed) ------------
@test "seal-from-template: an unresolved \${VAR} in the template fails cleanly" {
  command -v kubeseal >/dev/null || skip "kubeseal not available"
  command -v envsubst >/dev/null || skip "envsubst not available"
  printf 'stringData:\n  X: "${OUTPOST_BATS_UNSET_VAR}"\n' > "$TMP/tpl.yaml"
  run bash "$CLI" seal-from-template demo --template "$TMP/tpl.yaml" --output "$TMP/sealed.yaml" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"status":"error"'* ]]
  [ ! -f "$TMP/sealed.yaml" ]
}

# ---- db create: idempotency (needs a running postgres container) ------------
@test "db create: creates a database, then reports exists on rerun" {
  command -v docker >/dev/null || skip "docker not available"
  docker exec postgres true >/dev/null 2>&1 || skip "postgres container not running"
  local app="outpost_bats_$$"
  run bash "$CLI" db create "$app" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"created"'* ]]
  run bash "$CLI" db create "$app" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"exists"'* ]]
  docker exec postgres psql -U "${POSTGRES_USER:-postgres}" -d postgres \
    -c "DROP DATABASE IF EXISTS \"$app\"" >/dev/null 2>&1 || true
}
