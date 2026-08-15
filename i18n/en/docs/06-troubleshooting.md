# 06 — Troubleshooting

## General triage

```bash
./status.sh           # quick snapshot + sync heartbeat
./verify.sh           # detailed checks
./verify.sh --json    # machine-parseable for AI agents
```

`verify.sh` check ids are `<area>.<subject>` and map onto the sections
below: `compose.*` / `cloudflared.*`, `k8s.*` / `buildkit.*`, `ci.*`,
`sync.*`, `reconcile.*`, `data.*`, `edge.*`, `creds.*`.

## Compose layer

In `full` mode the Compose stack is `cloudflared` + `caddy` (the `edge`
profile) **plus** the four data services (`local-data` profile) — stateful
services live in Compose in both modes; see
[ADR-0005](../../../docs/decisions/0005-data-layer-back-to-host.md). In
`local` mode it is the four data services and nothing else.

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
- QUIC blocked (UDP/7844) → set `CF_TUNNEL_PROTOCOL=http2` in `.env` and
  restart. Note this disables `cloudflared access` TCP routes entirely
- DNS issues → `docker exec cloudflared nslookup api.cloudflare.com`

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
Type should be `NodePort` and ports include `web: 30080`. cloudflared
reaches this through `host.docker.internal:30080`, so every public HTTP
route dies with it.

### Pod stuck Pending
```bash
kubectl describe pod -n <ns> <pod>
```
Common: `Insufficient memory` (give WSL more RAM); `unbound PVC` (local-path
provisioner not running); `exceeded quota` (the `apps` namespace carries a
`ResourceQuota` — `kubectl describe quota -n apps`).

## Data layer (`infra-bridges`)

`verify.sh` ids: `data.postgres` / `data.redis` / `data.rabbitmq` /
`data.manticore`. Each is a real auth'd probe executed inside the pod, so
a FAIL means the service is genuinely down or refusing credentials.

```bash
docker ps --filter name=postgres --filter name=redis --filter name=rabbitmq --filter name=manticore
docker logs postgres --tail 200

# The same probes verify.sh runs (credentials expand inside the container)
docker exec postgres sh -c 'pg_isready -U "$POSTGRES_USER"'
docker exec -e REDIS_PASSWORD redis sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
docker exec rabbitmq rabbitmq-diagnostics -q ping
```

If the containers are healthy but *pods* still can't reach them, the
bridge is the suspect: `verify.sh` reports it as `data.bridge_dns`
(CoreDNS `host.docker.internal` entry vs the node's current IP — the
`coredns-hosts-reconciler` CronJob rewrites a stale entry within ~2min).

An app that can't reach a data service is almost always a wrong Service
name in its connection string. The names never change across modes:

```bash
kubectl exec -it -n apps <pod> -- \
  nslookup postgres.infra-bridges.svc.cluster.local
```

> `host.docker.internal` is **gone** from the cluster's DNS path. If any
> app config still points at it, that's the bug — the CoreDNS
> `coredns-custom` bridge is deleted on bootstrap.

## Build engine (buildkit + registry)

### `buildkit.daemon` FAIL — every build will fail
```bash
kubectl -n buildkit get pods
kubectl -n buildkit logs deploy/buildkitd --tail 200
kubectl wait --for=condition=Available deployment/buildkitd -n buildkit --timeout=420s
```
The daemon's startupProbe allows up to ~6 minutes when recovering a dirty
cache, so "not Ready yet" right after a restart is normal; "still not
Ready" is not.

### The runner can't reach buildkitd or the registry
Both are exposed to the host as NodePorts:

```bash
curl -s http://127.0.0.1:30500/v2/            # registry API → {}
nc -z 127.0.0.1 30750 && echo buildkitd-ok    # buildkitd gRPC
kubectl -n outpost-ci get svc                 # the NodePort definitions
```

### Push 401 / image pull 401
- Self-hosted registry is anonymous at the cluster level; a 401 on
  `https://registry.<root>` from outside usually means the Cloudflare
  **HTTP Host Header** override is missing (see `01-cloudflare-setup.md`)
- `aliyun-acr` needs real credentials — check `ALIYUN_ACR_*` in `.env`

## CI (GitHub Actions self-hosted runner)

`verify.sh` ids: `ci.runner`, `ci.runner.unit`, `ci.runner.online`,
`ci.workflow.<app>`.

