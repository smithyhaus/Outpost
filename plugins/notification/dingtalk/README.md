# notification / dingtalk

Sends Outpost CI/CD events to a DingTalk group robot.

## What gets installed

- `Secret/dingtalk-webhook` in `tekton-pipelines` — webhook URL + optional sign secret, read by the shared `outpost-notify` Task.
- `ConfigMap/dingtalk-template` in `tekton-pipelines` — the DingTalk markdown body template.
- A merge fragment into `argocd-notifications-cm` (services + per-event templates).
- A merge fragment into `argocd-notifications-secret` (the URL keys).

## How to enable

1. In your DingTalk group → **Group Settings → Bots → Add → Custom**. Pick **加签** (signed) for production safety.
2. Copy the webhook URL and (if signed) the sign secret.
3. In `.env`:
   ```
   NOTIFICATION_PROVIDERS=dingtalk         # add to comma list if more
   DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
   DINGTALK_SIGN_SECRET=SEC...             # optional but recommended
   ```
4. Re-run `bash bootstrap.sh`.

## What you'll see

| Event | Sample title |
|---|---|
| Tekton pipeline failed | `[error] my-app tekton.pipelinerun.failed` |
| ArgoCD sync failed | `[error] my-app sync failed` |
| ArgoCD app degraded | `[error] my-app degraded` |
| Rollouts auto-rolled back | `[error] my-app rolled back` |

## Caveats

- Without `DINGTALK_SIGN_SECRET`, anyone with the webhook URL can post into your group. Rotate if leaked.
- DingTalk rate-limits ≈ 20 messages per minute per bot. A storm-wide outage can drop messages.
- **Heads up:** DingTalk treats the message body as `application/json`; we wrap content in their `msgtype: markdown` envelope.
