#!/usr/bin/env bats
# =============================================================================
# Smoke test for the outpost CLI (scripts/outpost).
# Exercise help / version / unknown-subcommand paths — no kubectl side effects.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CLI="${INFRA_ROOT}/scripts/outpost"
  [ -x "$CLI" ] || skip "scripts/outpost not executable"
}

@test "outpost: bash syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "outpost help: prints usage with all advertised subcommands" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "outpost" ]]
  for sub in status verify doctor open logs rollback seal seal-from-template db manifest new-app onboard off-board decommission; do
    [[ "$output" == *"$sub"* ]] || { echo "missing subcommand in help: $sub"; return 1; }
  done
}

@test "outpost help: no dead v0.2 engine commands (argocd/tekton/webhooks)" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  for gone in setup-argocd-webhook register-webhooks tekton rollouts ArgoCD; do
    [[ "$output" != *"$gone"* ]] || { echo "stale reference in help: $gone"; return 1; }
  done
}

@test "outpost setup-argocd-webhook / register-webhooks: removed, exit non-zero" {
  run bash "$CLI" setup-argocd-webhook
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown" ]]
  run bash "$CLI" register-webhooks
  [ "$status" -ne 0 ]
}

@test "outpost help: verify documents --namespace flag" {
  run bash "$CLI" help
  [ "$status" -eq 0 ]
  # The hardcoded 'apps' ns lookup was a latent bug for apps that pick their
  # own namespace (e.g. via Application.spec.destination.namespace=scm-mcp).
  # Help must advertise the override so operators know it's a flag, not a
  # hidden env var.
  [[ "$output" =~ "--namespace" ]] || { echo "verify --namespace not in help"; return 1; }
}

@test "outpost verify: --namespace flag parses without 'unknown option'" {
  # No cluster needed — verify the CLI accepts the flag in its argparse loop.
  # The structural assertion is that the script reached the app-scoped pod
  # section WITH the custom namespace, not that kubectl succeeded.
  command -v kubectl >/dev/null 2>&1 || skip "kubectl not available"
  run bash "$CLI" verify --app testapp --namespace customns 2>&1
  # Exit code may be non-zero (no cluster); check we got past flag parsing.
  [[ "$output" =~ "Pods in customns namespace" ]] \
    || { echo "verify --namespace appears to short-circuit"; echo "$output"; return 1; }
}

@test "outpost (no args): defaults to help" {
  run bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "USAGE" ]]
}

@test "outpost --help / -h: equivalent to help" {
  run bash "$CLI" --help
  [ "$status" -eq 0 ]
  run bash "$CLI" -h
  [ "$status" -eq 0 ]
}

@test "outpost version: prints v<VERSION> and commit" {
  run bash "$CLI" version
  [ "$status" -eq 0 ]
  # Format: "outpost v<VERSION> (commit <sha>)" — sourced from VERSION file + git
  [[ "$output" =~ ^outpost\ v[0-9]+\.[0-9]+\.[0-9]+\ \(commit\ .+\)$ ]]
}

@test "outpost <unknown>: exits non-zero with hint" {
  run bash "$CLI" no-such-command
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown" ]]
}

@test "outpost open: requires target arg" {
  run bash "$CLI" open
  [ "$status" -ne 0 ]
}

@test "outpost open <unknown>: rejects with hint" {
  run bash "$CLI" open mars-rover
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown" ]] || [[ "$output" =~ "search" ]]
}

@test "outpost open: v0.2 dashboard targets (argocd/tekton/rollouts) are gone" {
  for t in argocd tekton rollouts; do
    run bash "$CLI" open "$t"
    [ "$status" -ne 0 ] || { echo "open $t should be rejected"; return 1; }
  done
}

@test "outpost onboard: requires a repo-url-or-path argument" {
  run bash "$CLI" onboard
  [ "$status" -ne 0 ]
  [[ "$output" =~ "onboard" ]]
}

@test "outpost rollback: without sha it only lists tags (needs no confirm)" {
  # No registry reachable in tests — the command must die on tag listing,
  # not on a missing argocd CLI (v0.2 behavior).
  run bash "$CLI" rollback someapp
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tags" ]] || [[ "$output" =~ "registry" ]]
}

@test "outpost new-app: requires --lang" {
  run bash "$CLI" new-app foo
  [ "$status" -ne 0 ]
  [[ "$output" =~ "lang" ]]
}

@test "outpost rollback: requires app name" {
  run bash "$CLI" rollback
  [ "$status" -ne 0 ]
}

@test "outpost decommission: requires app name" {
  run bash "$CLI" decommission
  [ "$status" -ne 0 ]
}
