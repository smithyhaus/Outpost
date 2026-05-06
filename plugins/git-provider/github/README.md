# Plugin: git-provider / github

GitHub Push event → Tekton EventListener → PipelineRun.

## Webhook configuration

In your GitHub repo: **Settings → Webhooks → Add webhook**

| Field         | Value                                  |
|---------------|----------------------------------------|
| Payload URL   | `https://hooks.<ROOT_DOMAIN>`          |
| Content type  | `application/json`                     |
| Secret        | value of `GIT_WEBHOOK_SECRET` from `.env` |
| SSL verify    | enabled                                |
| Events        | **Just the push event**                |
| Active        | yes                                    |

## How signature verification works

GitHub signs the payload body with HMAC-SHA256 keyed on the webhook secret
and sends the digest in `X-Hub-Signature-256`. Tekton's built-in
`github` interceptor verifies it before any downstream processing — invalid
signatures never reach the pipeline.

## Field mapping

| Pipeline param | GitHub field                    |
|----------------|---------------------------------|
| `repo-url`     | `body.repository.clone_url`     |
| `repo-name`    | `body.repository.name`          |
| `branch`       | `body.ref`                      |
| `revision`     | `body.after`                    |
| `pusher`       | `body.pusher.name`              |

## Limitations (v1.0)

- Only `push` events. PR / issue / release events are out of scope.
- Only public + private GitHub.com. GitHub Enterprise Server is untested.
