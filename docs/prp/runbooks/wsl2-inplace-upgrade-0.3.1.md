# WSL2 in-place upgrade runbook — v0.2 → v0.3.1

> Sibling of [`wsl2-redeploy-0.3.md`](wsl2-redeploy-0.3.md), which rebuilds
> a box from zero. **This one keeps the box.** Use it when the machine is
> already healthy at the data layer and you only need the engine swap
> (Tekton + ArgoCD → GitHub Actions runner + `manifest-sync`).

## Which runbook do I want?

Run this first:

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'postgres|redis|rabbitmq|manticore'
```

| What you see | Use |
|---|---|
| The four data containers exist and are `healthy` | **This runbook** (in-place) |
| Data containers missing/corrupt, or the distro is unbootable | [`wsl2-redeploy-0.3.md`](wsl2-redeploy-0.3.md) (full wipe) |

Why in-place is usually right: v0.3.1's data layer **is** host Compose
([ADR-0005](../../decisions/0005-data-layer-back-to-host.md)), so a v0.2
box already has the target shape. `bootstrap.d/08-ci.sh` deletes the
`argocd` and `tekton-pipelines` namespaces itself, so the retired engines
are cleaned up for you. Staying in place also keeps the in-cluster
registry populated — a wipe costs you a full rebuild of every app image
before anything can start.

**What you skip versus the wipe runbook, and why:**

| Wipe-runbook step | Skipped here because |
|---|---|
| §0 full data snapshot | The volumes are never touched. Take the cheap insurance backup in §1 anyway. |
| §2 fresh-distro preflight | The distro stays. |
| §5 data restore | Nothing was dropped. |
| §6 `publish-hy-to-verdaccio` | Verdaccio keeps its storage. |

---

## 1. Cheap insurance (5 min, do it anyway)

Nothing below deletes data, but `.env` is about to be edited and the
sealed-secrets master key is irreplaceable.

```bash
cd ~/outpost
mkdir -p ~/outpost-carry
cp .env ~/outpost-carry/.env
cp -r secrets-backup ~/outpost-carry/secrets-backup
# Single-quoted sh -c makes $POSTGRES_USER expand INSIDE the container,
# so no credential lands on the host command line or in shell history.
docker exec postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' \
  > ~/outpost-carry/pg-$(date +%F).sql
```

**PASS/FAIL:** `ls -la ~/outpost-carry/` shows a non-empty `.env`, a
`secrets-backup/` directory, and a `pg-*.sql` larger than a few KB. An
empty dump is a FAIL — stop and fix it before editing anything.

> Never run `reset.sh` during this procedure. It belongs to the wipe path
> and destroys the data volumes in both modes.

---

## 2. GitHub side (the new CI trigger surface)

CI is a GitHub Actions self-hosted runner, so every app repo needs a
GitHub copy even though gitee stays the primary push target.

1. Create or pick a GitHub org to host the runner and the app mirrors.
2. For each app repo, create a matching empty repo under that org.
3. Wire the sync — **dual-push is recommended** because failures are
   immediately visible:
   ```bash
   git remote set-url --add --push origin https://gitee.com/<org>/<repo>.git
   git remote set-url --add --push origin https://github.com/<org>/<repo>.git
   git push origin main
   ```
   The gitee one-way push-mirror also works. **Never** enable gitee's
   bidirectional mirror — its own docs warn of a ~30-minute cross-push
   race that can silently lose commits.
4. Mint `GITHUB_RUNNER_PAT` with `admin:org` scope. It is used **only** to
   mint runner registration tokens; revoke it once §5 succeeds.

**PASS/FAIL:** for every app repo,
`git ls-remote https://github.com/<org>/<repo>.git` and
`git ls-remote https://gitee.com/<org>/<repo>.git` report the same HEAD.

---

## 3. Pull v0.3.1

```bash
cd ~/outpost
git pull
cat VERSION            # expect 0.3.1
```

This also brings the caddy fix: `core/compose/Caddyfile` used to ship
`admin off` while the compose healthcheck probed the admin API on
`127.0.0.1:2019`, so caddy could never report healthy — and
`bootstrap.d/04-compose.sh` hard-gates on health, so bootstrap aborted at
Phase 4. Recreate caddy now rather than discovering that mid-run:

```bash
docker compose --env-file .env -f core/compose/docker-compose.yml \
  up -d --force-recreate caddy
docker ps --filter name=caddy --format '{{.Names}} {{.Status}}'
```

**PASS/FAIL:** caddy reports `(healthy)` within ~30s. Still unhealthy →
`docker inspect --format '{{json .State.Health}}' caddy` and read the last
probe output before continuing.

---

## 4. `.env` — add the new, delete the retired

Add:

```env
GITHUB_RUNNER_URL=https://github.com/<org>
GITHUB_RUNNER_PAT=<the PAT from §2>
GITHUB_RUNNER_LABELS=outpost
GITHUB_RUNNER_NAME=                    # blank -> outpost-<hostname>
OUTPOST_REPOS=                         # §6 fills this via `outpost onboard`
MANIFEST_SYNC_INTERVAL=2
OUTPOST_STALENESS_THRESHOLD=1800
OUTPOST_REGISTRY_KEEP_TAGS=10
ROLLOUT_PLUGIN=none
```

Delete the webhook-era variables — they no longer exist:

