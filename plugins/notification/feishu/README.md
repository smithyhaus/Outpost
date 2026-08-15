# notification / feishu

Sends Outpost CI/CD events to a Feishu (Lark) custom-bot as an interactive card.

## What gets installed

- `Secret/feishu-webhook` in `outpost-ci`, volume-mounted by the manifest-sync CronJob.
- `ConfigMap/feishu-template` in `outpost-ci` — Feishu interactive-card template.

Host-run callers (the GitHub Actions workflow's `build-failed` step, and the
`verify.sh` systemd timer's `verify-failed` check) invoke
`notify-fanout.sh --env-file $OUTPOST_ROOT/.env ...` instead of relying on
the volume mount.

## How to enable

1. Feishu group → **Settings → Bots → Custom Bot**. Optionally enable **Signature Verification** (`签名校验`).
2. Copy the webhook URL and (if signed) the sign secret.
3. In `.env`:
   ```
   NOTIFICATION_PROVIDERS=feishu          # comma-list if more
   FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...
   FEISHU_SIGN_SECRET=                    # optional
   ```
4. Re-run `bash bootstrap.sh`.

## Caveats

- Same as DingTalk — without sign secret the URL alone is enough to post.
- Feishu rate limit ≈ 100 msg/min per bot; more generous than DingTalk.
- The card uses `template: red` for errors; tweak the ConfigMap if you want other colours per event.
