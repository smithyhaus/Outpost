# Changelog

All notable changes to Outpost are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] — 2026-08-15

Data-layer revert: the v0.3.0 in-cluster move (ADR-0004) is reverted
before any real deployment ran it — stateful services
(postgres/redis/rabbitmq/manticore) stay in **host Compose in both modes**,
per owner decision. The k3s side returns to the hardened
`ExternalName → host.docker.internal` bridge (CoreDNS custom hosts +
`coredns-hosts-reconciler` self-heal), now with two FAIL-level verify
checks — `data.bridge_dns` (entry vs current node IP) and
`data.bridge_reconciler` — so drift pages instead of silently stranding
the fleet. Caddy's `@search`/`@mq` UI routes and the raw-TCP tunnel class
(`pg.*`/`redis.*`/`rabbitmq.*`) are restored; `full` mode runs Compose
with `--profile edge --profile local-data`. Bootstrap Phase 8 cleans up
v0.3.0 in-cluster data workloads if present (never PVCs). See
[ADR-0005](docs/decisions/0005-data-layer-back-to-host.md).

## [0.3.0] — 2026-08-15

CI/CD engine swap: Tekton + ArgoCD are retired in favor of a GitHub Actions
self-hosted runner (CI) and a manifest-sync CronJob (CD). Rationale, incident
attribution (72 commits audited), and the three-option adversarial review
live in [ADR-0003](docs/decisions/0003-github-actions-engine-swap.md). The
data layer (postgres/redis/rabbitmq/manticore) moves into k3s for `full`
mode; see [ADR-0004](docs/decisions/0004-data-layer-in-k3s.md) (amends
ADR-0001). Full redeploy steps:
[`docs/prp/runbooks/wsl2-redeploy-0.3.md`](docs/prp/runbooks/wsl2-redeploy-0.3.md).

### BREAKING

- **Engine swap: Tekton + ArgoCD → GitHub Actions self-hosted runner +
  manifest-sync CronJob.** Tekton (16 CRDs / 4 controllers / 5 admission
  webhooks / dashboard / EventListener / pruner) and ArgoCD (7 processes / 3
  CRDs / notifications) are fully removed — ~80k LOC of vendored YAML and
  23+ cluster CRDs down to 1 (sealed-secrets; +4 optional if
  `ROLLOUT_PLUGIN=argo-rollouts`). CI is now a ~40-line
  `templates/github/outpost-build.yml` workflow run by the official
  `actions/runner` on the host, calling this repo's `scripts/ci/*`
  (`build-image.sh` → buildctl against the in-cluster buildkitd NodePort,
  `run-tests.sh` → optional Gate A, `publish-npm.sh` for publish-type repos)
  then `scripts/update-manifest.sh` unchanged (6-attempt jittered push retry
  kept — cross-repo workflow concurrency still exists). CD is the
  `manifest-sync` CronJob (ns `outpost-ci`, every `MANIFEST_SYNC_INTERVAL`
  minutes, `concurrencyPolicy: Forbid`): `git pull` the manifest repo →
  `kubectl apply -k` changed apps → rollout-wait (Rollout-kind aware) →
  notify → heartbeat ConfigMap. See `bootstrap.d/08-ci.sh` (replaces
  `bootstrap.d/08-argocd-tekton.sh`).
- **Inbound webhook path retired entirely.** No provider push webhook is
  registered anywhere — the runner is pure outbound long-poll (proxy-aware),
  the manifest-sync CronJob is pure poll-pull. `scripts/register-webhooks.sh`,
  `platform/lib/cel-helpers.sh`, `platform/lib/eventlistener-assemble.sh`,
  every plugin's `trigger.yaml`, and the `hooks.<domain>` route are all
  deleted. `git-provider` plugins are now a credential + `git ls-remote`
  preflight contract, not a webhook-wiring contract.
