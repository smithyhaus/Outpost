# templates/github — app-repo workflow for the Outpost CI engine (v0.3.0)

CI runs on **GitHub Actions with a self-hosted runner on the Outpost host**.
App repos stay on **gitee as the primary push target**; the **github copy is
only the CI trigger surface**. The workflow file below is the ONLY thing an
app repo needs — every real step is a hardened script in this repo, executed
on the runner host.

## 1. Place the workflow into an app repo

```bash
mkdir -p <app-repo>/.github/workflows
cp templates/github/outpost-build.yml <app-repo>/.github/workflows/outpost-build.yml
# edit the `branches: [main]` line if the deploy branch differs
git -C <app-repo> add .github/workflows/outpost-build.yml
git -C <app-repo> commit -m "ci: outpost build workflow"
```

`outpost onboard <repo-url>` prints these steps (and offers the copy) and
registers the repo in `OUTPOST_REPOS` so verify.sh reconciliation watches it.

## 2. Keep github in sync with gitee (pick ONE)

**Recommended — dual push** (failure is visible in your terminal at push time):

```bash
cd <app-repo>
git remote set-url --add --push origin <gitee-url>
git remote set-url --add --push origin <github-url>
# one `git push` now reaches both forges
```

**Alternative — gitee one-way push-mirror** (gitee → github, configured in the
gitee repo settings UI). Use the *one-way* mirror only: gitee's own docs warn
that the bidirectional mirror's 30-minute window can lose commits. Mirror
death is caught by `verify.sh` reconciliation (live HEAD vs deployed tag),
not by anything in this workflow.

## 3. What `OUTPOST_ROOT` must point at

The workflow calls `$OUTPOST_ROOT/scripts/...`. `OUTPOST_ROOT` is injected
via the runner's environment file (`$HOME/actions-runner/.env`, written by
bootstrap when it installs the runner) and must point at the **infras repo
checkout on the runner host** — the one whose `.env` holds
`MANIFEST_REPO_URL`, `REGISTRY_PLUGIN`, `OUTPOST_LIBRARY_REPOS`, git
credentials, etc. The runner host additionally needs on PATH: `buildctl`,
`git`, `yq`, `docker` (Gate A), `pnpm`/`corepack` + `kubectl` (library repos).

The failure step drives the v0.3.0 `notify-fanout.sh` through its env API
(`PAYLOAD`/`PROVIDERS`, plus `--env-file` for host-side provider config).

## 4. Steps, in one breath

checkout (shallow) → `scripts/ci/build-image.sh` (read-build-config,
path-traversal guards, buildctl → in-cluster buildkitd via 127.0.0.1:30750,
sha-7 tag, ACR-safe push; library repos → `publish-npm.sh` → Verdaccio) →
`scripts/ci/run-tests.sh` (Gate A, containerized, clean no-op) →
`scripts/update-manifest.sh` (gitee manifest repo, 6-attempt jittered push
retry) → on any failure `notify-fanout.sh build-failed`. Deployment is NOT
here: the in-cluster manifest-sync CronJob applies the manifest change within
`MANIFEST_SYNC_INTERVAL` minutes — the deploy/rollback hot path stays fully
domestic (gitee + local cluster), independent of github/proxy health.
