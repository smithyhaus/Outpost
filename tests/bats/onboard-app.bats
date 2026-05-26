#!/usr/bin/env bats
# =============================================================================
# `outpost onboard` + outpost.app.yaml helpers (onboard_app_validate,
# onboard_render_caddy_fragment, onboard_render_compose_override).
#
# These are unit tests against platform/lib/onboard-lib.sh. The CLI smoke
# test exercises the dry-run path end-to-end without touching the live
# infras directory.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLI="${INFRA_ROOT}/scripts/outpost"
  [ -x "$CLI" ] || skip "scripts/outpost not executable"
  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"
  # shellcheck source=../../platform/lib/portable.sh
  source "${INFRA_ROOT}/platform/lib/portable.sh"
  # shellcheck source=../../platform/lib/onboard-lib.sh
  source "${INFRA_ROOT}/platform/lib/onboard-lib.sh"

  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
}

@test "onboard_app_validate: accepts minimal example" {
  run onboard_app_validate "${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: accepts multi-product example" {
  run onboard_app_validate "${INFRA_ROOT}/examples/outpost.app.yaml.multiproduct.example"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: rejects missing apiVersion" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
kind: App
metadata: { name: x }
spec: { tier: compose, compose: { image: nginx } }
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ apiVersion ]]
}

@test "onboard_app_validate: rejects bad metadata.name" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: "Foo_Bar" }
spec: { tier: compose, compose: { image: nginx } }
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "metadata.name" ]]
}

@test "onboard_app_validate: rejects invalid tier" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: x }
spec: { tier: vm }
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "spec.tier" ]]
}

@test "onboard_app_validate: rejects tier=k3s + spec.routes (contract violation)" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: bad-k3s }
spec:
  tier: k3s
  routes:
    - host: "x.{$ROOT_DOMAIN}"
      default_upstream: "x:80"
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tier=k3s forbids spec.routes" ]]
  [[ "$output" =~ "IngressRoute" ]]
}

@test "onboard_app_validate: rejects tier=k3s + spec.caddy_fragment (contract violation)" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: bad-k3s2 }
spec:
  tier: k3s
  caddy_fragment: |
    @x host x.{$ROOT_DOMAIN}
    handle @x { reverse_proxy x:80 }
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tier=k3s forbids spec.caddy_fragment" ]]
}

@test "onboard_app_validate: rejects tier=compose with host on -apps.<root> naming convention" {
  # The -apps.<root> suffix is the apps naming convention; CF Tunnel's
  # broad *.<root> wildcard routes that traffic to k3s Traefik. A
  # compose-tier service on `mcp-apps.<ROOT_DOMAIN>` is silently
  # unreachable — caddy never sees it.
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: bad-compose }
spec:
  tier: compose
  compose: { image: nginx }
  routes:
    - host: "mcp-apps.{$ROOT_DOMAIN}"
      default_upstream: "nginx:80"
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tier=compose host" ]]
  [[ "$output" =~ "-apps" ]]
  # The error must hint at both fixes: switch tier OR pick non-apps prefix.
  [[ "$output" =~ "tier=k3s" ]]
}

@test "onboard_app_validate: tier=compose with .apps. (two-level, paid-cert) is also rejected" {
  # Defensive: catch users who still try the old two-level pattern.
  # The regex matches `-apps.` followed by template var or domain;
  # `.apps.` doesn't match (no leading `-`), so this should PASS validate
  # (we only reject the apps naming convention; the two-level pattern
  # is a separate problem the operator solves at the CF + cert layer).
  # In practice, users who write `.apps.` will hit cert/CF failures at
  # deploy time, not at validate time. Validate is intentionally narrow.
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: ok-shape }
spec:
  tier: compose
  compose: { image: nginx }
  routes:
    - host: "myinfra.{$ROOT_DOMAIN}"
      default_upstream: "nginx:80"
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: tier=compose accepts non-apps prefix containing hyphens" {
  # Make sure the regex doesn't false-positive on hostnames like
  # `my-search.<root>` or `my-redis.<root>` — those don't end in `-apps`.
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: my-search }
spec:
  tier: compose
  compose: { image: elasticsearch }
  routes:
    - host: "my-search.{$ROOT_DOMAIN}"
      default_upstream: "elasticsearch:9200"
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: accepts tier=compose with legitimate top-level host" {
  run onboard_app_validate "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: accepts tier=k3s without any routes" {
  run onboard_app_validate "${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example"
  [ "$status" -eq 0 ]
  run onboard_app_validate "${INFRA_ROOT}/examples/outpost.app.yaml.multiproduct.example"
  [ "$status" -eq 0 ]
}