- **`.env` additions**: `OUTPOST_REPOS` (comma-list of
  `<canonical-clone-url>[#<branch>]` — the reconciliation basis and
  onboarding registry; replaces `WEBHOOK_REPO_WHITELIST`'s gating role),
  `GITHUB_RUNNER_URL`, `GITHUB_RUNNER_PAT`, `GITHUB_RUNNER_LABELS` (default
  `outpost`), `GITHUB_RUNNER_NAME`, `MANIFEST_SYNC_INTERVAL` (default `2`
  minutes), `OUTPOST_STALENESS_THRESHOLD` (default `1800` seconds — how long
  a reconciliation mismatch may persist before `verify.sh` calls it FAIL),
  `OUTPOST_REGISTRY_KEEP_TAGS` (default `10`, up from `5` — doubles as
  rollback depth), `ROLLOUT_PLUGIN` (new default `none`; `argo-rollouts` is
  now opt-in and controller-only, no dashboard).
- **`.env` removals**: `GIT_WEBHOOK_SECRET`, `WEBHOOK_REPO_WHITELIST`,
  `ROLLOUTS_DASHBOARD_HOST`, `HOOKS_HOST`, `OUTPOST_DASHBOARD_USER`,
  `OUTPOST_DASHBOARD_PASSWORD` — there is no inbound webhook secret to leak
  and no dashboard BasicAuth surface left to guard.
- **Dashboards removed.** ArgoCD UI, Tekton Dashboard, and the Argo Rollouts
  dashboard are gone — no in-cluster CI/CD web UI. Build status lives in the
  GitHub Actions UI (or `journalctl -u actions.runner.*` on the runner host);
  deploy status lives in `outpost status` / `outpost logs sync` (sync-job
  logs + `sync-heartbeat` ConfigMap: `last_sync_ts` / `applied_head` /
  `last_result`).
- **Data layer moves into k3s for `full` mode.** postgres/redis/rabbitmq/
  manticore become StatefulSets in `infra-bridges` (Service names unchanged
  — application connection strings need zero edits). The
  `host.docker.internal` / CoreDNS bridge is deleted. `local` mode keeps a
  pure-Compose `local-data` profile; `full` mode's Compose stack shrinks to
  an `edge` profile (`caddy` + `cloudflared`). See
  [ADR-0004](docs/decisions/0004-data-layer-in-k3s.md).
- **Rollback CLI unchanged in shape, new mechanism**: `outpost rollback
  <app> [sha]` now lists registry tags via the NodePort registry API,
  yq-rewrites the manifest repo through the same `update-manifest.sh` code
  path, and relies on manifest-sync to converge (≤2 sync intervals, fully
  domestic — works with github.com unreachable). `kubectl rollout undo`
  remains the break-glass escape hatch but MUST be paired with a manifest
  revert or the next sync tick reverts it (enforced truth is a feature).
- **`outpost onboard` registers CI, not a webhook.** Onboarding an app now
  appends its clone URL to `OUTPOST_REPOS`, prints dual-push / workflow-copy
  instructions, and offers to drop `templates/github/outpost-build.yml`
  into the target repo's `.github/workflows/`. No provider-side webhook
  step exists anywhere in the onboarding flow.

### Changed

- **BREAKING — search backend swapped from Meilisearch to Manticore Search**
  (`manticoresearch/manticore:7.4.6`). Standalone mode is the default; a
  `core/compose/manticore/conf.d/99-replication.conf.disabled` sample and
  bind-mount are shipped so the cluster path is one-step away. Port surface
  changed: `7700` → `9308` (HTTP/JSON) + `9306` (MySQL wire) + `9312`
  (binary / future replication). `MEILI_MASTER_KEY` and `MEILI_ENV` env
  vars are removed (standalone Manticore needs no auth). The k8s bridge
  Service is renamed `meilisearch` → `manticore`; apps must update env
  vars (`MEILI_URL` → `MANTICORE_URL`) and any sealed-secret carrying a
  `MEILI_KEY` should drop it.

### Added

- **AI-agent on-ramp docs** — `AGENTS.md` (top-level, agents.md
  convention) and `.github/copilot-instructions.md` (GitHub Copilot
  Workspace). Both are stubs that point at `SKILL.md` as canonical
  source — no generator, no drift risk.
- **i18n edit-time drift check** in `tests/lint.sh` — for each EN/zh
  file pair, compares the most-recent commit timestamps and WARNs when
  EN is newer than zh. Complements the v0.2 filename-parity check.
  Wired through `.github/workflows/lint.yml` automatically.
- **ADR framework** under `docs/decisions/`: Nygard-style template,
  index, and the first ADR documenting the Compose+k3s two-layer
  architectural decision.
- **`make install` / `make uninstall`** for the `outpost` CLI — replaces
  the manual `ln -s` step from v0.2. Idempotent, refuses to clobber
  strangers, refuses to uninstall symlinks it doesn't own, warns when
  the install prefix isn't on `$PATH`. Overridable `PREFIX` and
  `DESTDIR`. 11 bats tests cover happy path + 4 refusal cases.
- **Per-kind plugin contract enforcement** —
  `tests/bats/plugin-contract-per-kind.bats` dispatches on the `kind:`
  field of each `plugin.yaml` and asserts per-kind required extras
  (notification → 2 ArgoCD fragments, git-provider → trigger.yaml).
  Catches the contributor footgun where a copy-pasted plugin scaffold
  passes the universal contract but produces a silently-broken install.
- **notify-task script extraction (interim)** — the 80-line inline bash
  in `core/k8s/05-tekton/notify-task.yaml` is now
  `scripts/notify-fanout.sh` (POSIX sh, shellcheck-clean, 10 bats tests
  with stubbed curl). `platform/lib/sign-webhook.sh` becomes the single
  source of truth for HMAC math; the duplicate inline signing in the
  Task YAML is gone. Both scripts ConfigMap-mounted at /scripts.
  notify-task.yaml shrinks 144 → 84 lines. v0.4 will bake an actual
  `outpost/notify-runner` image to also remove the per-PipelineRun
  apk-add cost (see TODOS).
- **Per-app `outpost.build.yaml`** — Tekton's `build-and-push` step now
  consumes 3 results from a new `read-build-config` Task that parses an
  optional `outpost.build.yaml` at the application repo root:
  `dockerfile`, `context`, merged `extra-args`. Monorepos can build
  sub-paths; apps on private mirrors can pass `buildArgs[]` (each
  becomes `--build-arg=K=V`); large builds can add `extraArgs[]`
  (passed through to kaniko verbatim). Absent file → v0.2 defaults
  preserved exactly (zero-regression). Canonical script:
  `scripts/read-build-config.sh` with 14 bats tests. Example:
  `examples/hello-world/go/outpost.build.yaml`.
- **Multi-provider EventListener wiring** — `GIT_PROVIDER_PLUGIN={gitee,
  github,gitlab}` actually selects which provider routes webhooks now.
  Phase 8 assembles the EventListener from a provider-agnostic envelope
  (`core/k8s/05-tekton/eventlistener-base.yaml`) plus the active
  plugin's sibling `trigger.yaml` file via
  `platform/lib/eventlistener-assemble.sh`. GitHub uses Tekton's
  built-in HMAC interceptor (X-Hub-Signature-256); Gitee / GitLab use
  plain-token compare against `GIT_WEBHOOK_SECRET`. 10 new bats tests
  cover all 3 providers + bad inputs + envsubst residue.
- **Doc-drift fix (v0.1.0 → v0.2.0)**: `VERSION` file, `CHANGELOG.md`
  (this file), `outpost version` now prints `v<VERSION> (commit <sha>)`,
  README §Status updated, bug-report issue template placeholder fixed.

### Changed

- **EventListener renamed** `gitee-listener` → `build-listener`
  (provider-agnostic). Service follows: `el-gitee-listener` →
  `el-build-listener`. Bootstrap Phase 8 orphan cleanup deletes the
  old names on upgrade — no manual intervention required.
- **Plugin `<provider>-trigger-fragment` ConfigMaps removed.** They
  had no consumer; the sibling `trigger.yaml` is the source of truth.
  Orphan cleanup deletes existing in-cluster copies on upgrade.

### Removed

- `core/k8s/05-tekton/eventlistener.yaml` (the hardcoded v0.1
  Gitee-only EventListener). Replaced by the assembly pipeline above.

See [`TODOS.md`](TODOS.md) for the v0.4 roadmap and beyond.

## [0.2.0] — 2026-05-12

The v0.2 cut focused on (a) zero-friction local onboarding, (b) CI/CD
test gate + auto-rollback + multi-channel notifications, and (c) several
hardening fixes uncovered by end-to-end macOS + Linux runs.

### Added

- **`OUTPOST_MODE={local|full}` toggle** — `local` runs only the Compose
  data services (PG / Redis / RabbitMQ / Meilisearch) on `localhost`
  with zero required input; `full` keeps the v0.1 stack (Cloudflare
  Tunnel + k3s + ArgoCD + Tekton GitOps) unchanged. Compose `tunnel`
  profile gates `cloudflared` + `caddy`. `verify.sh` / `status.sh` skip
  k8s sections in local mode. New `INFRA.local.md.template` in en + zh-CN.
  JSON `summary.mode` field added (schema-additive).
- **CI/CD test gate + auto-rollback + multi-channel notifications**
  (Phase 9 of `bootstrap.sh`). Three new plugin kinds:
  - `test-runner/{testkube, catalog-tasks}` — Gate A in Pipeline +
    Gate B in Argo Rollouts `AnalysisTemplate`.
  - `rollout/argo-rollouts` — canary + automatic rollback on
    `AnalysisRun` failure.
  - `notification/{dingtalk, feishu, wecom, webhook-generic}` —
    fan-out alerts via shared `outpost-notify` Tekton task + ArgoCD
    notifications controller; signed webhook for dingtalk/feishu.
  Application contract: optional `outpost.test.yaml` at app repo root.
  Full design: [`docs/proposals/cicd-test-gate.md`](i18n/en/docs/proposals/cicd-test-gate.md).
- **`scripts/outpost` CLI** — single-entry daily commands wrapping the
  kubectl / argocd / kubeseal incantations every user eventually
  memorizes: `status`, `verify [--app <name>]`, `open <target>`,
  `logs <app> [--build]`, `rollback <app>`, `seal <app> KEY=VAL …`,
  `new-app <name> --lang <go|python|java|csharp|react|vue>`,
  `decommission <app>`.
- **Argo Rollouts demo app** + per-language hello-world scaffolds for
  Go, Python, Java, C#, React, Vue.
- **`bootstrap.d/` per-phase split** — `bootstrap.sh` is now a 60-line
  orchestrator; the 10 phases live in `bootstrap.d/NN-*.sh` so they
  can be edited, code-reviewed, and reasoned about independently.
- **Tekton Dashboard** installed and wired through `tekton.<domain>`.
- **EventListener CEL whitelist** (`WEBHOOK_REPO_WHITELIST`) — narrows
  the blast radius of `GIT_WEBHOOK_SECRET` so a leak no longer lets
  any caller trigger kaniko builds for arbitrary repos.
- **kaniko build cache** wired through the active registry plugin —
  Java/.NET cold-cache builds drop from 30–90 min to 5–10 min on warm
  cache.

### Changed

- **Sealed-secrets master key now persists across resets.**
  `bootstrap.sh` Phase 6 backs up + restores
  `secrets-backup/sealed-secrets-master.key.yaml`. `reset.sh`
  preserves it by default; `--hard` wipes for forced rotation.
  Eliminates the "Sealed-Secrets bankruptcy" failure mode every
  cluster reset previously caused.
- **Tekton + Argo Rollouts dashboards are now sealed behind a single
  Traefik BasicAuth middleware** (`OUTPOST_DASHBOARD_USER` /
  `OUTPOST_DASHBOARD_PASSWORD`, auto-generated if blank). Both ship
  anonymous-with-write-access upstream; this closes a real
  exposure surface on full-mode deployments.
- **Aliyun ACR plugin now works end-to-end.** Image tags became 7-char
  short SHAs via CEL overlay interceptor; `update-manifest.sh` retries
  `git push` with `git fetch + rebase` on non-fast-forward so
  concurrent PipelineRuns no longer silently lose deployments;
  `examples/demo-app/` switched from inline plaintext env to
  `envFrom: secretRef:` + sealed-secret pattern.
- **`apps` namespace ships with `ResourceQuota` + `LimitRange`** so a
  runaway app can't pin the host (30 pods / 4 req-cpu / 8 Gi req-mem;
  default 1 cpu / 512 Mi; max 4 cpu / 8 Gi per container).
