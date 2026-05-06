#!/usr/bin/env bash
# =============================================================================
# platform/wsl2.sh — WSL2 (Windows 11+) bootstrap hooks
# -----------------------------------------------------------------------------
# WSL2 is a Linux kernel under Windows; most of the Linux paths apply, but
# autostart behaves differently (no Windows service from inside WSL), and
# we want to surface .wslconfig / mirrored networking advice.
# =============================================================================

# Inherit Linux native install paths for docker / k3s / mirror config —
# we only override autostart and add platform-specific advice.
_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./linux.sh
source "${_PLATFORM_DIR}/linux.sh"

# WSL2 autostart: services started inside WSL die when the distro shuts down.
# We can't register a true Windows service from here, but we can:
#   1) make sure WSL has systemd enabled (so docker/k3s autostart inside WSL)
#   2) print explicit instructions for the Windows-side Task Scheduler entry
sk_setup_autostart() {
  # Ensure systemd is enabled in /etc/wsl.conf
  if ! grep -q "^systemd=true" /etc/wsl.conf 2>/dev/null; then
    log "Enabling systemd in /etc/wsl.conf (requires 'wsl --shutdown' to apply)"
    sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false
EOF
    warn "After bootstrap completes, run 'wsl --shutdown' from PowerShell,"
    warn "then reopen WSL. systemd will manage docker/k3s autostart."
  else
    ok "systemd already enabled in /etc/wsl.conf"
  fi
  # systemd unit-level enable (re-uses linux.sh logic)
  sudo systemctl enable docker.service 2>/dev/null || true
  sudo systemctl enable k3s.service 2>/dev/null || true
}

# WSL2-specific finalisation guidance
sk_print_post_install_notes() {
  cat <<'EOF'

WSL2 post-install notes
-----------------------
1. ~/.wslconfig (in your Windows %UserProfile%) — recommended template:

       [wsl2]
       memory=<half of host RAM, e.g. 32GB>
       processors=<host cores - 4>
       swap=8GB
       networkingMode=mirrored
       firewall=true

   After editing, run `wsl --shutdown` in PowerShell.

2. Windows Task Scheduler (so WSL stays up after Windows reboot):

   - Open Task Scheduler → Create Task
   - Trigger: At log on
   - Action: Program  = wsl.exe
             Args     = -d Ubuntu -u <your-user> -- bash -lc "cd ~/outpost && ./status.sh > /tmp/outpost-autostart.log 2>&1 &"

3. mirrored networking requires Win11 22H2+. If not available, see
   i18n/en/docs/02-wsl-config.md for the NAT + portproxy fallback.

4. For TCP access from your dev workstation (PG/Redis/RabbitMQ AMQP), see
   i18n/en/docs/04-client-access.md.
EOF
}
