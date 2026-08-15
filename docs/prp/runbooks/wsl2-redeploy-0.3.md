# WSL2 redeploy runbook — v0.3.0 (CI/CD engine swap + data-in-k3s)

> Supersedes [`wsl-wipe-rebootstrap.md`](wsl-wipe-rebootstrap.md) (deprecated,
> kept for historical record). Use this runbook for any full WSL2
> rebuild from v0.3.1 onward — the CI engine (GitHub Actions self-hosted
> runner + manifest-sync CronJob) is structurally different from what the
> old runbook describes; the data layer stays in host Compose (v0.3.0's
> in-cluster move was reverted before shipping). See
> [ADR-0003](../../decisions/0003-github-actions-engine-swap.md) and
> [ADR-0005](../../decisions/0005-data-layer-back-to-host.md) for the "why".

Applies to: accepting a full WSL2 distro wipe and rebuilding Outpost from
zero on a fresh install, OR standing up a brand-new WSL2 box as a
replacement for an existing one.

---

## 0. Old-box data snapshot (before touching anything)

Only things that are genuinely **not reconstructible** need to leave the
old box. Everything else (cluster state, images, manifests) is rebuilt by
`bootstrap.sh` + a normal push.

```bash
cd ~/outpost   # the infras clone on the OLD box
mkdir -p ~/outpost-carry

# 1. .env — every password/config (gitignored, never in git history)
cp .env ~/outpost-carry/.env

# 2. secrets-backup/ — the sealed-secrets master keypair (gitignored).
#    Without it, EVERY SealedSecret in every manifest repo is permanently
#    undecryptable — you'd have to re-seal every app's secrets by hand.
cp -r secrets-backup ~/outpost-carry/secrets-backup

# 3. Postgres — full logical dump. The data layer runs in host Compose
#    (true on the old box AND in v0.3.1's target shape — ADR-0005 reverted
#    the brief v0.3.0 in-cluster move) — use docker. The single-quoted
#    sh -c makes $POSTGRES_USER expand INSIDE the container (no .env
#    sourcing needed on the host, no secret on the host command line):
docker exec postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' \
  > ~/outpost-carry/pg-all-$(date +%F).sql

# 4. RabbitMQ — definitions export (queues/exchanges/bindings/users, not
#    message bodies — in-flight messages are not durable across this move).
docker exec rabbitmq rabbitmqctl export_definitions /tmp/definitions.json
docker cp rabbitmq:/tmp/definitions.json \
  ~/outpost-carry/rabbitmq-definitions-$(date +%F).json

# 5. Manticore — standalone mode has no built-in snapshot/export command;
#    it is treated as a rebuildable search index in this runbook (re-index
#    from Postgres/source-of-truth after redeploy). If you have a real
#    index you cannot rebuild, stop the container and archive the
#    manticore_data Compose volume (docker volume inspect
#    infra_manticore_data for the mountpoint) before wiping.

tar czf ~/outpost-carry.tgz -C ~/outpost-carry .
# Copy outpost-carry.tgz off the box (scp / a shared drive / etc.)
```

**PASS/FAIL for this step:** `tar tzf ~/outpost-carry.tgz` lists `.env`,
`secrets-backup/`, a non-empty `pg-all-*.sql`, and a non-empty
`rabbitmq-definitions-*.json`. Any missing/empty file = FAIL, stop and
retry that step before wiping the old box.

---

## 1. GitHub org setup (new in v0.3.0 — CI trigger surface)

CI runs on a GitHub Actions self-hosted runner, so every app repo needs a
github copy even if gitee stays the primary push target.

1. Create (or confirm) a GitHub org (or use a personal account) to host
   the runner and every app repo's github mirror.
2. For each app repo currently only on gitee, create a matching empty
   repo under the org on github.
3. Wire the sync — pick ONE per repo:
   - **Dual-push (recommended):**
     ```bash
     git remote set-url --add --push origin https://gitee.com/<org>/<repo>.git
     git remote set-url --add --push origin https://github.com/<org>/<repo>.git
     git push origin main   # fires both remotes; failures are visible immediately
     ```
   - **gitee official one-way push-mirror** (gitee → github only):
     configure under the gitee repo's Management → Push mirror settings.
     **Never enable the bidirectional mirror** — gitee's own docs warn of
     a ~30-minute cross-push race window that can silently lose commits.
