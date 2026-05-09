# notification / feishu

Sends Outpost CI/CD events to a Feishu (Lark) custom-bot as an interactive card.

## What gets installed

- `Secret/feishu-webhook` in `tekton-pipelines`.
- `ConfigMap/feishu-template` in `tekton-pipelines` — Feishu interactive-card template.
- Merge fragments into `argocd-notifications-cm` and `argocd-notifications-secret`.

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
