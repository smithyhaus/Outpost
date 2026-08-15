# 07 — AI verification playbook

> Written for AI agents (Claude, Cursor, Cline, Aider, Copilot Workspace,
> etc.). Pair this with [`SKILL.md`](../../../SKILL.md) at the project root.

When an AI agent enters an `outpost` checkout, the standard onboarding is:

1. Read `SKILL.md` (project orientation, invariants, file pointers)
2. Read this file (verification operations + diagnosis playbook)
3. Run `bash verify.sh --json` and reason from the structured output

## 0. One-shot verification

```bash
bash verify.sh           # human-friendly, coloured
bash verify.sh --json    # AI-friendly (recommended for agents)
bash verify.sh --quiet   # summary only (what the systemd timer runs)
```

**Exit code semantics:**
- `0` — all PASS
- `1` — at least one FAIL (action needed)
- `2` — only WARN (observe / next-pass)

**JSON output shape:**

```json
{
  "schema_version": "1",
  "summary": {"pass": 28, "warn": 2, "fail": 0, "os": "linux", "mode": "full"},
  "checks": [
    {"status": "PASS", "id": "tool.docker", "detail": "found at /usr/bin/docker"},
    {"status": "WARN", "id": "edge.skipped", "detail": "ROOT_DOMAIN unset"}
  ]
}
```

The schema is locked at `tests/schema/verify-output.schema.json`. Field
shape is stable across versions; `schema_version` will bump on a breaking
change.

**Sections, in the order verify.sh emits them:** tooling → Compose →
K8s core → CI trigger → CD → reconciliation → data layer → public
ingress → credentials hygiene. Sections 3–8 are skipped entirely in
`local` mode.

**Recommended AI agent workflow:**

1. `bash verify.sh --json`
2. Parse the JSON
3. If `summary.fail > 0` → for each FAIL check, jump to §1 below to
   diagnose
4. If `summary.warn > 0` → list the WARN ids and brief implication
5. Otherwise → "stack is healthy"
6. Output a short structured report; do not flood the user with PASS detail

> **Read `reconcile.*` first when several things are red.** It is the only
> check that judges the whole push→build→deploy chain from outside, so a
> FAIL there usually explains the others rather than being a separate
> problem.

## 1. Per-check diagnosis

Each check id maps to a diagnosis path. ids follow `<area>.<subject>`.

### `tool.<name>`

Probed set: `docker openssl envsubst curl` in `local` mode, plus
`kubectl helm git` in `full` mode.

| id             | Recovery                                                    |
|----------------|-------------------------------------------------------------|
| `tool.docker`  | Install Docker (Desktop on macOS; convenience script Linux)  |
| `tool.kubectl` | `sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl`      |
| `tool.helm`    | `curl get-helm-3 \| bash`                                    |
| `tool.envsubst`| Install `gettext` / `gettext-base` — templates won't render  |
| `tool.git`     | Install git — without it reconciliation cannot run at all    |

> `yq` (mikefarah v4+) and `buildctl` are **not** in this probed set, but
> the runner host needs both — `scripts/ci/build-image.sh`,
> `run-tests.sh`, and `outpost rollback` all fail without them. A green
> `tool.*` section does not prove the build host is complete.

### `docker.daemon`
```bash
sudo service docker start    # Linux/WSL2
open -a Docker               # macOS
```

### `kubectl.cluster`
```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 200
```

### `compose.<service>`

`full` mode expects `cloudflared` + `caddy` only; `local` mode expects the
four data services.

```bash
docker compose -f core/compose/docker-compose.yml ps
docker logs <service> --tail 100
docker inspect --format '{{json .State.Health}}' <service>
```

### `cloudflared.tunnel`
```bash
docker logs cloudflared --tail 100
```
Expect at least one line containing `Registered tunnel connection`.
If absent: token is wrong or expired (`.env`), DNS to api.cloudflare.com
is broken, or QUIC (UDP/7844) is blocked — try `CF_TUNNEL_PROTOCOL=http2`.