4. Mint `GITHUB_RUNNER_PAT` — a PAT scoped to `admin:org` (org-level
   runner) or repo-admin (single-repo runner), used ONLY to mint runner
   *registration* tokens. Revoke/rotate it after the runner registers
   successfully (§4) — it is not needed for day-to-day operation.

**PASS/FAIL:** for each app repo, `git ls-remote https://github.com/<org>/<repo>.git`
returns the same HEAD sha as `git ls-remote https://gitee.com/<org>/<repo>.git`.
Mismatch = FAIL, fix the mirror/dual-push before proceeding.

---

## 2. New WSL2 preflight

```powershell
# Windows PowerShell, if this is a genuinely fresh WSL2 distro
wsl --shutdown
wsl --unregister <distro-name>     # e.g. Ubuntu — ONLY if truly starting fresh
# Reinstall the distro, confirm systemd is enabled (default on modern Ubuntu)
```

```bash
# Inside the new WSL2
git clone https://github.com/smithyhaus/outpost.git ~/outpost && cd ~/outpost
bash scripts/wsl2-migrate-preflight.sh
```

`wsl2-migrate-preflight.sh` probes systemd readiness, WSL network mode
(mirrored/NAT), reads the Windows registry for the system proxy port, live-
tests `install.sh`'s real URL to pick a working egress path (direct or
v2ray proxy), and writes the docker/k3s/apt proxy drop-ins accordingly.
Read-only by default — it does not touch secrets or the old box.

Also run the general preflight:

```bash
bash doctor.sh --egress
```

**PASS/FAIL:** `wsl2-migrate-preflight.sh` prints a GO/NO-GO verdict at the
end — must be GO. `doctor.sh --egress` (default host set: `gitee.com`,
`github.com`, `api.github.com`, `m.daocloud.io`) must show no FAIL —
`api.github.com` reachability is new-in-v0.3.0-critical (the runner's
entire CI trigger path depends on it).

---

## 3. `.env` fill

```bash
tar xzf ~/outpost-carry.tgz -C ~/outpost-carry
cp ~/outpost-carry/.env .env
cp -r ~/outpost-carry/secrets-backup .
```

Review and update these fields for the v0.3.0 shape — most are carried
over unchanged, but confirm/add:

```env
# CI trigger surface (new in v0.3.0)
GITHUB_RUNNER_URL=https://github.com/<org>
GITHUB_RUNNER_PAT=<the PAT minted in §1>
GITHUB_RUNNER_LABELS=outpost
GITHUB_RUNNER_NAME=                    # blank -> outpost-<hostname>

# Reconciliation basis (new in v0.3.0 — replaces WEBHOOK_REPO_WHITELIST)
OUTPOST_REPOS=https://gitee.com/<org>/<repo-a>.git,https://gitee.com/<org>/<repo-b>.git

# CD tuning (new in v0.3.0, safe to keep defaults)
MANIFEST_SYNC_INTERVAL=2
OUTPOST_STALENESS_THRESHOLD=1800
OUTPOST_REGISTRY_KEEP_TAGS=10
ROLLOUT_PLUGIN=none                    # or argo-rollouts if you use canary
```

**Remove these vars if carried over from an old `.env`** — they no
longer exist and `bootstrap.sh` will not use them:
`GIT_WEBHOOK_SECRET`, `WEBHOOK_REPO_WHITELIST`, `ROLLOUTS_DASHBOARD_HOST`,
`HOOKS_HOST`, `OUTPOST_DASHBOARD_USER`, `OUTPOST_DASHBOARD_PASSWORD`,
`ARGOCD_ADMIN_PASSWORD`.

```bash
sed -i '/^GIT_WEBHOOK_SECRET=/d; /^WEBHOOK_REPO_WHITELIST=/d; /^ROLLOUTS_DASHBOARD_HOST=/d; /^HOOKS_HOST=/d; /^OUTPOST_DASHBOARD_USER=/d; /^OUTPOST_DASHBOARD_PASSWORD=/d; /^ARGOCD_ADMIN_PASSWORD=/d' .env
```

**PASS/FAIL:** `grep -c '^OUTPOST_REPOS=\|^GITHUB_RUNNER_URL=\|^GITHUB_RUNNER_PAT='  .env`
returns `3` (all three present and non-empty). Any removed var still
present = WARN (harmless — bootstrap ignores unknown vars — but clean it
up).

---

## 4. Bootstrap

```bash
bash bootstrap.sh
```

