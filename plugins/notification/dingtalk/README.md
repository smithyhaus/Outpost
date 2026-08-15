# notification / dingtalk

Sends Outpost CI/CD events to a DingTalk group robot.

## What gets installed

- `Secret/dingtalk-webhook` in `outpost-ci` — webhook URL + optional sign
  secret, volume-mounted by the manifest-sync CronJob so
  `scripts/notify-fanout.sh` finds it at `/secrets/dingtalk/webhook-url`.
- `ConfigMap/dingtalk-template` in `outpost-ci` — the DingTalk markdown body
  template, mounted at `/templates/dingtalk/body.tmpl`.

Host-run callers (the GitHub Actions workflow's `build-failed` step, and the
`verify.sh` systemd timer's `verify-failed` check) run outside the cluster —
they invoke `notify-fanout.sh --env-file $OUTPOST_ROOT/.env ...` instead of
relying on the volume mount.

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
| GitHub Actions workflow build failed | `[error] my-app build-failed` |
| manifest-sync deploy succeeded | `[ok] my-app deploy-succeeded` |
| manifest-sync deploy failed | `[error] my-app deploy-failed` |
| verify.sh reconciliation/liveness FAIL | `[error] my-app verify-failed` |

## Caveats

- Without `DINGTALK_SIGN_SECRET`, anyone with the webhook URL can post into your group. Rotate if leaked.
- DingTalk rate-limits ≈ 20 messages per minute per bot. A storm-wide outage can drop messages.
- **Heads up:** DingTalk treats the message body as `application/json`; we wrap content in their `msgtype: markdown` envelope.