### `k8s.nodes`
```bash
kubectl get nodes
kubectl describe node $(kubectl get node -o jsonpath='{.items[0].metadata.name}')
```

### `k8s.<ns>.<deploy>` / `k8s.<ns>.<name>` / `k8s.no_crashloop`
```bash
kubectl describe deploy -n <ns> <deploy>
kubectl get pods -n <ns> -l app=<deploy>
kubectl logs -n <ns> -l app=<deploy> --tail 200
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> -p          # previous run
```
`k8s.<ns>.<name>` WARN means a plugin-provided object is missing — re-run
bootstrap if you expected that plugin to be enabled.

### `buildkit.daemon` — FAIL means every build will fail
```bash
kubectl -n buildkit get pods
kubectl -n buildkit logs deploy/buildkitd --tail 200
```
The startupProbe tolerates ~6 minutes on a dirty-cache recovery, so treat
a FAIL immediately after a restart as "wait and re-check once".

### `ci.runner` / `ci.runner.unit` / `ci.runner.online`
```bash
systemctl status 'actions.runner.*'
journalctl -u 'actions.runner.*' -n 200
cd ~/actions-runner && sudo ./svc.sh status
```
- `ci.runner` WARN → `GITHUB_RUNNER_PAT` empty, runner never installed.
  **No build can trigger.** Only legitimate for this repo's own CI/e2e
- `ci.runner.unit` FAIL → the systemd service is not running. Pushes queue
  on GitHub instead of failing, so nothing else looks wrong
- `ci.runner.online` FAIL → GitHub reports no online runner, or
  api.github.com was unreachable (proxy/egress, or the PAT lost its scope)

### `ci.workflow.<app>`
Queries the app repo's most recent workflow run through the GitHub API.
- WARN `no workflow runs yet` → the repo lacks
  `.github/workflows/outpost-build.yml`
- FAIL `last run: failure` → read the run in the GitHub Actions UI

### `sync.cronjob` / `sync.heartbeat` / `sync.result`
```bash
kubectl -n outpost-ci get cronjob manifest-sync
kubectl -n outpost-ci get cm sync-heartbeat -o yaml
kubectl -n outpost-ci get jobs
bash scripts/outpost logs sync
```
- `sync.cronjob` FAIL → nothing deploys; re-run bootstrap
- `sync.heartbeat` FAIL → heartbeat older than 3× `MANIFEST_SYNC_INTERVAL`;
  sync stopped running. A wedged job blocks later ticks
  (`concurrencyPolicy: Forbid`) — delete it
- `sync.result` FAIL → the last run errored; `last_result` is
  self-describing (`error:git-clone`, `error:git-fetch`,
  `error:unexpected-rc=<n>`, …)

### `reconcile.<app>` — the ultimate judge
The repo's live branch head has not become a deployed image tag within
`OUTPOST_STALENESS_THRESHOLD` (default 1800s). This one check covers a
dead gitee→github mirror, GitHub being unreachable, an offline runner, a
red workflow, a dead buildkitd, and a stalled sync — all of which surface
as exactly this symptom. Diagnose in chain order:

```bash
git ls-remote <github-url> refs/heads/main   # 1. did the push mirror?
systemctl status 'actions.runner.*'          # 2. is the runner alive?
# 3. GitHub Actions UI → did the workflow go red?
# 4. manifest repo → is there a `chore(<app>): bump image to <sha>` commit?
bash scripts/outpost status                  # 5. is sync fresh and ok?
```

Related ids: `reconcile.git` (git not installed), `reconcile.manifest`
(`MANIFEST_REPO_URL` unset), `reconcile.repos` (`OUTPOST_REPOS` empty —
the anti-silence layer is blind, onboard your apps).

