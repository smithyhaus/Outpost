#!/usr/bin/env bash
# =============================================================================
# platform/macos.sh — macOS-specific bootstrap hooks
# -----------------------------------------------------------------------------
# Sourced by bootstrap.sh after detect_os.
# All functions here are idempotent.
# =============================================================================

# Install Docker on macOS — Docker Desktop is the de facto path.
# We do NOT auto-install it (interactive license accept). We check + instruct.
sk_install_docker() {
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is running"
    return 0
  fi
  err "Docker Desktop is not running."
  cat <<EOF
  On macOS, install and start Docker Desktop:
    brew install --cask docker
    open -a Docker
  Then re-run bootstrap.sh.
EOF
  return 1
}

# k3s does not run natively on macOS (Linux-only kernel modules).
# We launch k3s inside Docker via the official rancher/k3s image.
sk_install_k3s() {
  if kubectl version --request-timeout=3s >/dev/null 2>&1; then
    ok "k3s already reachable via kubectl"
    return 0
  fi
  log "macOS detected — installing k3s via k3d (k3s in Docker)"
  if ! command -v k3d >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      brew install k3d
    else
      curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi
  fi
  k3d cluster create selfhost \
    --servers 1 \
    --port "30080:30080@server:0" \
    --port "30443:30443@server:0" \
    --k3s-arg "--disable=metrics-server@server:0" \
    --wait
  k3d kubeconfig merge selfhost --kubeconfig-switch-context
  ok "k3d cluster 'selfhost' running"
}

# Autostart on macOS uses launchd. We register a LaunchAgent for the user.
sk_setup_autostart() {
  local agent="$HOME/Library/LaunchAgents/io.smithyhaus.outpost.compose.plist"
  local infra_dir="${SK_INFRA_DIR:-$HOME/outpost}"
  # In full mode the cloudflared+caddy services are gated behind --profile tunnel.
  # In local mode they don't exist; including --profile is a harmless no-op.
  local profile_flag="--profile tunnel"
  if [[ "${OUTPOST_MODE:-}" == "local" ]]; then
    profile_flag=""
  fi

  mkdir -p "$(dirname "$agent")"
  # CRITICAL: LaunchAgents do NOT inherit the user's shell environment.
  # Without --env-file pointing at the canonical .env (which lives at the
  # infra root, not next to the compose file), every ${VAR} in
  # docker-compose.yml expands to "" and containers get recreated with
  # blank env vars (postgres unhealthy, redis "wrong number of arguments",
  # manticore healthcheck fails on missing config, etc.).
  cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>io.smithyhaus.outpost.compose</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>/usr/local/bin/docker compose --env-file ${infra_dir}/.env -f ${infra_dir}/core/compose/docker-compose.yml ${profile_flag} up -d</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/outpost.log</string>
  <key>StandardErrorPath</key><string>/tmp/outpost.err</string>
</dict></plist>
EOF
  launchctl unload "$agent" 2>/dev/null || true
  launchctl load "$agent"
  ok "LaunchAgent registered: $agent"
}

# macOS Docker Desktop doesn't read /etc/docker/daemon.json. Mirror config is
# done via Docker Desktop UI → Settings → Docker Engine. We don't auto-modify.
sk_configure_registry_mirror() {
  warn "Registry mirror config on macOS Docker Desktop must be set via the UI:"
  warn "  Docker Desktop → Settings → Docker Engine → add registry-mirrors"
  warn "  Recommended (CN): https://docker.m.daocloud.io"
}

# Wake-after-shutdown is automatic on macOS (Docker Desktop launches with login).
sk_print_post_install_notes() {
  cat <<'EOF'

macOS post-install notes
------------------------
- Docker Desktop manages the engine; no systemd needed.
- k3s runs inside Docker via k3d cluster `selfhost`.
- LaunchAgent will start Compose at login. Logs: /tmp/outpost.log.
- For TCP access (postgres / redis / rabbitmq), install cloudflared:
    brew install cloudflared
  See i18n/en/docs/04-client-access.md.
EOF
}