### `ci.runner` WARN — "runner not configured"
`GITHUB_RUNNER_PAT` is empty, so bootstrap skipped the runner install.
**No build will ever trigger.** Set `GITHUB_RUNNER_URL` +
`GITHUB_RUNNER_PAT` in `.env` and re-run `bash bootstrap.sh`. (This state
is legitimate only when running this repo's own CI/e2e suite.)

### `ci.runner.unit` FAIL — no running runner service
```bash
systemctl status 'actions.runner.*'
cd ~/actions-runner && sudo ./svc.sh status
sudo ./svc.sh start
journalctl -u 'actions.runner.*' -n 200
```
Pushes **queue on GitHub** rather than failing, so nothing looks broken
from the app side — this check is the signal.

### `ci.runner.online` FAIL — "CI trigger path down"
GitHub's API says no online runner, or the API itself was unreachable.
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com   # proxy/egress alive?
systemctl status 'actions.runner.*'
```
Behind a proxy, the runner reads proxy vars from its own env file
(`~/actions-runner/.env`, seeded from `~/.outpost-proxy.env` at bootstrap).
Check that file if the runner works interactively but not as a service.
Also verify the PAT still has `admin:org` (org URL) or repo-admin scope.

### `ci.workflow.<app>` FAIL / WARN
- `no workflow runs yet` → the app repo is missing
  `.github/workflows/outpost-build.yml` (copy it from `templates/github/`)
- `last run: failure` → open the run in the GitHub Actions tab; the three
  meaningful steps are `Build image`, `Run tests (Gate A)`,
  `Update manifest`

### The push never reached github
The github copy is CI-trigger-only, and a dead mirror is silent:
```bash
git ls-remote <github-url> refs/heads/main
git ls-remote <gitee-url>  refs/heads/main   # should match
```
Re-check your dual-push remotes (`git remote -v`) or the gitee push-mirror
settings. This exact failure is what reconciliation exists to catch.

## CD (manifest-sync)

`verify.sh` ids: `sync.cronjob`, `sync.heartbeat`, `sync.result`.

### `sync.cronjob` FAIL — CronJob missing
Nothing deploys at all. Re-run `bash bootstrap.sh` (Phase 8 recreates it
and blocks until a fresh heartbeat lands).

### `sync.heartbeat` FAIL — stale
The heartbeat is older than 3× `MANIFEST_SYNC_INTERVAL`; sync has stopped
running regardless of the CronJob object existing.
```bash
kubectl -n outpost-ci get cm sync-heartbeat -o yaml
kubectl -n outpost-ci get jobs
kubectl -n outpost-ci get pods
outpost logs sync
```
Common: the node was asleep/down (WSL distro stopped), the SA lost apply
rights, or a previous job is wedged (`concurrencyPolicy: Forbid` means a
hung job blocks all later ticks — delete it).

### `sync.result` FAIL — last run errored
`outpost logs sync` prints the reason. The `last_result` value is
self-describing:

| `last_result` | Meaning |
|---|---|
| `error:git-clone` / `error:git-fetch` | can't reach the manifest repo — `GIT_USER`/`GIT_TOKEN` in the `notify-secrets` Secret, or gitee unreachable |
| `error:unexpected-rc=<n>` | the job aborted; read the pod log |
| anything else non-`ok` | apply or rollout-wait failed for a specific app — the log names it |

### Sync runs OK but my app didn't change
```bash
outpost status        # applied_head — is it the commit you pushed?
```
`manifest-sync` only applies directories under `apps/` that changed
between `applied_head` and `HEAD`. A commit that touches only
`argocd-apps/` or docs is logged as "nothing to apply" — that directory is
legacy and ignored.

To force a full re-apply of every `apps/<dir>` at the current head, clear
the remembered position — an empty `applied_head` makes the next run a
full sync:

```bash
kubectl -n outpost-ci delete cm sync-heartbeat
kubectl -n outpost-ci create job manifest-sync-full --from=cronjob/manifest-sync
```

(The script also honours `FORCE_SYNC=1` in its environment, which is the
same code path.)

### Trigger a sync immediately
```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
outpost logs sync
```

## Reconciliation (the ultimate judge)

`verify.sh` ids: `reconcile.git`, `reconcile.manifest`, `reconcile.repos`,
`reconcile.<app>`.

A `reconcile.<app>` FAIL means: this repo's **live branch head** has not
become a **deployed image tag** within `OUTPOST_STALENESS_THRESHOLD`
(default 1800s). It deliberately doesn't tell you *which* link broke —
it tells you the chain is broken, which is the thing that used to go
unnoticed for days. Walk it in order:

1. Did the push reach github? (`git ls-remote`)
2. Is the runner online? (`ci.runner.*`)
3. Did the workflow go red? (GitHub Actions tab)
4. Did the manifest repo get its bump commit?
5. Is sync alive and green? (`sync.*`)

`reconcile.repos` WARN means `OUTPOST_REPOS` is empty — the anti-silence
layer is blind. Onboard your apps (`outpost onboard <url>`).

## Test gate, auto-rollback, notifications

(Only active if you opted in — see `00-quickstart.md` Phase J.)

### Gate A is always skipped
The repo root has no `outpost.test.yaml` and no `Dockerfile.test`. That's
a clean no-op, not a failure. Add either file to engage it. Gate A also
no-ops when `TEST_RUNNER` is `none` or `catalog-tasks`.

### Gate A fails with "yq required" or "docker required"
Both run on the **runner host**, not in-cluster. Install `yq`
(mikefarah v4+) and Docker there. Gate A deliberately refuses to fall back
to bare host execution: the app repo's command is untrusted code, so it
always runs inside a container with the workspace bind-mounted at
`/workspace`.

### Gate A fails with `sh: <tool> not found`
The command runs in `alpine:3.20` by default. Either set
`runner.image` in `outpost.test.yaml` to a real toolchain image
(`golang:1.23-alpine`, `python:3.12-alpine`, …) or install what you need
inside the command itself.

### A canary keeps rolling back
Only relevant with `ROLLOUT_PLUGIN=argo-rollouts`.
```bash
kubectl get rollout -n apps
kubectl describe rollout -n apps <name>
```
`manifest-sync` polls `.status.phase` and treats `Degraded` as a failed
sync, which fires `deploy-failed`.

### Notifications don't fire
- `NOTIFICATION_PROVIDERS` empty in `.env` → re-bootstrap with at least
  one channel listed
- Check the provider config actually reached the cluster with
  `kubectl -n outpost-ci describe secret notify-secrets` — it lists key
  names and byte counts only. Do **not** use `-o jsonpath='{.data}'` or
  `-o yaml` here; those print the base64 values straight into your
  terminal and shell history
- Build failures notify from the **runner**, not the cluster: that path
  reads `.env` directly via `notify-fanout.sh --env-file`
- DingTalk / Feishu signed webhooks: host clock skew breaks the HMAC
  signature — keep the system clock in sync

## Network / Cloudflare

### Domain doesn't resolve
```bash
dig registry.<root>
```
Should return Cloudflare IPs. NXDOMAIN = NS not switched, or Public
Hostname not configured.

### Domain resolves but 502 / 521 / 522 / 524
- 502: backend service down (Traefik, or the app behind it)
- 521 / 522 / 524: cloudflared can't reach origin → check the container is
  up, `docker logs cloudflared`, and that Traefik still holds NodePort 30080

### Everything was fine, then the whole domain went dark
On WSL2, the distro stopping takes cloudflared, k3s, and the runner with
it. Check the Windows autostart task and `/tmp/outpost-autostart.log`
(see `03-windows-autostart.md`). `outpost-verify.timer` has
`Persistent=true`, so it fires a catch-up `verify.sh` once the distro is
back — that's where the alert comes from.

## Dead-man switch not reporting

```bash
systemctl status outpost-verify.timer
systemctl list-timers outpost-verify.timer
journalctl -u outpost-verify.service -n 100
```
It runs `verify.sh --quiet` every 30 minutes (5 minutes after boot) and
fans FAILs out through `notify-fanout.sh`. It lives on the host, outside
both the cluster and GitHub, on purpose — if it's disabled, you're back to
finding outages by hand. macOS has no systemd; schedule
`platform/systemd/outpost-verify-run.sh` from a LaunchAgent instead.

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

For a whole-host rebuild (new WSL2 box, distro wipe), follow
`../../../docs/prp/runbooks/wsl2-redeploy-0.3.md` instead — it covers the
data snapshot steps that `reset.sh` does not.