### `data.<service>`
```bash
kubectl -n infra-bridges get pods
kubectl -n infra-bridges logs sts/<service> --tail 200
kubectl -n infra-bridges exec sts/postgres -- sh -c 'pg_isready -U "$POSTGRES_USER"'
```
These are real auth'd probes inside the pod, so a FAIL means the service
is down or rejecting credentials — not a networking guess.

### `edge.<sub>`
Only `edge.search` / `edge.mq` / `edge.registry` exist in v0.3 (the
ArgoCD / Tekton / hooks routes are gone).
- `000` — DNS doesn't resolve to Cloudflare, or no response
- `502/503/504` — origin (your stack) is down
- `4xx` — usually still PASS for a probe (a service that answers a bare
  GET with 401/403 proves the path is alive)

```bash
dig <sub>.<root>
curl -v https://<sub>.<root>
```

### `creds.env_perm` / `creds.env` / `creds.infra_md`
Recover by re-running bootstrap; `.env` permissions are set to 600
automatically.

## 2. Decision tree

```
verify.sh --json
   │
   ├── any FAIL? ─────────────────────────────────────────┐
   │                                                       │
   │  check reconcile.* FIRST — it explains most chains    │
   │  then iterate by area:                                │
   │  · tool.* / docker.* / kubectl.*  → install/start     │
   │  · compose.* / cloudflared.*      → §1                │
   │  · k8s.* / buildkit.*             → §1                │
   │  · ci.*    (build half)           → §1                │
   │  · sync.*  (deploy half)          → §1                │
   │  · data.* / edge.*                → §1                │
   │                                                       │
   │  resolve, then re-run verify.sh --json                │
   │                                                       │
   └── only WARN? → list and continue                      │
                                                           │
   all PASS? ──────────────────────────────────────────────┘
       └── report "infrastructure is healthy"
```

## 3. AI agent system instructions snippet

Drop this into a system prompt or skill activation message:

```
You are operating in an Outpost checkout.
1. Read SKILL.md and i18n/en/docs/07-ai-verification.md before any action.
2. To assess health: bash verify.sh --json. Parse the JSON.
3. To answer connection-string questions, read INFRA.md, never synthesize.
4. Modifying state: read existing files, show a diff, get user approval, apply, then re-run verify.sh on the affected section.
5. Never run reset.sh unless the user said "reset" or "wipe".
6. Never delete the namespaces infra-bridges, outpost-ci, buildkit, registry, kube-system.
7. Never kubectl apply into the `apps` namespace — the manifest repo is its enforced source of truth. Edit the manifest repo and let manifest-sync converge.
8. Never echo secrets: .env values, tokens, GITHUB_RUNNER_PAT, or the contents of any Secret.
```

## 4. Post-modification verification

When an agent changes config:

```bash
kubectl apply -f <changed.yaml>     # or compose, or platform script
sleep 20                            # let reconcile finish
bash verify.sh --json | jq '.checks[] | select(.status != "PASS")'
```

For a change that lands through the manifest repo, wait one
`MANIFEST_SYNC_INTERVAL` (default 2 min) — or force it:

```bash
kubectl -n outpost-ci create job manifest-sync-now --from=cronjob/manifest-sync
bash scripts/outpost logs sync
```

If the only new non-PASS items are expected (e.g. `reconcile.<app>`
briefly lagging while a build is still running), proceed. Otherwise roll
back and ask the user.

## 5. Known limitations of `verify.sh`

verify.sh does NOT check:

- application-level business logic (apps should expose their own /healthz)
- sealed-secrets crypto correctness (only checks the controller pod)
- whether a build is *correct* — only that its last run was green and that
  live HEAD eventually became a deployed tag
- TLS cert expiry (Cloudflare manages it)
- disk space (host-level concern)

It also cannot see anything about a repo missing from `OUTPOST_REPOS`.
That list is the reconciliation basis; an unregistered app is invisible to
the anti-silence layer even though it otherwise builds and deploys fine.

For these, run targeted commands or escalate to the user.
