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
bash verify.sh --quiet   # summary only
```

**Exit code semantics:**
- `0` — all PASS
- `1` — at least one FAIL (action needed)
- `2` — only WARN (observe / next-pass)

**JSON output shape:**

```json
{
  "schema_version": "1",
  "summary": {"pass": 28, "warn": 2, "fail": 0, "os": "linux"},
  "checks": [
    {"status": "PASS", "id": "tool.docker", "detail": "found at /usr/bin/docker"},
    {"status": "WARN", "id": "edge.skipped", "detail": "ROOT_DOMAIN unset, …"}
  ]
}
```

The schema is locked at `tests/schema/verify-output.schema.json`. Field
shape is stable across versions; `schema_version` will bump on a breaking
change.

**Recommended AI agent workflow:**

1. `bash verify.sh --json`
2. Parse the JSON
3. If `summary.fail > 0` → for each FAIL check, jump to §1 below to
   diagnose
4. If `summary.warn > 0` → list the WARN ids and brief implication
5. Otherwise → "stack is healthy"
6. Output a short structured report; do not flood the user with PASS detail

## 1. Per-check diagnosis

Each check id maps to a diagnosis path. ids follow `<area>.<subject>`.

### `tool.<name>`

| id            | Recovery                                                |
|---------------|---------------------------------------------------------|
| `tool.docker` | Install Docker (Desktop on macOS; convenience script Linux) |
| `tool.kubectl`| `sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl` |
| `tool.helm`   | `curl get-helm-3 \| bash`                              |

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
If absent: token is wrong or expired (.env), or DNS to api.cloudflare.com
is broken.

### `k8s.nodes`
```bash
kubectl get nodes
kubectl describe node $(kubectl get node -o jsonpath='{.items[0].metadata.name}')
```

### `k8s.<ns>.<deploy>`
```bash
kubectl describe deploy -n <ns> <deploy>
kubectl get pods -n <ns> -l app=<deploy>
kubectl logs -n <ns> -l app=<deploy> --tail 200
```

### `k8s.no_crashloop`
The check id will include the offender. Then:
```bash
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> -p          # previous run
```

### `bridge.<service>`
```bash
kubectl get svc -n infra-bridges <service> -o yaml
# Test from inside cluster:
kubectl run -it --rm probe --image=alpine --restart=Never -- \
  sh -c "apk add busybox-extras >/dev/null && nc -zv <service>.infra-bridges.svc.cluster.local <port>"
```

### `argocd.app.<name>`
```bash
kubectl get app -n argocd <name> -o yaml | yq '.status'
```
Common: `ComparisonError` → manifest yaml invalid or repo unreachable;
`OutOfSync` → ArgoCD UI → click SYNC, or fix the manifest divergence.

### `tekton.eventlistener`
```bash
kubectl logs -n tekton-pipelines deploy/el-<provider>-listener --tail 200
```

### `tekton.run.<name>`
```bash
kubectl describe pipelinerun -n tekton-pipelines <name>
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<name> \
  --all-containers --tail=200 --prefix
```

### `edge.<sub>`
- `000` — DNS doesn't resolve to Cloudflare, or browser refused (CORS)
- `502/503/504` — origin (your stack) is down
- `4xx` — usually OK for a probe (login required, hooks reject GET, etc.)

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
   ├── any FAIL? ────────────────────────────────────┐
   │                                                  │
   │  iterate by area:                                │
   │  · tool.* / docker.* / kubectl.* → install/start │
   │  · compose.* / cloudflared.*     → §1            │
   │  · k8s.*                         → §1            │
   │  · bridge.*                      → §1            │
   │  · argocd.* / tekton.* / edge.*  → §1            │
   │                                                  │
   │  resolve, then re-run verify.sh --json           │
   │                                                  │
   └── only WARN? → list and continue                 │
                                                      │
   all PASS? ─────────────────────────────────────────┘
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
6. Never delete the namespaces argocd, tekton-pipelines, infra-bridges, registry, kube-system.
```

## 4. Post-modification verification

When an agent changes config:

```bash
kubectl apply -f <changed.yaml>     # or compose, or platform script
sleep 20                            # let reconcile finish
bash verify.sh --json | jq '.checks[] | select(.status != "PASS")'
```

If the only new non-PASS items are expected (e.g. an Application
becomes briefly OutOfSync after a manifest edit), proceed. Otherwise
roll back and ask the user.

## 5. Known limitations of `verify.sh`

verify.sh does NOT check:

- application-level business logic (apps should expose their own /healthz)
- sealed-secrets crypto correctness (only checks the controller pod)
- real webhook delivery (only checks the endpoint is reachable)
- TLS cert expiry (Cloudflare manages it)
- disk space (host-level concern)

For these, run targeted commands or escalate to the user.