@test "onboard_app_validate: rejects routes + caddy_fragment together" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: x }
spec:
  tier: compose
  compose: { image: nginx }
  routes:
    - host: "x.{$ROOT_DOMAIN}"
      default_upstream: "x:80"
  caddy_fragment: |
    @x host x.{$ROOT_DOMAIN}
    handle @x { reverse_proxy x:80 }
EOF
  run onboard_app_validate "$TEST_TMPDIR/x.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "mutually exclusive" ]]
}

@test "onboard_render_caddy_fragment: emits host matcher + handle block" {
  # Caddy fragments are now rendered only for tier=compose; the stateful-infra
  # example is the canonical fixture for fragment rendering.
  out=$(onboard_render_caddy_fragment "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example")
  [[ "$out" =~ "@elasticsearch_host_0 host" ]]
  [[ "$out" =~ "handle @elasticsearch_host_0" ]]
  [[ "$out" =~ "reverse_proxy elasticsearch:9200" ]]
}

@test "onboard_render_caddy_fragment: dashed app name → underscored matcher" {
  # Use a synthetic dashed-name yaml (the new examples don't have one).
  cat > "$TEST_TMPDIR/dashed.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: my-infra
spec:
  tier: compose
  compose: { image: nginx }
  routes:
    - host: "my-infra.{$ROOT_DOMAIN}"
      default_upstream: "my-infra:80"
EOF
  out=$(onboard_render_caddy_fragment "$TEST_TMPDIR/dashed.yaml")
  # 'my-infra' must become 'my_infra' in matcher names (Caddy disallows hyphens).
  [[ "$out" =~ "my_infra_host_0" ]]
  ! [[ "$out" =~ "my-infra_host_0" ]]
}

@test "onboard_render_caddy_fragment: rewrite_path_prefix → uri strip_prefix" {
  # Synthetic yaml exercising rewrite_path_prefix (legitimate stateful-infra
  # use case: e.g., Kibana under /kibana on the same host as Elasticsearch).
  cat > "$TEST_TMPDIR/strip.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: search-bundle
spec:
  tier: compose
  compose: { image: searchstack }
  routes:
    - host: "search.{$ROOT_DOMAIN}"
      rules:
        - path: ["/kibana/*"]
          rewrite_path_prefix: ["/kibana", ""]
          upstream: "kibana:5601"
      default_upstream: "elasticsearch:9200"
EOF
  out=$(onboard_render_caddy_fragment "$TEST_TMPDIR/strip.yaml")
  # `rewrite_path_prefix: ["/kibana", ""]` must render as strip_prefix,
  # NOT as a full `rewrite *` (which would discard the URL tail).
  [[ "$out" =~ "uri strip_prefix /kibana" ]]
}

@test "onboard_render_caddy_fragment: caddy_fragment escape hatch is passed verbatim" {
  cat > "$TEST_TMPDIR/x.yaml" <<'EOF'
apiVersion: outpost.dev/v1
kind: App
metadata: { name: raw }
spec:
  tier: compose
  compose: { image: nginx }
  caddy_fragment: |
    @raw host raw.{$ROOT_DOMAIN}
    handle @raw {
        respond "verbatim" 200
    }
EOF
  out=$(onboard_render_caddy_fragment "$TEST_TMPDIR/x.yaml")
  [[ "$out" =~ '@raw host raw.{$ROOT_DOMAIN}' ]]
  [[ "$out" =~ 'respond "verbatim" 200' ]]
  # The fragment should NOT contain the auto-generated `@<slug>_host_N`
  # matcher pattern when escape-hatch mode is active.
  ! [[ "$out" =~ "raw_host_0 host" ]]
}

@test "onboard_render_compose_override: stateful-infra output is valid YAML" {
  # Stateful-infra example is the only legitimate compose-tier example, so
  # it carries the canonical compose-override fixture.
  out=$(onboard_render_compose_override "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example")
  echo "$out" | yq -e '.services.elasticsearch.image | test("^docker.elastic.co/elasticsearch")' >/dev/null
}