Phase 8 (`bootstrap.d/08-ci.sh`) installs buildkitd, the `03-ci/`
RBAC/PVC/NodePorts, the `manifest-sync` CronJob, and — if
`GITHUB_RUNNER_PAT` is set — registers the GitHub Actions runner as a
systemd service. Empty PAT = loud WARN + runner skipped (a legitimate
CI/e2e-mode shape, not an error, but wrong for a real redeploy).

**PASS/FAIL:**
```bash
systemctl status 'actions.runner.*'    # active (running)
sudo systemctl status outpost-verify.timer   # active (waiting)
```
Both must show `active`. If the runner service is missing, check
`GITHUB_RUNNER_PAT` scope and re-run `bash bootstrap.sh`.

---

## 5. Data restore + row-count spot-check

```bash
# Postgres — restore the dump into the fresh Compose container
docker exec -i postgres sh -c 'psql -U "$POSTGRES_USER"' \
  < ~/outpost-carry/pg-all-*.sql

# RabbitMQ — replay definitions (queues/exchanges/bindings/users)
docker cp ~/outpost-carry/rabbitmq-definitions-*.json \
  rabbitmq:/tmp/definitions.json
docker exec rabbitmq rabbitmqctl import_definitions /tmp/definitions.json
```

**PASS/FAIL — row-count spot-check** (pick 2-3 tables you know the
approximate old-box row count for):

```bash
docker exec postgres sh -c \
  'psql -U "$POSTGRES_USER" -c "SELECT count(*) FROM <known_table>;"'
```
Count within expected range = PASS. Zero or wildly off = FAIL — check the
dump file wasn't truncated/empty (§0's PASS/FAIL check should have caught
this, but verify again post-restore).

---

## 6. `publish-hy-to-verdaccio`

```bash
bash scripts/publish-hy-to-verdaccio.sh
```

Verdaccio starts empty on the new box — this repopulates the private
`@hy/*` npm package registry every app depends on.

**PASS/FAIL:**
```bash
curl -s http://localhost:<verdaccio-port>/@hy%2f<any-known-package> | jq .name
```
Returns the package name = PASS. 404 = FAIL, re-run the publish script and
check its output for errors.

---

## 7. First sync observation

Onboard each app repo (this also registers `OUTPOST_REPOS` if not already
done manually in §3):

```bash
outpost onboard https://gitee.com/<org>/<repo>.git
```

Confirm the workflow file is committed in each app repo
(`.github/workflows/outpost-build.yml`), then trigger one real build per
repo (a trivial commit is enough) and watch it land:

```bash
outpost status              # sync-heartbeat: last_sync_ts / applied_head / last_result
outpost logs sync
kubectl get pods -n apps
```

**PASS/FAIL:** every onboarded app has a Running pod in `apps` with the
just-built image tag within `MANIFEST_SYNC_INTERVAL` × 2 minutes of the
push. `outpost status`'s `last_result` reads `ok`, not `error:...`.

---

## 8. Cloudflare dashboard route cleanup

The v0.3.0 ingress surface drops several routes:

1. **Delete** any `hooks.<domain>` Public Hostname — no inbound webhook
   endpoint exists anymore.
2. **Delete** `argocd.<domain>`, `tekton.<domain>`,
   `<rollouts-dashboard-host>.<domain>` Public Hostnames if they exist
   from a pre-v0.3.0 install — those dashboards are removed.
3. **Confirm** `mq.<domain>` and `search.<domain>` target `http://caddy:80`
   — the v0.2 shape is BACK in v0.3.1 (ADR-0005): the data services are
   Compose containers again and caddy's `@search`/`@mq` routes proxy to
   them. A pre-existing route already pointing at caddy is correct; one
   changed to `:30080` during a brief v0.3.0 window must be pointed back.
   Double-check `curl -sS -o /dev/null -w '%{http_code}\n' https://mq.<domain>`
   returns `200`, not a 404.
4. **Confirm/restore** the raw-TCP Public Hostnames if you use remote TCP
   access: `pg.<domain>` → `tcp://postgres:5432`, `redis.<domain>` →
   `tcp://redis:6379`, `rabbitmq.<domain>` → `tcp://rabbitmq:5672`.
   These need QUIC transport — with `CF_TUNNEL_PROTOCOL=http2` the
   `cloudflared access` TCP path is unavailable (documented trade-off).

