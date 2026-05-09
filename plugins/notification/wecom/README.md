# notification / wecom

Sends Outpost CI/CD events to a WeCom (企业微信) group robot as a markdown message.

## What gets installed

- `Secret/wecom-webhook` in `tekton-pipelines`.
- `ConfigMap/wecom-template` in `tekton-pipelines`.
- Merge fragments into `argocd-notifications-cm` and `argocd-notifications-secret`.

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
