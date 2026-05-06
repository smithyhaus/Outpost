# Plugin: git-provider / gitee

Wires Gitee Push Hook → Tekton EventListener → PipelineRun.

## Webhook configuration

In your Gitee repo: **Management → WebHooks → Add**

| Field   | Value                                  |
|---------|----------------------------------------|
| URL     | `https://hooks.<ROOT_DOMAIN>`          |
| 密码    | value of `GIT_WEBHOOK_SECRET` from `.env` (Gitee labels its shared-secret field "密码") |
| Events  | check **Push** only                    |
| Status  | enabled                                |

## How signature verification works

Gitee sends the raw shared secret in the `X-Gitee-Token` header. The
EventListener CEL interceptor compares it with `GIT_WEBHOOK_SECRET` baked
into the trigger.

> ⚠️ This is a plain-token comparison, weaker than HMAC. If the token leaks,
> rotate it: regenerate `GIT_WEBHOOK_SECRET` in `.env`, re-run
> `bash bootstrap.sh` (idempotent), and update the value in every Gitee
> repo's webhook setting.

## Field mapping

| Pipeline param | Gitee field                                |
|----------------|--------------------------------------------|
| `repo-url`     | `body.repository.git_http_url`             |
| `repo-name`    | `body.repository.name`                     |
| `branch`       | `body.ref`                                 |
| `revision`     | `body.after`                               |
| `pusher`       | `body.user_name`                           |
