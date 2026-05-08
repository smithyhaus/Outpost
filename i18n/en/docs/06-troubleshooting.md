# 06 — Troubleshooting

## General triage

```bash
./status.sh           # quick snapshot
./verify.sh           # detailed checks
./verify.sh --json    # machine-parseable for AI agents
```

## Compose layer

### Containers won't start
```bash
cd core/compose
docker compose ps
docker compose logs <service> --tail 100
```

### cloudflared not connecting
```bash
docker logs cloudflared --tail 100
```
Look for `Registered tunnel connection`. Common failures:
- `failed to fetch token` → `CF_TUNNEL_TOKEN` wrong / expired
- `connection refused` → CF Public Hostname URL points to wrong service:port
- DNS issues → `docker exec cloudflared nslookup api.cloudflare.com`

### Data service unhealthy
```bash
docker inspect --format='{{.State.Health.Status}}' postgres
docker logs postgres --tail 200
```

## k3s / K8s

### k3s won't start (Linux/WSL2)
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200
```
Common causes on WSL2: cgroup v2 missing → enable systemd in `/etc/wsl.conf`;
iptables module unavailable → `sudo apt install iptables`; port 6443
already bound.

### Traefik not on NodePort 30080
```bash
kubectl get helmchartconfig -n kube-system
kubectl describe svc -n kube-system traefik
```
Type should be `NodePort` and ports include `web: 30080`.

### Pod stuck Pending
```bash
kubectl describe pod -n <ns> <pod>
```
Common: `Insufficient memory` (give WSL more RAM); `unbound PVC` (local-path
provisioner not running).

### Pod can't reach `host.docker.internal`
mirrored networking should make it work. If not:
```bash
kubectl run -it --rm test --image=alpine --restart=Never -- \
  sh -c "apk add curl >/dev/null && curl -v http://host.docker.internal:5432"
```
Fallback: hard-code the WSL host IP (`ip route show default`) in the
ExternalName service.

## ArgoCD

### UI 502
```bash
kubectl logs -n argocd deploy/argocd-server --tail 100
kubectl get ingressroute -n argocd
```
Common: missed the `server.insecure: "true"` ConfigMap → `kubectl rollout
restart deploy/argocd-server -n argocd`. Or IngressRoute Host typo.

### Application stuck OutOfSync
- UI → click SYNC
- `kubectl get app -n argocd <name> -o yaml | yq '.status.conditions'`
- Common: manifest YAML invalid; repo unreachable; credentials secret stale

### Repo authentication fails
- Secret `git-manifest-repo` (provider-agnostic) carries the token
- `kubectl edit secret -n argocd <secret>` to rotate

## Tekton

### Webhook receives but no PipelineRun
```bash
kubectl logs -n tekton-pipelines deploy/el-<provider>-listener --tail 200
```
Common: signature mismatch (wrong secret in repo's webhook), or CEL filter
rejects the event.

### PipelineRun stuck on git-clone
- workspace PVC unbound → `kubectl describe pvc -n tekton-pipelines`
- Git credentials wrong → secret `git-credentials` (in `tekton-pipelines` namespace)

### Kaniko build fails
- Dockerfile missing in the app repo root
- Push 401 → `registry-credentials` mismatch (self-hosted is anonymous;
  aliyun-acr needs a real password)
- Registry unreachable → `kubectl exec -it <pod> -- wget -O- http://registry.<root>`

## Network / Cloudflare

### Domain doesn't resolve
```bash
dig argocd.<root>
```
Should return Cloudflare IPs. NXDOMAIN = NS not switched, or Public
Hostname not configured.

### Domain resolves but 502 / 521 / 522 / 524
- 502: backend service down
- 521 / 522 / 524: cloudflared can't reach origin → check container is up,
  `docker logs cloudflared`

### Webhook returns 522 / 524
- WSL distro stopped (Windows reboot) → autostart task failed → check
  `/tmp/outpost-autostart.log`

## Last resort — full reset

```bash
./reset.sh         # type the confirmation phrase
./bootstrap.sh
```
