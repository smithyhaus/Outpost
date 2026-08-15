# notification / webhook-generic

Fallback channel: POSTs the raw normalized Outpost payload to your own collector — no vendor wrapper. Useful for self-hosted alertmanager bridges, custom relays, local debugging, or chaining to additional channels.

## What gets installed

- `Secret/generic-webhook` in `outpost-ci`, volume-mounted by the manifest-sync CronJob.
- `ConfigMap/generic-template` in `outpost-ci`.

Host-run callers (the GitHub Actions workflow's `build-failed` step, and the
`verify.sh` systemd timer's `verify-failed` check) invoke
`notify-fanout.sh --env-file $OUTPOST_ROOT/.env ...` instead of relying on
the volume mount.

## How to enable

```env
NOTIFICATION_PROVIDERS=webhook-generic       # comma-list if more
GENERIC_WEBHOOK_URL=https://your-collector.example.com/hook
GENERIC_WEBHOOK_BEARER=                      # optional Bearer token
```

Then re-run `bash bootstrap.sh`.

## Payload shape

```json
{ "event": "build-failed", "level": "error",
  "app": "my-app", "env": "prod", "commit": "abc1234",
  "ref": "main", "url": "https://...", "text": "..." }
```

Event names: `build-failed` (GitHub Actions workflow), `deploy-succeeded` /
`deploy-failed` (manifest-sync CronJob), `verify-failed` (host verify.sh
systemd timer).

## Caveats

- No retry on 4xx/5xx — your receiver should be idempotent.
- If `GENERIC_WEBHOOK_BEARER` is set, traffic carries `Authorization: Bearer <token>`.
- This plugin is the recommended channel for chaining (e.g. POST to a local script that fans out to internal SMS / PagerDuty / etc.).