```bash
sed -i '/^GIT_WEBHOOK_SECRET=/d; /^WEBHOOK_REPO_WHITELIST=/d; /^ROLLOUTS_DASHBOARD_HOST=/d; /^HOOKS_HOST=/d; /^OUTPOST_DASHBOARD_USER=/d; /^OUTPOST_DASHBOARD_PASSWORD=/d; /^ARGOCD_ADMIN_PASSWORD=/d' .env
```

**PASS/FAIL:**
`grep -c '^GITHUB_RUNNER_URL=\|^GITHUB_RUNNER_PAT=' .env` returns `2`, and
`grep -c '^GIT_WEBHOOK_SECRET=\|^WEBHOOK_REPO_WHITELIST=' .env` returns `0`.

---

## 5. Bootstrap

```bash
bash bootstrap.sh
```

Idempotent. Phase 8 deletes the `argocd` / `tekton-pipelines` namespaces,
installs buildkitd + the `outpost-ci` RBAC/PVC/NodePorts + the
`manifest-sync` CronJob, registers the GitHub runner as a systemd service,
and blocks until the first sync writes a fresh heartbeat.

**PASS/FAIL:**
```bash
systemctl status 'actions.runner.*'          # active (running)
sudo systemctl status outpost-verify.timer   # active (waiting)
kubectl get ns | grep -E 'argocd|tekton'     # expect: no output
```

Runner missing → check the PAT's `admin:org` scope and re-run bootstrap.

---

## 6. Onboard each app repo

The only genuinely repetitive part. Per app, `outpost onboard` registers
the repo in `OUTPOST_REPOS` and drops
`.github/workflows/outpost-build.yml` into the app repo:

```bash
outpost onboard https://gitee.com/<org>/<repo>.git
```

Then commit and push that workflow file in each app repo (dual-push sends
it to both remotes).

**PASS/FAIL:** `grep '^OUTPOST_REPOS=' .env` lists every app, and each app
repo has `.github/workflows/outpost-build.yml` on its default branch. An
app missing from `OUTPOST_REPOS` is invisible to the anti-silence
reconciliation even though it otherwise builds and deploys fine — that
list is the entire basis of the `reconcile.<app>` check.

---

## 7. One real build, end to end

```bash
cd <any onboarded app repo>
git commit --allow-empty -m "test: v0.3.1 in-place upgrade e2e"
git push
```

Watch it land:

```bash
outpost status        # last_sync_ts advancing, last_result=ok
outpost logs sync
kubectl get pods -n apps
```

**PASS/FAIL:** GitHub Actions shows a green run; the manifest repo gains a
`chore(<app>): bump image to <sha>` commit; the pod in `apps` picks up the
new tag within ~2× `MANIFEST_SYNC_INTERVAL`. Any broken link →
`bash verify.sh --json` names it (`ci.*` for the build half, `sync.*` for
the deploy half, `reconcile.*` for the whole chain judged from outside).

---

## 8. Cloudflare route cleanup

1. **Delete** `hooks.<domain>` — no inbound webhook endpoint exists now.
2. **Delete** `argocd.<domain>`, `tekton.<domain>`, and the rollouts
   dashboard hostname.
3. **Confirm** `search.<domain>` and `mq.<domain>` target
   `http://caddy:80` (Caddy's `@search`/`@mq` proxy on to
   `manticore:9308` / `rabbitmq:15672`).
4. **Optional** raw-TCP rows need no host-side prep — point them straight
   at `tcp://postgres:5432`, `tcp://redis:6379`, `tcp://rabbitmq:5672`.
   They require QUIC, so they are unavailable while
   `CF_TUNNEL_PROTOCOL=http2`.

**PASS/FAIL:**
```bash
curl -sS -o /dev/null -w "%{http_code}\n" "https://mq.${ROOT_DOMAIN}"
curl -sS -o /dev/null -w "%{http_code}\n" "https://search.${ROOT_DOMAIN}"
```
Both must answer (200/401/403 all prove the path is alive). `530` with
`error code: 1033` means the box or its docker is down, not a route
problem — see §10.

---

## 9. Acceptance

```bash
bash verify.sh --json | jq '.summary'
```

**PASS/FAIL:** `fail == 0`. Pay particular attention to
`data.bridge_dns` and `data.bridge_reconciler` — they prove k3s pods can
still resolve the host data layer after the engine swap.

Two drills from the wipe runbook are still worth running here:
[§9.2 dead-man switch](wsl2-redeploy-0.3.md) (suspend `manifest-sync`,
confirm a `verify-failed` notification actually fires) and
[§9.3 rollback](wsl2-redeploy-0.3.md) (`outpost rollback <app> <sha>` must
work with the runner stopped).

---

## 10. Fix the recurring outage: closing the terminal kills everything

Closing the WSL terminal window stops the distro. cloudflared dies with
it, so **every** public hostname starts returning HTTP 530
`error code: 1033` and remote `kubectl` times out — with nothing at all
wrong inside the cluster. Reopening the window restarts the distro but
does not reliably restart the containers.

Set up autostart per
[`i18n/zh-CN/docs/03-windows-autostart.md`](../../../i18n/zh-CN/docs/03-windows-autostart.md)
(English: [`i18n/en/docs/03-windows-autostart.md`](../../../i18n/en/docs/03-windows-autostart.md)).

**PASS/FAIL:** close every WSL window, wait a minute, then from another
machine run
`curl -sk -o /dev/null -w '%{http_code}\n' https://search.<domain>/`.
Anything other than `530` means the stack survived. Re-check
`verify.sh --json` afterwards too — a WSL restart is exactly when the
bridge IP drifts, and `coredns-hosts-reconciler` should repair it within
~2 min.
