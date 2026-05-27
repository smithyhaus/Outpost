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
kubectl logs -n tekton-pipelines deploy/el-build-listener --tail 200
```
Common: signature mismatch (wrong secret in repo's webhook), or CEL filter
rejects the event.

### PipelineRun stuck on git-clone
- workspace PVC unbound → `kubectl describe pvc -n tekton-pipelines`
- Git credentials wrong → secret `git-credentials` (in `tekton-pipelines` namespace)

### Kaniko build fails
- Dockerfile missing in the app repo root
- Push 401 → `registry-credentials` mismatch (self-hosted is anonymous;
  aliyun-acr needs a real password). Inspect:
  `kubectl -n tekton-pipelines get secret registry-credentials -o jsonpath='{.data.config\.json}' | base64 -d`
- Registry unreachable → `kubectl exec -it <pod> -- wget -O- http://registry.<root>`

### Build pod reports `Evicted` / ephemeral-storage pressure
Symptom: a fresh build's `step-write-url` or `step-build-and-push`
container terminates with `Reason: Evicted` and
`The node was low on resource: ephemeral-storage`, with no application-
level cause.

Root cause: Tekton does not GC finished PipelineRuns by default. Each
completed kaniko pod holds 0.5–2 GB of ephemeral storage. After ~50
builds the single-node k3d host crosses the kubelet's ephemeral-storage
threshold and starts Evicting fresh pods.

Mitigation (automatic since v0.5+): Outpost installs a `tekton-pruner`
CronJob that sweeps hourly, deleting PipelineRuns whose
`status.completionTime` is older than 24h. PR deletion cascades to its
TaskRuns + their pods via owner-references, releasing the held
ephemeral storage. The Tekton Dashboard still shows runs within the
retention window for debugging.

Tunable via `.env`:
```env
OUTPOST_TEKTON_RETENTION_HOURS=24            # shorten if you're tight on disk
OUTPOST_TEKTON_PRUNE_SCHEDULE="0 * * * *"    # hourly; for hot clusters try "*/15 * * * *"
```

If you're stuck mid-incident (cron next tick is too far away):
```bash
# Fire the pruner now without waiting for the schedule
kubectl create job --from=cronjob/tekton-pruner -n tekton-pipelines \
  tekton-pruner-manual-$(date +%s)
# Watch its output
kubectl logs -n tekton-pipelines -l job-name=tekton-pruner-manual-...
```

Confirm the diagnosis:
```bash
kubectl describe node | grep -E "ephemeral-storage|DiskPressure"
kubectl get pods -n tekton-pipelines --field-selector=status.phase=Failed
```

### `admission webhook denied: tasks + finally > pipeline`
You added a Pipeline task (or bumped one's per-task timeout) and the
sum exceeded `triggertemplate.yaml`'s `timeouts.tasks` /
`timeouts.finally` budget. Tekton enforces
`tasks + finally <= pipeline` at run-creation time.
Fix: bump the appropriate field in
`core/k8s/05-tekton/triggertemplate.yaml` and re-apply.

### Dashboard returns 401
Tekton Dashboard + Argo Rollouts UI are sealed behind a shared Traefik
BasicAuth middleware. Username = `OUTPOST_DASHBOARD_USER` (default
`outpost`), password = `OUTPOST_DASHBOARD_PASSWORD` — both live in
`INFRA.md` §0 and `.env`.
`kubectl -n tekton-pipelines get secret dashboard-auth-secret -o jsonpath='{.data.users}' | base64 -d`
shows the htpasswd line currently active.

## Phase J — Test gate, auto-rollback, notifications

(Only active if you opted in — see
[`00-quickstart.md` Phase J](./00-quickstart.md).)

### `run-tests` task is always skipped
Repo root has no `outpost.test.yaml` and no `Dockerfile.test`. The
task no-ops cleanly; this is the "your repo isn't using the test gate"
path. To engage Gate A, add either file.

### `run-tests` task fails with `bash: command not found` / similar
The task runs in a stock `alpine:3.20` step; `outpost.test.yaml`'s
`runner.command` must apk-install whatever runtime it needs, e.g.
`["sh","-c","apk add --no-cache go && go test ./..."]`. Phase 2 swaps
this for a Testkube TestWorkflow with `content.git`; for now the heavy
language runtime install is on the application author.

### Rollouts aborts every canary step
`AnalysisTemplate` thresholds are intentionally tight
(`failureLimit: 2`, `consecutiveErrorLimit: 3`). Inspect:
```bash
kubectl get analysisrun -n apps
kubectl describe analysisrun -n apps <name>
```
If the service is healthy but the probe expects a different shape,
loosen `successCondition` in
`plugins/rollout/argo-rollouts/analysistemplate-default.yaml`.

### Notifications don't fire
- `NOTIFICATION_PROVIDERS` empty in `.env` → re-bootstrap with at
  least one channel listed.
- `kubectl logs -n tekton-pipelines <pipelinerun-pod> -c step-fanout`
  shows the per-provider POST attempts. `[WARN] <p> delivery failed`
  = vendor returned non-2xx; check the webhook URL.
- DingTalk / Feishu signed webhook: host clock skew breaks the
  HMAC signature — keep system clock in sync.

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
./reset.sh         # type the confirmation phrase. preserves secrets-backup/
./bootstrap.sh     # restores sealed-secrets master key from secrets-backup/
```

If you suspect the sealed-secrets master key has been compromised, or
want a totally clean slate (incl. forced re-sealing of every existing
SealedSecret), use:

```bash
./reset.sh --hard  # also wipes secrets-backup/ — every SealedSecret
                   # in your manifest repos must be re-sealed afterward
./bootstrap.sh
```