**PASS/FAIL:**
```bash
curl -sS -o /dev/null -w "%{http_code}\n" "https://hooks.${ROOT_DOMAIN}"
# expect: connection failure / no route (hooks route deleted)
curl -sS -o /dev/null -w "%{http_code}\n" "https://mq.${ROOT_DOMAIN}"
curl -sS -o /dev/null -w "%{http_code}\n" "https://search.${ROOT_DOMAIN}"
# expect: 200 for both
```

---

## 9. Acceptance gauntlet

### 9.1 Dual-provider empty-commit end-to-end

```bash
cd <any onboarded app repo>
git commit --allow-empty -m "test: v0.3.0 acceptance — dual provider e2e"
git push   # fires both gitee and github with dual-push
```

**PASS:** within a couple minutes, GitHub Actions UI shows a green run,
the manifest repo gets a new `chore(<app>): bump image to <sha>` commit,
and `outpost logs sync` shows it applied. **FAIL** any link in that chain
→ diagnose with `bash verify.sh --json` (the `ci.*` and `reconcile.*`
checks name exactly which link broke).

### 9.2 Dead-man switch (verify anti-silence actually fires)

```bash
kubectl -n outpost-ci patch cronjob manifest-sync -p '{"spec":{"suspend":true}}'
# Wait past OUTPOST_STALENESS_THRESHOLD + one outpost-verify.timer cycle
# (default: 1800s + up to 30min — budget ~35-40 min, or temporarily lower
# OUTPOST_STALENESS_THRESHOLD in .env for a faster drill, then bootstrap again)
```

**PASS:** a `verify-failed` notification arrives via
`scripts/notify-fanout.sh` on your configured `NOTIFICATION_PROVIDERS`
channel, and `bash verify.sh --json` shows `sync.heartbeat` as FAIL
("STALE"). **FAIL** if nothing fires — check
`platform/systemd/outpost-verify.timer` is `active`, and that
`NOTIFICATION_PROVIDERS` is actually configured in `.env`.

Resume:

```bash
kubectl -n outpost-ci patch cronjob manifest-sync -p '{"spec":{"suspend":false}}'
```

**PASS:** next `outpost status` shows `last_sync_ts` advancing again and
`last_result=ok`.

### 9.3 Rollback drill

```bash
outpost rollback <app>          # lists available tags
outpost rollback <app> <sha>    # rewrites the manifest to a known-good sha
```

**PASS:** `outpost logs sync` shows the rollback commit applied within
`MANIFEST_SYNC_INTERVAL`, and `kubectl get deploy -n apps <app> -o
jsonpath='{.spec.template.spec.containers[0].image}'` shows the rolled-
back tag. This must work with the GitHub Actions runner stopped
(`sudo systemctl stop 'actions.runner.*'`) — the rollback path is fully
domestic (gitee + local cluster) by design; **FAIL** if it doesn't work
with the runner down. Restart the runner afterward:
`sudo systemctl start 'actions.runner.*'`.

### 9.4 WSL reboot retest (self-heal check)

```powershell
wsl --shutdown
```
Then reopen the WSL2 terminal (auto-starts the distro).

**PASS/FAIL, check each independently:**
```bash
systemctl is-active 'actions.runner.*'     # expect: active
systemctl is-active outpost-verify.timer   # expect: active
docker inspect -f '{{.State.Health.Status}}' postgres redis rabbitmq manticore
                                           # expect: healthy ×4 (compose restart policy)
bash verify.sh --json | jq '.summary'      # expect: fail_count == 0 — this includes
                                           # data.bridge_dns (coredns entry vs the NEW
                                           # node IP) and data.bridge_reconciler
```
Any non-active/non-healthy/non-zero result = FAIL. The WSL restart is
exactly when the bridge IP drifts — the coredns-hosts-reconciler CronJob
must rewrite the entry within ~2min of the cluster coming back; if
`data.bridge_dns` still FAILs after a few minutes, the reconciler is the
thing to debug (`kubectl -n kube-system get cronjob,jobs | grep coredns`).

---

## 10. Old-box retention

Keep the old box (or at minimum `~/outpost-carry.tgz` and a snapshot of
the old cluster's `secrets-backup/`) for **30 days** after cutover, in
case a data-restore gap surfaces (a table that wasn't in the row-count
spot-check, a RabbitMQ queue whose definitions didn't round-trip, etc.).
After 30 days of the new box running clean (no FAIL in the daily
`outpost-verify.timer` run), the old box may be decommissioned.
