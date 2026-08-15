# Plugin: git-provider / github

GitHub is Outpost's **CI trigger surface**: a self-hosted Actions runner on
this host authenticates outbound (long-poll, no inbound endpoint) and runs
`templates/github/outpost-build.yml` on every push to the deploy branch.

## v0.3 change: no more inbound webhook

Earlier versions wired GitHub's Push event straight into a Tekton
EventListener (HMAC-SHA256 verified). That path is retired — the GitHub
Actions self-hosted runner replaces it with a pure outbound connection, so
there's nothing to configure on the GitHub webhook UI anymore.

## Setting up the runner

1. Create (or reuse) a GitHub org and add every app repo you'll build.
2. Set `GITHUB_RUNNER_URL=https://github.com/<org>` in `.env` — **org-level**
   registration is recommended: one runner serves every private repo in the
   org (see GitHub Docs: runner groups). A single-repo URL
   (`https://github.com/<owner>/<repo>`) also works but only serves that repo.
3. Set `GITHUB_RUNNER_PAT` to a PAT with the minimal scope needed to mint
   runner *registration* tokens (`admin:org` for org-level, or repo admin for
   single-repo). This PAT is used ONLY to mint short-lived registration
   tokens via the GitHub API — it is never stored as the runner's long-lived
   credential, and preflight.sh never echoes it.
4. Re-run `bash bootstrap.sh` — it installs the official `actions/runner` as
   a systemd service under `$HOME/actions-runner`.
5. Leave both empty to run this repo's own test/e2e suite without a real
   GitHub org — preflight WARNs loudly and skips the runner install instead
   of failing (a supported CI/e2e mode, not silent).

## Getting app repos onto GitHub

App repos are usually primarily on gitee. See
`plugins/git-provider/gitee/README.md` for the dual-push / push-mirror setup
that keeps a github.com copy in sync so the workflow has something to
trigger from.

## How the preflight check works

- Authenticated `git ls-remote` against every `OUTPOST_REPOS` entry whose
  host is `github.com` (credentials resolved the same way as every other
  git-provider plugin: primary `GIT_USER`/`GIT_TOKEN` when `GIT_HOST` matches,
  else a `GIT_CREDENTIALS_EXTRA` entry).
- When `GITHUB_RUNNER_URL`/`GITHUB_RUNNER_PAT` are set: validates the URL
  shape and calls the GitHub API (`GET /user`) with the PAT to confirm it
  authenticates. The token is masked in all output.

## Limitations (unchanged from v0.1)

- Only public + private GitHub.com. GitHub Enterprise Server is untested.
- Runner group scope: keep the runner group limited to your private repos
  (GitHub's default) — never attach it to a group that accepts public-repo
  PRs, since the runner executes arbitrary workflow code on this host.
