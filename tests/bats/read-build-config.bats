#!/usr/bin/env bats
# =============================================================================
# Tests for scripts/read-build-config.sh — per-app outpost.build.yaml parser.
#
# Quietly broken merge logic = wrong kaniko args = broken builds for every
# app that opts into outpost.build.yaml. Fixture-lock the output shapes.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${INFRA_ROOT}/scripts/read-build-config.sh"

  # Skip the whole file when yq isn't installed locally — keeps CI matrix
  # tolerant on environments that haven't `apk add yq` yet. CI's
  # `tests/lint.sh` already installs yq via brew/apt for the smoke job.
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq (mikefarah, v4+) not installed"
  fi

  SRC=$(mktemp -d)
  OUT=$(mktemp -d)
}

teardown() {
  [ -n "${SRC:-}" ] && rm -rf "$SRC" || true
  [ -n "${OUT:-}" ] && rm -rf "$OUT" || true
}

# ---- 1. Bad-input contract ---------------------------------------------------

@test "fails with usage when args missing" {
  run sh "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ usage ]]
}

@test "creates out_dir if missing" {
  local fresh="$OUT/nested/new"
  run sh "$SCRIPT" "$SRC" '[]' "$fresh"
  [ "$status" -eq 0 ]
  [ -f "$fresh/dockerfile" ]
  [ -f "$fresh/context" ]
  [ -f "$fresh/extra-args" ]
}

# ---- 2. Defaults preserved when file absent (v0.2 back-compat) --------------

@test "no outpost.build.yaml → dockerfile=./Dockerfile" {
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/dockerfile")" = "./Dockerfile" ]
}

@test "no outpost.build.yaml → context=./" {
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/context")" = "./" ]
}

@test "no outpost.build.yaml → extra-args passes defaults through unchanged" {
  local defaults='["--cache=true","--cache-repo=docker-registry.registry.svc.cluster.local:5000/cache"]'
  run sh "$SCRIPT" "$SRC" "$defaults" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/extra-args")" = "$defaults" ]
}

@test "no outpost.build.yaml + empty defaults → extra-args=[]" {
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/extra-args")" = "[]" ]
}

# ---- 3. Per-app overrides ----------------------------------------------------

@test "outpost.build.yaml dockerfile/context override defaults" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
dockerfile: ./services/api/Dockerfile
context: ./services/api
EOF
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/dockerfile")" = "./services/api/Dockerfile" ]
  [ "$(cat "$OUT/context")" = "./services/api" ]
}

@test "partial config (only buildArgs) keeps default dockerfile + context" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
buildArgs:
  - GO_VERSION=1.22
EOF
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/dockerfile")" = "./Dockerfile" ]
  [ "$(cat "$OUT/context")" = "./" ]
  [ "$(cat "$OUT/extra-args")" = '["--build-arg=GO_VERSION=1.22"]' ]
}

# ---- 4. Merge semantics (the load-bearing part) -----------------------------

@test "merge order: defaults + --build-arg= + extraArgs" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
buildArgs:
  - VERSION=1.2.3
  - DEBUG=false
extraArgs:
  - --single-snapshot
  - --ignore-path=/tmp
EOF
  local defaults='["--cache=true","--cache-repo=foo/cache"]'
  run sh "$SCRIPT" "$SRC" "$defaults" "$OUT"
  [ "$status" -eq 0 ]
  local expected='["--cache=true","--cache-repo=foo/cache","--build-arg=VERSION=1.2.3","--build-arg=DEBUG=false","--single-snapshot","--ignore-path=/tmp"]'
  [ "$(cat "$OUT/extra-args")" = "$expected" ]
}

@test "buildArgs entries each get --build-arg= prefix" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
buildArgs:
  - KEY1=val1
  - KEY2=val2
EOF
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/extra-args")" = '["--build-arg=KEY1=val1","--build-arg=KEY2=val2"]' ]
}

@test "extraArgs entries pass through verbatim (no prefix)" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
extraArgs:
  - --whitelist-var-run=false
  - --snapshot-mode=redo
EOF
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/extra-args")" = '["--whitelist-var-run=false","--snapshot-mode=redo"]' ]
}

@test "empty buildArgs + empty extraArgs lists → defaults unchanged" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
buildArgs: []
extraArgs: []
EOF
  local defaults='["--cache=true"]'
  run sh "$SCRIPT" "$SRC" "$defaults" "$OUT"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/extra-args")" = "$defaults" ]
}

# ---- 5. Output is single-line (Tekton results contract) ---------------------

@test "result files have no trailing newline (Tekton result contract)" {
  run sh "$SCRIPT" "$SRC" '[]' "$OUT"
  [ "$status" -eq 0 ]
  # wc -l counts newlines. Zero = single line, no trailing newline.
  [ "$(wc -l < "$OUT/dockerfile" | tr -d ' ')" -eq 0 ]
  [ "$(wc -l < "$OUT/context" | tr -d ' ')" -eq 0 ]
  [ "$(wc -l < "$OUT/extra-args" | tr -d ' ')" -eq 0 ]
}

@test "merged extra-args is valid JSON parseable by yq" {
  cat > "$SRC/outpost.build.yaml" <<'EOF'
buildArgs:
  - X=1
extraArgs:
  - --flag
EOF
  run sh "$SCRIPT" "$SRC" '["--default"]' "$OUT"
  [ "$status" -eq 0 ]
  # If extra-args isn't valid JSON, yq will exit non-zero.
  run yq -p=json '.' "$OUT/extra-args"
  [ "$status" -eq 0 ]
  # And length is 3.
  run yq -p=json -o=tsv 'length' "$OUT/extra-args"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}