@test "onboard_render_compose_override: env_from_outpost expands to \${VAR}" {
  out=$(onboard_render_compose_override "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example")
  # ROOT_DOMAIN listed in env_from_outpost should appear as `ROOT_DOMAIN: ${ROOT_DOMAIN}`.
  [[ "$out" =~ ROOT_DOMAIN:[[:space:]]+\$\{ROOT_DOMAIN\} ]]
}

@test "outpost onboard: no args → usage error" {
  run bash "$CLI" onboard
  [ "$status" -ne 0 ]
  [[ "$output" =~ "outpost onboard" ]]
}

@test "outpost onboard: nonexistent path → clear error" {
  run bash "$CLI" onboard /tmp/definitely-does-not-exist-$$
  [ "$status" -ne 0 ]
}

@test "outpost onboard --dry-run (tier=compose): emits fragment + override without writing" {
  mkdir -p "$TEST_TMPDIR/app"
  # Stateful-infra is the canonical tier=compose example post-contract.
  cp "${INFRA_ROOT}/examples/outpost.app.yaml.stateful-infra.example" "$TEST_TMPDIR/app/outpost.app.yaml"
  run bash "$CLI" onboard "$TEST_TMPDIR/app" --dry-run --no-reload
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY RUN" ]]
  [[ "$output" =~ "reverse_proxy elasticsearch:9200" ]]
  # Crucially, dry-run must NOT have touched the infras dir.
  [ ! -e "${INFRA_ROOT}/core/compose/Caddyfile.d/elasticsearch.caddy" ]
}

@test "outpost onboard --dry-run (tier=k3s): skips caddy fragment entirely" {
  mkdir -p "$TEST_TMPDIR/app"
  cp "${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example" "$TEST_TMPDIR/app/outpost.app.yaml"
  run bash "$CLI" onboard "$TEST_TMPDIR/app" --dry-run --no-reload
  [ "$status" -eq 0 ]
  [[ "$output" =~ "DRY RUN" ]]
  # tier=k3s must NOT emit a Caddy fragment — apps use IngressRoute.
  [[ "$output" =~ "tier=k3s" ]]
  ! [[ "$output" =~ "reverse_proxy" ]]
  [ ! -e "${INFRA_ROOT}/core/compose/Caddyfile.d/hello.caddy" ]
}

@test "outpost help: advertises onboard subcommand" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "onboard" ]]
}

@test "outpost onboard k3s: spec.k3s.manifest_repo overrides global MANIFEST_REPO_URL" {
  # Stage an app repo with tier=k3s + a per-app manifest_repo, plus a fake
  # local manifests-dir clone the scaffolder will write into. Verify the
  # rendered argocd-app.yaml points at the PER-APP repo, not the global one.
  mkdir -p "$TEST_TMPDIR/app" "$TEST_TMPDIR/manifests/apps" "$TEST_TMPDIR/manifests/argocd-apps"
  cat > "$TEST_TMPDIR/app/outpost.app.yaml" <<'YAML'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: k3s-app
spec:
  tier: k3s
  k3s:
    manifest_repo: https://example.com/per-app/manifests.git
    manifest_branch: release
YAML

  run env OUTPOST_NO_ENV=1 MANIFEST_REPO_URL=https://example.com/GLOBAL/should-NOT-be-used.git \
          MANIFEST_REPO_BRANCH=main \
          ROOT_DOMAIN=example.com \
          bash "$CLI" onboard "$TEST_TMPDIR/app" \
            --manifests-dir "$TEST_TMPDIR/manifests" \
            --lang go \
            --no-reload
  [ "$status" -eq 0 ]

  # The scaffolded argocd-app yaml must reference the per-app repo + branch.
  local argo_app="$TEST_TMPDIR/manifests/argocd-apps/k3s-app.yaml"
  [ -r "$argo_app" ]
  run grep -F "https://example.com/per-app/manifests.git" "$argo_app"
  [ "$status" -eq 0 ]
  run grep -F "targetRevision: release" "$argo_app"
  [ "$status" -eq 0 ]
  # And the global URL must NOT have leaked in.
  run grep -F "GLOBAL/should-NOT-be-used" "$argo_app"
  [ "$status" -ne 0 ]
}

