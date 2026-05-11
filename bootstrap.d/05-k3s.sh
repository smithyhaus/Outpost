# shellcheck shell=bash
# =============================================================================
# Phase 5 — k3s cluster (full mode only).
# =============================================================================
phase "Phase 5 / 10 k3s cluster"

sk_install_k3s
sk_setup_autostart
sk_configure_registry_mirror

# Apply Traefik NodePort config
case "$SK_OS" in
  linux|wsl2)
    sudo cp core/k8s/01-traefik-config.yaml /var/lib/rancher/k3s/server/manifests/
    sleep 5
    ;;
  macos)
    # k3d already exposes 30080/30443 via the cluster create command.
    kubectl apply -f core/k8s/01-traefik-config.yaml
    ;;
esac

# Configure containerd insecure registry mirror for self-hosted plugin
if [[ "$REGISTRY_PLUGIN" == "self-hosted" && ( "$SK_OS" == "linux" || "$SK_OS" == "wsl2" ) ]]; then
  log "Configuring containerd insecure registry mirror..."
  sudo mkdir -p /etc/rancher/k3s
  sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<EOF
mirrors:
  registry.${ROOT_DOMAIN}:
    endpoint:
      - "http://registry.${ROOT_DOMAIN}"
configs:
  registry.${ROOT_DOMAIN}:
    tls:
      insecure_skip_verify: true
EOF
  sudo systemctl restart k3s 2>/dev/null || true
  sleep 10
fi

kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f core/k8s/00-namespaces.yaml
kubectl apply -f core/k8s/02-apps-resource-controls.yaml
ok "k3s ready, namespaces + apps resource controls applied"
