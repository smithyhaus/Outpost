# Plugin: git-provider / gitee

Gitee is Outpost's **primary push target** — manifest-repo host, the
domestic (CN) path for the deploy/rollback hot loop, and the reconciliation
basis `verify.sh` checks every `OUTPOST_REPOS` entry against.

## v0.3 change: no more inbound webhook

Earlier versions wired Gitee's Push Hook straight into a Tekton
EventListener. That entire inbound-webhook path is retired — CI now runs on
a **GitHub Actions self-hosted runner** (pure outbound long-poll, no inbound
endpoint to configure or leak a shared secret from). Gitee's job narrows to:

- primary push target for your app repos
- host of `MANIFEST_REPO_URL` (the deploy source of truth, pulled by the
  in-cluster `manifest-sync` CronJob every `MANIFEST_SYNC_INTERVAL` minutes)
- the host `preflight.sh` and `verify.sh` match `OUTPOST_REPOS` entries
  against for an authenticated `git ls-remote` probe

There is nothing to configure on the Gitee side anymore — no webhook URL, no
shared secret, no signature mode.

## Getting a GitHub trigger surface

Since GitHub Actions is the CI engine, every app repo needs a `github.com`
copy for the workflow to trigger from. Two supported ways to keep it in
sync with gitee (the primary):

### Option A — dual-push (recommended)

Add GitHub as a second push URL on `origin`, so one `git push` delivers to
both remotes and a failure is visible in your terminal immediately:

```bash
git remote set-url --add --push origin https://gitee.com/<org>/<repo>.git
git remote set-url --add --push origin https://github.com/<org>/<repo>.git
git push   # now pushes to BOTH
```

### Option B — gitee's official one-way push-mirror

Gitee repo → **管理 → 仓库镜像管理 → 推送镜像** → add the GitHub repo as a
push-mirror target. Gitee documents a 30-minute sync window and explicitly
warns against configuring **bidirectional** mirroring (push-mirror both
ways) — code can be lost if both sides receive writes inside that window.
Keep gitee as the only write target; the mirror is one-way gitee → github.

## Credentials

`GIT_USER` / `GIT_TOKEN` (paired with `GIT_HOST`, auto-derived from
`MANIFEST_REPO_URL`) authenticate against gitee.com. `preflight.sh` uses
these to run a real `git ls-remote` against every `OUTPOST_REPOS` entry on
gitee.com — an invalid or expired token fails bootstrap immediately instead
of silently breaking builds and reconciliation later.

## Field reference (unchanged concepts, new consumers)

| Concept | Source |
|---------|--------|
| Repo registry | `OUTPOST_REPOS` (`.env`) — replaces the old `WEBHOOK_REPO_WHITELIST` |
| Deploy branch | `OUTPOST_DEPLOY_BRANCH` (`.env`) — filters which branch's pushes matter |
| Manifest repo | `MANIFEST_REPO_URL` / `MANIFEST_REPO_BRANCH` (`.env`) |
