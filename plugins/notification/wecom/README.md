# notification / wecom

Sends Outpost CI/CD events to a WeCom (企业微信) group robot as a markdown message.

## What gets installed

- `Secret/wecom-webhook` in `outpost-ci`, volume-mounted by the manifest-sync CronJob.
- `ConfigMap/wecom-template` in `outpost-ci`.

Host-run callers (the GitHub Actions workflow's `build-failed` step, and the
`verify.sh` systemd timer's `verify-failed` check) invoke
`notify-fanout.sh --env-file $OUTPOST_ROOT/.env ...` instead of relying on
the volume mount.

## How to enable

1. WeCom group → **Group Settings → Add Group Robot → Custom Robot**.
2. Copy the webhook URL.
3. In `.env`:
   ```
   NOTIFICATION_PROVIDERS=wecom
   WECOM_WEBHOOK_URL=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
   ```
4. Re-run `bash bootstrap.sh`.

## Caveats

- WeCom does not have per-message HMAC signing. Protect the URL.
- Rate limit ≈ 20 msg/min per bot.
- WeCom markdown is strict — no tables; use `<font color="warning">` for emphasis.
