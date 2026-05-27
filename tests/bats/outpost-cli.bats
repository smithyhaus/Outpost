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
  for sub in status verify doctor open logs rollback seal seal-from-template db manifest new-app decommission setup-argocd-webhook; do
    [[ "$output" == *"$sub"* ]] || { echo "missing subcommand in help: $sub"; return 1; }
  done
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
  # With no kubectl present this will error on the FIRST kubectl call (which
  # is `kubectl get application`), so we look for the ArgoCD-lookup header
  # to confirm we got past flag parsing.
  run bash "$CLI" verify --app testapp --namespace customns 2>&1
  # Exit code may be non-zero (no cluster); the structural assertion is that
  # the script reached the kubectl section, not bailed on flag parsing.
  [[ "$output" =~ "ArgoCD Application" ]] \
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
  [[ "$output" =~ "unknown" ]] || [[ "$output" =~ "argocd" ]]
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
