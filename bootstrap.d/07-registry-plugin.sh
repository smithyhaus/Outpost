# shellcheck shell=bash
# =============================================================================
# Phase 7 — Registry plugin (git-provider plugin deferred to Phase 8 because
# it needs Tekton CRDs to exist first).
# =============================================================================
phase "Phase 7 / 10 Plugins (registry)"

log "Applying registry plugin: ${REGISTRY_PLUGIN}"
render_apply "plugins/registry/${REGISTRY_PLUGIN}/manifest.yaml"
ok "Registry plugin applied"

# Configure containerd to use the in-cluster docker-registry as a mirror for
# `registry.${ROOT_DOMAIN}`. Without this, k8s pulls go through cloudflared,
# which has an HTTP/2 PROTOCOL_ERROR ceiling on large blob transfers
# (multi-stage Java/Dotnet builds easily hit it).
#
# macOS-specific path: k3d node is a Docker container; we write registries.yaml
# inside it (idempotent on content) and restart the k3s server only when
# content actually changed (so re-running bootstrap on a healthy cluster is
# disruption-free).
if [[ "$REGISTRY_PLUGIN" == "self-hosted" && "$SK_OS" == "macos" ]]; then
  log "Configuring k3d containerd registry mirror (macOS)..."

  # docker-registry Service ClusterIP is stable for the cluster's lifetime
  # (recreated on `k3d cluster delete`; that's fine — bootstrap re-runs).
  REG_IP=$(kubectl get svc -n registry docker-registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [[ -z "$REG_IP" ]]; then
    warn "docker-registry ClusterIP not found yet — skipping mirror config"
  else
    DESIRED=$(cat <<EOF
mirrors:
  registry.${ROOT_DOMAIN}:
    endpoint:
      - "http://${REG_IP}:5000"
configs:
  "${REG_IP}:5000":
    tls:
      insecure_skip_verify: true
EOF
)
    K3D_NODE="k3d-${OUTPOST_K3D_CLUSTER:-selfhost}-server-0"
    CURRENT=$(docker exec "$K3D_NODE" cat /etc/rancher/k3s/registries.yaml 2>/dev/null || echo "")
    if [[ "$CURRENT" != "$DESIRED" ]]; then
      printf '%s\n' "$DESIRED" | docker exec -i "$K3D_NODE" sh -c 'cat > /etc/rancher/k3s/registries.yaml'
      log "  registries.yaml updated; restarting k3d node to reload containerd..."
      docker restart "$K3D_NODE" >/dev/null
      # Wait for kube-apiserver to come back before asking it for node status —
      # otherwise kubectl wait gets ServiceUnavailable from the LB and exits
      # immediately (set -e then aborts the whole bootstrap).
      log "  waiting for kube-apiserver to come back..."
      for _ in {1..60}; do
        kubectl get --raw=/readyz >/dev/null 2>&1 && break
        sleep 2
      done
      kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
      ok "containerd mirror set: registry.${ROOT_DOMAIN} -> ${REG_IP}:5000"
    else
      ok "containerd mirror already up to date"
    fi
  fi
fi

# git-provider plugin contains Tekton TriggerBinding (triggers.tekton.dev CRD).
# Defer it to Phase 8 right after `kubectl apply` of Tekton triggers/release.yaml.
