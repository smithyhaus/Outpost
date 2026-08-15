# Plugin: git-provider / gitlab

GitLab (gitlab.com or self-hosted CE/EE) — a credential + host-matching
contract, same shape as gitee/github. Works alongside them: `GIT_PROVIDER_PLUGIN`
accepts a comma-list, and each enabled provider's `preflight.sh` only probes
`OUTPOST_REPOS` entries whose host it owns.

## v0.3 change: no more inbound webhook

Earlier versions wired GitLab's Push Hook straight into a Tekton
EventListener (plain `X-Gitlab-Token` compare — GitLab has never offered
HMAC signing for webhooks). That path is retired; CI is triggered by GitHub
Actions on a self-hosted runner, so there is nothing to configure on the
GitLab webhook UI anymore.

## Host matching

GitLab self-hosted instances can live on any hostname, so this plugin can't
match a single fixed host like gitee/github do. `preflight.sh` treats any
`OUTPOST_REPOS` entry whose host contains the substring `gitlab.` as owned by
this plugin (matches `gitlab.com`, `gitlab.corp.example`, etc.). If your
self-hosted instance's hostname doesn't contain `gitlab.`, its entries won't
be probed by this plugin — they'll need `GIT_CREDENTIALS_EXTRA` credentials
regardless, since only the *probe*, not the clone, depends on host matching.

## Credentials

Same resolution as every other git-provider plugin: the primary
`GIT_USER`/`GIT_TOKEN` pair when the entry's host equals `GIT_HOST`
(derived from `MANIFEST_REPO_URL` — normally gitee, so this is rare for
GitLab), otherwise a `GIT_CREDENTIALS_EXTRA` `host|user|token` entry:

```env
GIT_CREDENTIALS_EXTRA=gitlab.corp.example|ci-bot|glpat-xxxx
```

## What preflight checks

For every matching `OUTPOST_REPOS` entry, an authenticated `git ls-remote`
confirms the token can actually list refs — a revoked/expired token fails
loudly at bootstrap instead of silently breaking `verify.sh` reconciliation
weeks later.