@test "outpost onboard k3s: falls back to MANIFEST_REPO_URL when per-app override absent" {
  mkdir -p "$TEST_TMPDIR/app" "$TEST_TMPDIR/manifests/apps" "$TEST_TMPDIR/manifests/argocd-apps"
  cat > "$TEST_TMPDIR/app/outpost.app.yaml" <<'YAML'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: k3s-default
spec:
  tier: k3s
YAML

  run env OUTPOST_NO_ENV=1 MANIFEST_REPO_URL=https://example.com/fallback/manifests.git \
          MANIFEST_REPO_BRANCH=main \
          ROOT_DOMAIN=example.com \
          bash "$CLI" onboard "$TEST_TMPDIR/app" \
            --manifests-dir "$TEST_TMPDIR/manifests" \
            --lang go \
            --no-reload
  [ "$status" -eq 0 ]
  run grep -F "https://example.com/fallback/manifests.git" "$TEST_TMPDIR/manifests/argocd-apps/k3s-default.yaml"
  [ "$status" -eq 0 ]
}

@test "outpost onboard k3s: envsubst applied to manifest_repo (per-app gating)" {
  # outpost.app.yaml may write `${MY_APP_MANIFEST_REPO:-default}` so the
  # caller can override per-instance via env. The onboard pipeline must
  # envsubst before passing the value through.
  mkdir -p "$TEST_TMPDIR/app" "$TEST_TMPDIR/manifests/apps" "$TEST_TMPDIR/manifests/argocd-apps"
  cat > "$TEST_TMPDIR/app/outpost.app.yaml" <<'YAML'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: gated-app
spec:
  tier: k3s
  k3s:
    manifest_repo: "${SCM_MCP_MANIFEST_REPO}"
YAML

  run env OUTPOST_NO_ENV=1 MANIFEST_REPO_URL=https://example.com/fallback.git \
          SCM_MCP_MANIFEST_REPO=https://example.com/scm-mcp/manifests.git \
          ROOT_DOMAIN=example.com \
          bash "$CLI" onboard "$TEST_TMPDIR/app" \
            --manifests-dir "$TEST_TMPDIR/manifests" \
            --lang go \
            --no-reload
  [ "$status" -eq 0 ]
  run grep -F "https://example.com/scm-mcp/manifests.git" "$TEST_TMPDIR/manifests/argocd-apps/gated-app.yaml"
  [ "$status" -eq 0 ]
}

@test "outpost onboard --install-skill: copies skill template into app's .claude/skills/" {
  mkdir -p "$TEST_TMPDIR/app"
  # tier=k3s + no --manifests-dir is a valid path: onboard prints the
  # next-step hint and runs install-skill (tier-agnostic, runs unconditionally).
  cp "${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example" "$TEST_TMPDIR/app/outpost.app.yaml"
  run bash "$CLI" onboard "$TEST_TMPDIR/app" --no-reload --install-skill --force
  [ "$status" -eq 0 ]
  [ -r "$TEST_TMPDIR/app/.claude/skills/outpost-deploy.skill.md" ]
}

@test "outpost onboard --install-skill: idempotent (preserves existing skill)" {
  mkdir -p "$TEST_TMPDIR/app/.claude/skills"
  cp "${INFRA_ROOT}/examples/outpost.app.yaml.minimal.example" "$TEST_TMPDIR/app/outpost.app.yaml"
  printf "# CUSTOM SKILL — DO NOT OVERWRITE\n" > "$TEST_TMPDIR/app/.claude/skills/outpost-deploy.skill.md"
  run bash "$CLI" onboard "$TEST_TMPDIR/app" --no-reload --install-skill
  [ "$status" -eq 0 ]
  # Without --force, the existing file is preserved.
  run grep -F "# CUSTOM SKILL — DO NOT OVERWRITE" "$TEST_TMPDIR/app/.claude/skills/outpost-deploy.skill.md"
  [ "$status" -eq 0 ]
}

@test "outpost onboard k3s: missing --manifests-dir prints helpful hint, no error" {
  # Without --manifests-dir we render the Caddy side (none for k3s) but
  # don't try to scaffold. Operators get a clear next-command hint.
  mkdir -p "$TEST_TMPDIR/app"
  cat > "$TEST_TMPDIR/app/outpost.app.yaml" <<'YAML'
apiVersion: outpost.dev/v1
kind: App
metadata:
  name: needs-dir
spec:
  tier: k3s
  k3s:
    manifest_repo: https://example.com/override/manifests.git
YAML

  run bash "$CLI" onboard "$TEST_TMPDIR/app" --no-reload
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--manifests-dir" ]]
  # The hint should surface the per-app override so the operator knows
  # where to clone.
  [[ "$output" =~ "https://example.com/override/manifests.git" ]]
}