- **Secrets renamed for provider-agnostic naming**:
  `gitee-credentials` → `git-credentials` (tekton-pipelines),
  `gitee-manifest-repo` → `git-manifest-repo` (argocd). v0.2 bootstrap
  cleans up the old names automatically.

### Fixed

- Three race conditions during full reset + rebootstrap (`63032a2`).
- Kaniko push routed through in-cluster Service to bypass the
  cloudflared HTTP/2 boundary (`06b2fbe`).
- PipelineRun timeouts raised to 2h to accommodate cold-cache Java/.NET
  builds (`6a1cba1`).
- `git-credentials` secret now carries `.gitconfig` so Tekton's
  `git-clone` task authenticates correctly (`eb5fdc7`).
- `tekton-pipelines` namespace PSA downgraded to `baseline` to match
  what catalog Tasks actually need (`7e32c13`).
- ClusterTask removed in favor of namespace Task (`b61e357`).
- Server-side apply for ArgoCD + Tekton installs to avoid the 256 KB
  client-side-apply limit on CRDs (`075edf2`).
- `.env` persisted before plugin preflight subshells so auto-generated
  values are visible to them (`e98080a`).

## [0.1.0] — initial public release

First public cut of Outpost. Two-layer architecture (Docker Compose for
stateful data services + k3s for stateless apps and GitOps CI/CD),
fronted by a single Cloudflare Tunnel. Plugin model for
`registry/{self-hosted, aliyun-acr}` and `git-provider/{gitee, github,
gitlab}` (gitee wired end-to-end; github/gitlab scaffold only).
Supports macOS / Linux / WSL2.

[Unreleased]: https://github.com/smithyhaus/outpost/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/smithyhaus/outpost/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/smithyhaus/outpost/releases/tag/v0.1.0
