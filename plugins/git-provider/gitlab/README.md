# Plugin: git-provider / gitlab

GitLab Push Hook → Tekton EventListener → PipelineRun.
Works on both gitlab.com and self-hosted GitLab CE/EE.

## Webhook configuration

Repo → **Settings → Webhooks → Add new webhook**

| Field           | Value                                  |
|-----------------|----------------------------------------|
| URL             | `https://hooks.<ROOT_DOMAIN>`          |
| Secret token    | value of `GIT_WEBHOOK_SECRET` from `.env` |
| SSL verify      | enabled                                |
| Trigger events  | check **Push events** only             |

## How signature verification works

GitLab sends the raw shared secret in the `X-Gitlab-Token` header. The
EventListener CEL interceptor compares it with `GIT_WEBHOOK_SECRET`.

> ⚠️ GitLab does not offer HMAC signing for webhooks — plain token is the
> only available mode. Rotate `GIT_WEBHOOK_SECRET` if leaked.

## Field mapping

| Pipeline param | GitLab field                       |
|----------------|------------------------------------|
| `repo-url`     | `body.repository.git_http_url`     |
| `repo-name`    | `body.repository.name`             |
| `branch`       | `body.ref`                         |
| `revision`     | `body.after`                       |
| `pusher`       | `body.user_username`               |
