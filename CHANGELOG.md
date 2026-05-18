# Changelog

All notable changes to Outpost are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

See [`TODOS.md`](TODOS.md) for the v0.3 roadmap and beyond.

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
