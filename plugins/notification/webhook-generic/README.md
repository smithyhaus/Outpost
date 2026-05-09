# notification / webhook-generic

Fallback channel: POSTs the raw normalized Outpost payload to your own collector — no vendor wrapper. Useful for self-hosted alertmanager bridges, custom relays, local debugging, or chaining to additional channels.

## What gets installed

- `Secret/generic-webhook` in `tekton-pipelines`.
- `ConfigMap/generic-template` in `tekton-pipelines`.
- Merge fragments into `argocd-notifications-cm` and `argocd-notifications-secret`.

## How to enable

```env
NOTIFICATION_PROVIDERS=webhook-generic       # comma-list if more
GENERIC_WEBHOOK_URL=https://your-collector.example.com/hook
GENERIC_WEBHOOK_BEARER=                      # optional Bearer token
```

Then re-run `bash bootstrap.sh`.

## Payload shape

See `i18n/en/docs/proposals/cicd-test-gate.md` §4.2. Compact form:

```json
{ "event": "tekton.pipelinerun.failed", "level": "error",
  "app": "my-app", "env": "prod", "commit": "abc1234",
  "ref": "main", "url": "https://...", "text": "..." }
```

## Caveats

- No retry on 4xx/5xx — your receiver should be idempotent.
- If `GENERIC_WEBHOOK_BEARER` is set, traffic carries `Authorization: Bearer <token>`.
- This plugin is the recommended channel for chaining (e.g. POST to a local script that fans out to internal SMS / PagerDuty / etc.).
