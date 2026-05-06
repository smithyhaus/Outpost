#!/usr/bin/env bash
# =============================================================================
# platform/linux.sh — Linux native bootstrap hooks
# =============================================================================

sk_install_docker() {
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is running"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker via the official convenience script..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
    warn "You may need to log out / log back in for the docker group to apply."
  fi
  sudo systemctl enable --now docker || sudo service docker start
  docker info >/dev/null 2>&1 || { err "Docker did not come up"; return 1; }
  ok "Docker installed & running"
}

# Native k3s installation. Idempotent — re-running is a no-op.
sk_install_k3s() {
  if kubectl version --request-timeout=3s >/dev/null 2>&1; then
    ok "k3s already reachable via kubectl"
    return 0
  fi
  log "Installing k3s natively..."
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode=644 \
    --disable=metrics-server
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$(id -u):$(id -g)" ~/.kube/config
  if ! command -v kubectl >/dev/null 2>&1; then
    sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  fi
  ok "k3s installed (systemd unit: k3s.service)"
}

# Linux native: systemd handles autostart automatically via Docker / k3s units.
sk_setup_autostart() {
  sudo systemctl enable docker.service 2>/dev/null || true
  sudo systemctl enable k3s.service 2>/dev/null || true
  # Compose containers use restart: unless-stopped; nothing else to do.
  ok "systemd will autostart docker, k3s; compose containers self-restore"
}

# Configure registry mirrors only if the user has no daemon.json yet.
# We refuse to overwrite an existing config (user may have customizations).
sk_configure_registry_mirror() {
  local cfg="/etc/docker/daemon.json"
  if [[ -f "$cfg" ]]; then
    warn "$cfg exists; not modifying. To use mirrors, edit it manually."
    return 0
  fi
  log "Writing default registry-mirrors to $cfg (none existed)..."
  sudo mkdir -p /etc/docker
  sudo tee "$cfg" >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.nju.edu.cn"
  ],
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "3"}
}
EOF
  sudo systemctl restart docker
  ok "Registry mirrors configured (DaoCloud + NJU). Edit $cfg to override."
}

sk_print_post_install_notes() {
  cat <<'EOF'

Linux post-install notes
------------------------
- systemd manages docker and k3s — they will autostart on boot.
- For TCP access (postgres/redis/rabbitmq), install cloudflared:
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
  See i18n/en/docs/04-client-access.md for systemd-user services.
EOF
}
