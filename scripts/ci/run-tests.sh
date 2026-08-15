#!/usr/bin/env bash
# =============================================================================
# scripts/ci/run-tests.sh — Gate A test runner (host side, containerized).
# -----------------------------------------------------------------------------
# Ported from core/k8s/05-tekton/run-tests-task.yaml, same application
# contract:
#   - outpost.test.yaml present   → run .runner.command (REQUIRED), exit code
#                                   decides pass/fail
#   - Dockerfile.test present     → recognized, treated as plumbing-OK pass
#                                   (the old task's Phase-2 placeholder —
#                                   behavior preserved exactly)
#   - neither                     → "Gate A: skipped", exit 0 (clean no-op,
#                                   needs no external tools)
#
# Execution model: the user's command comes from a CHECKED-OUT APP REPO, i.e.
# it is untrusted relative to the runner host. It therefore runs inside a
# container (docker run, workspace bind-mounted at /workspace), never bare on
# the host. Docker is the engine of choice because the WSL2 runner host
# reliably has it (it already hosts the compose edge profile); buildkitd has
# no "run" primitive without abusing a build. If docker is missing while
# tests exist, this FAILS loudly rather than degrading to host execution.
#
# The old task eval'd the command with bash inside alpine:3.20 after
# apk-installing bash (CN mirror first) — same dance below, inside the
# container. `.runner.image` (optional) overrides the image per app.
#
# Usage: run-tests.sh [<workspace>]   (default: $GITHUB_WORKSPACE)
# bash-3.2 compatible.
# =============================================================================
set -euo pipefail

WORKSPACE="${1:-${GITHUB_WORKSPACE:-}}"
[[ -n "$WORKSPACE" ]] || { echo "[ERR] usage: run-tests.sh <workspace> (or set GITHUB_WORKSPACE)" >&2; exit 2; }
[[ -d "$WORKSPACE" ]] || { echo "[ERR] workspace not a directory: $WORKSPACE" >&2; exit 2; }

# Config (TEST_RUNNER / OUTPOST_TEST_IMAGE) comes from the infra .env — same
# sourcing pattern as build-image.sh; OUTPOST_NO_ENV=1 keeps bats hermetic.
_CI_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPOST_ROOT="${OUTPOST_ROOT:-$(cd "$_CI_DIR/../.." && pwd)}"
if [[ -f "$OUTPOST_ROOT/.env" && "${OUTPOST_NO_ENV:-0}" != "1" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$OUTPOST_ROOT/.env"
  set +a
fi

# ---- detect (no external tools needed — keep the skip path instant) ---------
if [[ -f "$WORKSPACE/outpost.test.yaml" ]]; then
  mode="outpost-yaml"
elif [[ -f "$WORKSPACE/Dockerfile.test" ]]; then
  mode="dockerfile"
else
  echo "[INFO] no outpost.test.yaml / Dockerfile.test in repo root"
  echo "[INFO] Gate A: skipped"
  exit 0
fi
echo "[INFO] detected test mode: $mode"

# ---- active test-runner plugin (host analogue of the old ConfigMap mount) ---
# TEST_RUNNER is the configured knob (.env / 02-config.sh); the old
# TEST_RUNNER_PLUGIN name is honored as an override for backward compat.
runner="${TEST_RUNNER_PLUGIN:-${TEST_RUNNER:-testkube}}"
echo "[INFO] active test-runner plugin: $runner"
if [[ "$runner" == "none" || "$runner" == "catalog-tasks" ]]; then
  echo "[INFO] test-runner '$runner': Gate A no-ops here"
  echo "[INFO] Gate A: skipped"
  exit 0
fi

# ---- run --------------------------------------------------------------------
if [[ "$mode" == "outpost-yaml" ]]; then
  command -v yq >/dev/null 2>&1 || { echo "[ERR] yq (mikefarah v4+) required on the runner host" >&2; exit 2; }
  if ! yq -e '.runner.command' "$WORKSPACE/outpost.test.yaml" >/dev/null 2>&1; then
    echo "[ERR] outpost.test.yaml: .runner.command is required (MVP)" >&2
    echo "[ERR] Gate A failed"
    exit 1
  fi
  CMD=$(yq -r '.runner.command | join(" ")' "$WORKSPACE/outpost.test.yaml")
  IMG=$(yq -r '.runner.image // ""' "$WORKSPACE/outpost.test.yaml")
  [[ -z "$IMG" || "$IMG" == "null" ]] && IMG="${OUTPOST_TEST_IMAGE:-alpine:3.20}"

  # Untrusted-code containment: never run the repo's command bare on the host.
  command -v docker >/dev/null 2>&1 || {
    echo "[ERR] docker is required to containerize Gate A commands (refusing bare-host execution)" >&2
    exit 1
  }

  # Write the command to a file instead of inlining it into -c: no shell
  # re-quoting layer for the (untrusted) command to escape through.
  GATE_TMP=$(mktemp -d)
  trap 'rm -rf "$GATE_TMP"' EXIT
  printf '%s\n' "$CMD" > "$GATE_TMP/cmd.sh"

  echo "[INFO] Gate A: running in $IMG: $CMD"
  if docker run --rm \
      -v "$WORKSPACE":/workspace -w /workspace \
      -v "$GATE_TMP":/outpost-gate:ro \
      "$IMG" /bin/sh -c '
        # Same bash bootstrap as the old alpine task: CN mirror first, then
        # bash for the user command (apk absent on non-alpine images → no-op).
        if ! command -v bash >/dev/null 2>&1 && command -v apk >/dev/null 2>&1; then
          sed -i "s|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g" /etc/apk/repositories 2>/dev/null || true
          apk add --no-cache --quiet bash >/dev/null 2>&1 || true
        fi
        if command -v bash >/dev/null 2>&1; then
          exec bash /outpost-gate/cmd.sh
        fi
        exec /bin/sh /outpost-gate/cmd.sh
      '; then
    echo "[OK] Gate A passed"
  else
    rc=$?
    echo "[ERR] Gate A failed (exit $rc)" >&2
    exit "$rc"
  fi
elif [[ "$mode" == "dockerfile" ]]; then
  # Phase-2 placeholder semantics preserved from the old task: recognized,
  # not executed — treat as plumbing OK. (Executing it is a behavior change;
  # tracked in TODOS, do not "fix" silently.)
  echo "[INFO] Dockerfile.test detected — Phase 2 path; treating as plumbing OK"
  echo "[OK] Gate A passed"
fi
