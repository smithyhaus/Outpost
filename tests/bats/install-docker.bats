#!/usr/bin/env bats
# =============================================================================
# Unit tests for install.sh — ensure_docker preflight.
#
# install.sh is the canonical `curl … | bash` entrypoint. It must work from a
# bare Linux/WSL2 with no docker pre-installed, so ensure_docker auto-installs
# the engine there (get.docker.com) and points macOS at Docker Desktop. The
# real install path runs get.docker.com and is exercised by integration runs;
# here we cover the decision branches with stubs.
#
# install.sh runs main() at the bottom unless OUTPOST_INSTALL_SOURCE_ONLY=1,
# which lets us source it for testing without performing an install.
# =============================================================================

setup() {
  INFRA_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  INSTALL_SH="${INFRA_ROOT}/install.sh"
}

@test "ensure_docker is a no-op when docker already works" {
  run bash -c '
    export OUTPOST_INSTALL_SOURCE_ONLY=1
    source "'"$INSTALL_SH"'"
    docker() { return 0; }                 # `docker info` succeeds
    _install_docker_engine() { echo "INSTALL-CALLED"; }
    ensure_docker
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "docker ready" ]]
  [[ "$output" != *"INSTALL-CALLED"* ]]    # must NOT try to install
}

@test "ensure_docker triggers the engine install on Linux when docker is absent" {
  run bash -c '
    export OUTPOST_INSTALL_SOURCE_ONLY=1
    source "'"$INSTALL_SH"'"
    docker() { return 1; }                 # info fails (not installed)
    command() { return 1; }                # `command -v docker` -> not found
    uname() { echo Linux; }
    id() { echo "u docker g"; }            # pretend group active after install
    _install_docker_engine() { echo "INSTALL-CALLED"; docker() { return 0; }; }
    ensure_docker
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ "INSTALL-CALLED" ]]
  [[ "$output" =~ "docker ready" ]]
}

@test "ensure_docker dies with Docker Desktop guidance on macOS" {
  run bash -c '
    export OUTPOST_INSTALL_SOURCE_ONLY=1
    source "'"$INSTALL_SH"'"
    docker() { return 1; }
    command() { return 1; }                # docker binary absent
    uname() { echo Darwin; }
    ensure_docker
  '
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Docker Desktop" ]]
}

@test "ensure_docker tells the user to re-login when group not yet active" {
  run bash -c '
    export OUTPOST_INSTALL_SOURCE_ONLY=1
    source "'"$INSTALL_SH"'"
    docker() { return 1; }                 # info keeps failing this shell
    command() { return 0; }                # binary present
    sudo() { return 0; }
    systemctl() { return 0; }
    id() { echo "u docker g"; }            # user IS in docker group
    ensure_docker
  '
  [ "$status" -ne 0 ]
  [[ "$output" =~ "newgrp docker" ]]
}
