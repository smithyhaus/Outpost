# TODOS

Items deliberately deferred from v0.1. Each entry has enough context for
a future contributor to pick it up cold.

---

## ✅ Retired in v0.3 — Replace deprecated kaniko catalog Task

**Originally:** `core/k8s/05-tekton/pipeline-build.yaml` referenced the
deprecated upstream Tekton catalog `kaniko` Task, with BuildKit already
promoted to the default `BUILD_ENGINE_TASK` and kaniko kept as a
one-word-flip rollback.

**Why retired:** the v0.3.0 CI/CD engine swap
([ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)) removes
Tekton entirely — there is no Task, no Pipeline, no PipelineRun anymore.
Builds run via `scripts/ci/build-image.sh` (buildctl against the
in-cluster buildkitd, unchanged from the pre-v0.3 hardening) invoked
directly by the GitHub Actions workflow. The kaniko catalog Task, its
rollback flag, and this entire deprecation-tracking item no longer apply
— buildkitd is now the only build path, with no Tekton-Task-shaped
rollback to maintain.

---

## ✅ Done in v0.3, superseded by the v0.3.0 engine swap — multi-provider EventListener wiring

> **Superseded:** the mechanism described below (Tekton EventListener +
> per-provider `trigger.yaml`) is deleted by the v0.3.0 CI/CD engine swap
> ([ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)).
> `GIT_PROVIDER_PLUGIN` still exists but now selects a credential + `git
> ls-remote` preflight contract, not webhook routing. Left below for
> historical record.

`bootstrap.sh` Phase 8 now assembles the EventListener from a
provider-agnostic envelope (`core/k8s/05-tekton/eventlistener-base.yaml`)
plus the active plugin's sibling `trigger.yaml` file via
`platform/lib/eventlistener-assemble.sh`. Hardcoded
`core/k8s/05-tekton/eventlistener.yaml` deleted; service name unified
to `el-build-listener`. EventListener renamed `gitee-listener` →
`build-listener` (orphan cleanup in Phase 8 deletes the old name on
upgrade). Each plugin's stale `<provider>-trigger-fragment` ConfigMap
also removed (orphan cleanup deletes existing in-cluster copies).
No yq dependency added — pure bash + awk splice with a strict
single-marker check (`# OUTPOST_TRIGGERS_HERE`). 10 new bats tests in
`tests/bats/eventlistener-assemble.bats` cover the 3 providers + bad
inputs + envsubst residue. `GIT_PROVIDER_PLUGIN={gitee,github,gitlab}`
now actually selects which provider routes webhooks.

---

## ✅ Done in v0.2 — local/full mode split

`OUTPOST_MODE={local|full}` toggles Compose-only vs full GitOps. New users
get a zero-prompt `local` install; `full` mode preserves the v0.1 stack
unchanged. Compose `tunnel` profile gates cloudflared+caddy. Verify and
status scripts skip k8s sections in `local`. New `INFRA.local.md.template`
in en + zh-CN. JSON `summary.mode` field added (schema-additive).

---

## ✅ Done in v0.2 — CI/CD test gate + auto-rollback + multi-channel notifications

Phase 9 of `bootstrap.sh`. Three new plugin kinds:
- `test-runner/{testkube,catalog-tasks}` — Gate A in pipeline + Gate B in
  Argo Rollouts AnalysisTemplate.
- `rollout/argo-rollouts` — canary + automatic rollback on
  AnalysisRun failure.
- `notification/{dingtalk,feishu,wecom,webhook-generic}` — fan-out
  alerts via shared `outpost-notify` Tekton task + ArgoCD notifications
  controller; signed webhook for dingtalk/feishu.

Application contract: optional `outpost.test.yaml` at app repo root
(see `examples/hello-world/<lang>/`). Full design:
[`i18n/en/docs/proposals/cicd-test-gate.md`](i18n/en/docs/proposals/cicd-test-gate.md).

---

## ✅ Done in v0.2 — sealed-secrets master key persists across resets

`bootstrap.sh` Phase 6 backs up + restores
`secrets-backup/sealed-secrets-master.key.yaml`. `reset.sh` preserves it
by default; `--hard` wipes for forced rotation. Eliminates the
"Sealed-Secrets bankruptcy" failure mode every cluster reset previously
caused.

---

## ✅ Done in v0.2 — Tekton + Argo Rollouts dashboards behind BasicAuth

Both ship anonymous-with-write-access upstream. Outpost wraps both in a
single Traefik BasicAuth middleware. Username = `OUTPOST_DASHBOARD_USER`
(default `outpost`), password = `OUTPOST_DASHBOARD_PASSWORD` (auto-gen
in `.env`, surfaced in `INFRA.md` §0). `--providers.kubernetescrd.allowCrossNamespace=true`
enabled in Traefik so the same middleware covers both namespaces.

---

## ✅ Done in v0.2 — aliyun-acr end-to-end + 7-char short SHA + manifest push retry

App-team review fixes (from `i18n/{en,zh-CN}/docs/proposals/cicd-test-gate.md`
review pass):
- `REGISTRY_PLUGIN=aliyun-acr` actually pushes to ACR (was previously broken
  in three places: secret name, hardcoded host, kaniko --insecure flags).
- Image tags are 7-char short SHA via CEL overlay interceptor.
- `update-manifest.sh` retries `git push` with `git fetch + rebase` on
  non-fast-forward — concurrent PipelineRuns no longer silently lose deployments.
- `examples/demo-app/` switched from inline plaintext env to
  `envFrom: secretRef:` + sealed-secret pattern.
- `apps` namespace ships with ResourceQuota + LimitRange.

---

## Tunnel plugin abstraction (frp / tailscale / ngrok)

**What:** Add a `plugins/tunnel/` kind, with `cloudflare/`, `frp/`,
`tailscale/`, `ngrok/` etc. as plugins. `bootstrap.sh` selects one per
`.env`.

**Why:** v0.1 hard-codes Cloudflare Tunnel. Users without a Cloudflare
account, or who don't want to send traffic through Cloudflare, are
excluded.

**Pros:**
- Broadens the user base immediately.
- Validates the plugin architecture in a second axis (after registry +
  git-provider).

**Cons:**
- Each tunnel backend has different ingress semantics (cloudflared has
  Public Hostnames, frp has reverse proxies with explicit ports, tailscale
  has Funnel/Serve, ngrok has named tunnels).
- TCP service exposure (PG / Redis / RabbitMQ) is not uniform — frp and
  tailscale handle it natively but with different UX; ngrok free tier
  limits TCP per account.

**Context:** plugin contract is defined in `plugins/README.md`. Use
`plugins/registry/aliyun-acr/` as the closest analog (external service +
credentials secret).

**Depends on:** v0.1 plugin architecture (already done).

**Milestone:** v0.2

---

## ✅ Done in v0.3 — AGENTS.md + .github/copilot-instructions.md

Both files added as **stubs that point at SKILL.md as canonical**, not
generated duplicates. Each file restates the 4 critical facts (two modes,
plugin model, no-silent-failures, tests-first) inline, summarises the
repo layout, and lists "what NOT to do" — then links to SKILL.md for
depth. Zero generator: no drift risk because there's only one
authoritative source.

Trade-off accepted vs the original "generator" proposal: AGENTS.md and
copilot-instructions.md will lag SKILL.md if its structure changes, but
the 4 critical facts are stable enough that manual stubs are lower-cost
than maintaining a generator + its bats coverage.

If a third AI-tool convention emerges in v0.4 and the stub burden grows,
revisit the generator idea then.

---

## Helm chart packaging

**What:** Ship a Helm chart for the k3s layer (`outpost-ci` CI/CD glue +
`infra-bridges` ExternalName data bridges + buildkit/registry + plugins) so
operators on existing clusters can install just that layer without using
`bootstrap.sh`.

**Updated for v0.3.0:** the ArgoCD + Tekton stack this item originally
targeted is gone ([ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)).
The k3s layer is now considerably smaller — `manifest-sync` CronJob +
RBAC/PVC/NodePorts (`core/k8s/03-ci/`), the ExternalName data bridges +
CoreDNS reconciler (`core/k8s/06-bridges/`), buildkitd
(`core/k8s/08-buildkit/`), and the
registry plugin. A Helm chart is arguably a better fit now than before
(less to templatize, no Tekton-Task Go-template contortions), but the
GitHub Actions **runner** piece is host-level (systemd), not k8s, and
doesn't fit a Helm chart at all — this item would ship a chart for the
in-cluster half only; the runner install stays a host-side script either
way.

**Why:** Some users already have k3s / k8s clusters. They want the
CI/CD glue parts but not the Compose data layer. A Helm chart is
the standard packaging.

**Pros:**
- Reaches the K8s-native audience.
- Easier to integrate into existing CD flows.

**Cons:**
- Maintaining manifests + Helm in parallel is duplicate work.
- Plugin abstraction has to translate to Helm values.

**Context:** Current manifests use `${VAR}` envsubst placeholders. Helm
values expansion is similar but uses Go templates. Most manifests will
need a small refactor to switch.

**Depends on:** stable plugin contract (v0.1 done).

**Milestone:** v0.3

---

## ✅ Done in v0.3 — i18n drift detection (filename parity + edit-time)

`tests/lint.sh` carries two i18n phases (both WARN, never FAIL — a
translation lag of one PR is normal):

1. **Filename parity** (already in v0.2) — `find` + `comm` to flag
   files present in one locale but not the other.
2. **Edit-time drift** (new in v0.3) — for each file pair, compare the
   commit timestamp of the most recent commit touching each side via
   `git log -1 --format=%ct`. If EN is strictly newer than zh, WARN with
   the day delta. Equal timestamps (same commit touched both, the goal
   state) → silent.

Wired into `.github/workflows/lint.yml` automatically since that
workflow already runs `bash tests/lint.sh`. No new workflow file
needed.

---

## More language packs (ja / ko / fr / es / de)

**What:** Mirror the EN + zh-CN docs under `i18n/<lang>/` for additional
languages.

**Why:** International audience.

**Pros:** broader reach.

**Cons:** maintenance burden grows linearly per language. Best driven by
native-speaker contributors.

**Context:** see `CONTRIBUTING.md` "Translating docs" section.

**Depends on:** v0.2 i18n drift detection (so new languages don't
silently rot).

**Milestone:** community-driven, opportunistic

---

## WSL2 in CI matrix

**What:** Add a Windows runner with WSL2 to the GitHub Actions test
matrix so PRs that risk a WSL2-only regression are caught automatically.

**Why:** v0.1 ships ubuntu + macos in CI; WSL2 is verified manually
before each release.

**Pros:** catches regressions earlier.

**Cons:** Windows runners with WSL2 are slow and historically flaky in
GitHub Actions. The first attempts may need a self-hosted runner.

**Context:** see `.github/workflows/test-matrix.yml` for the current
matrix.

**Depends on:** GitHub Actions improving WSL2 support, or self-hosted
runner availability.

**Milestone:** v0.3 or community

---

## ✅ Done in v0.3 — ADR framework + first ADR

`docs/decisions/` directory now contains:
- `README.md` — explains the why/when/how of ADRs in this repo, and the
  index table.
- `0000-template.md` — Michael Nygard format adapted to be light
  (Context / Decision / Consequences / Alternatives considered /
  References).
- `0001-two-layer-split.md` — documents the most-asked architectural
  question: why Compose for data + k3s for apps, not all-in-one.

### ⏳ v0.4 community-driven follow-ups (more ADRs)

The original TODO listed several other decisions worth documenting.
Pick them up as the questions actually recur:
- "Why cloudflared as the only ingress (not Tailscale / frp / ngrok)?"
- "Why a plugin model at all (vs forking deps)?"
- "Why Argo Rollouts vs Flagger?"
- "Why Testkube vs catalog Tasks as the default test runner?"
- "Why kaniko vs buildah vs BuildKit?"

No need to backfill all at once — write them when someone actually asks
the question or proposes the alternative.

---

## v0.3 from app-team review

The five items below were raised by the app-team review pass on v0.2
(see `i18n/en/docs/proposals/cicd-test-gate.md` review thread). Each is
a real DX gap or hardening opportunity.

### ✅ Done in v0.3 — Per-app build params (`outpost.build.yaml`)

Tekton Pipeline gains a `read-build-config` Task between fetch-source
and build-and-push that reads an optional `outpost.build.yaml` from the
cloned source root and emits 3 results consumed by kaniko: `dockerfile`,
`context`, `extra-args` (merged: platform defaults + `buildArgs[]` as
`--build-arg=K=V` + `extraArgs[]` passthrough).

- Canonical script: `scripts/read-build-config.sh` (POSIX sh, yq dep) —
  14 bats tests in `tests/bats/read-build-config.bats` cover defaults,
  merge order, partials, valid-JSON output, Tekton-result single-line
  contract.
- Wrapper Task: `core/k8s/05-tekton/task-read-build-config.yaml`
  (mikefarah/yq:4.44.1 image, ConfigMap-mounted script — same split
  pattern as update-manifest-task).
- Example: `examples/hello-world/go/outpost.build.yaml` documenting
  the schema.
- Docs: `i18n/{en,zh-CN}/docs/05-onboard-project.md` § 8.

**Scope cut from original 6-key proposal:** `build-secret-name` (kaniko
catalog Task doesn't expose a secret-volume option without forking) and
`pvc-size` (workspace size is set at PipelineRun creation, before the
pipeline reads outpost.build.yaml) are out of scope; the remaining 4
keys (dockerfile / context / buildArgs / extraArgs) cover the cited
pain points — monorepo subpath, private mirror tokens, large-build
flags.

**Zero-regression:** absent file → v0.2 defaults (./Dockerfile + ./ +
platform's KANIKO_EXTRA_ARGS) preserved exactly.

---

### ✅ Retired in v0.3.0 — EventListener CEL whitelist of `body.repository.url`

**What it was:** a `WEBHOOK_REPO_WHITELIST` → `build_cel_whitelist()`
(`platform/lib/cel-helpers.sh`) → EventListener CEL filter narrowing
which repos a shared `GIT_WEBHOOK_SECRET` could trigger builds for, plus
`scripts/register-webhooks.sh` / `outpost register-webhooks` to register
the provider-side webhook per whitelisted repo.

**Why retired:** the entire inbound-webhook attack surface this item was
defending against is deleted by the v0.3.0 CI/CD engine swap
([ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)) — there
is no shared webhook secret, no CEL filter, no
`scripts/register-webhooks.sh` (deleted), and nothing to register on the
provider side. `platform/lib/cel-helpers.sh` and
`platform/lib/eventlistener-assemble.sh` are deleted along with it.
`WEBHOOK_REPO_WHITELIST`'s *gating* role is replaced by `OUTPOST_REPOS`
(comma-list of `<clone-url>[#branch]`) — but as a reconciliation basis
for `verify.sh`, not a webhook access-control list; there is no
"anyone with the secret can submit any repo URL" failure mode left to
mitigate, because there is no secret.

---

### ✅ Done in v0.2 — kaniko build cache

`platform/lib/registry-config.sh` sets `KANIKO_EXTRA_ARGS` with
`--cache=true --cache-repo=...` for both registry plugins (self-hosted
→ `docker-registry.registry.svc.cluster.local:5000/cache`, aliyun-acr
→ `<acr>/<ns>/cache`). The Pipeline's kaniko step consumes via
`EXTRA_ARGS=${KANIKO_EXTRA_ARGS}`. Verified in
`tests/regression/golden/registry-self-hosted.yaml`.

Cold cache: 30–90 min → warm cache: 5–10 min (matches the original
estimate).

---

### ✅ Done in v0.2, reshaped in v0.3.0 — `outpost verify --app <name>`

`scripts/outpost verify --app <name>` originally covered: ArgoCD
Application sync/health/revision, pods in `apps` namespace filtered by
`app=<name>`, recent PipelineRuns matching `build-<name>-*`, last 10
events in `<name>` namespace.

**v0.3.0 reshape:** ArgoCD Application status and Tekton PipelineRuns no
longer exist. `outpost verify --app <name>` now shows pods + deployed
image tag + recent events in the app's namespace, and points at
`outpost logs sync` (deploy status) and the GitHub Actions UI / runner
journal (build status) instead — there's no single in-cluster object
left that carries "build status" the way a PipelineRun did, since builds
run on the host runner now.

**Still deferred:** "last webhook delivery" — moot, there is no webhook.
The v0.3.0-equivalent ask ("last GitHub Actions run status for this
repo") is partially covered by `verify.sh`'s `ci.workflow.<name>` check
(queries the GitHub API per `OUTPOST_REPOS` entry) but not surfaced in
`outpost verify --app` itself yet.

---

### PR / branch preview environments

**What:** the deploy-branch workflow (`templates/github/outpost-build.yml`,
`on: push` to `OUTPOST_DEPLOY_BRANCH`) always writes to the same
`apps/<repo>/` path in the manifest repo. Two branches pushed close
together would race the manifest repo and silently overwrite each other
— same underlying risk as before the v0.3.0 engine swap, different
trigger mechanism.

**Architecture sketch (updated for v0.3.0):** a second GitHub Actions
workflow triggered `on: pull_request`, running on the same self-hosted
runner, targeting `apps/<repo>-pr<n>/` in the manifest repo, served at
`<repo>-pr<n>.apps.<root>` via the existing wildcard. The main-branch
workflow and path stay unchanged. Lifecycle: clean up PR namespaces on
PR close (a workflow step `on: pull_request: types: [closed]`, or a
small addition to `manifest-sync` that prunes PR-suffixed app dirs past
an age threshold).

**Why:** PR preview is the most-asked DX feature in our user base;
"open a PR, get a deployment" is competitive table stakes vs Vercel /
Railway / Coolify.

**Cons:** complexity creep (cleanup, namespace churn, quota conflict
with main `apps`), wildcard cert (already covered by Cloudflare).

**Milestone:** v0.3 if there's appetite; could be its own RFC.

---

## ✅ Done in v0.3 — notify-runner interim (script extraction + single-source signing)

The 80-line inline bash in `core/k8s/05-tekton/notify-task.yaml` is now
`scripts/notify-fanout.sh` (POSIX sh, shellcheck-clean, 10 bats tests).
The notify-task shrinks from 144 → 84 lines. `platform/lib/sign-webhook.sh`
is now the single source of truth for HMAC math — the previously
mirrored signing logic in the Task YAML is gone. Both scripts are
mounted via a single `notify-runner-scripts` ConfigMap, created in
`bootstrap.d/09-test-gate.sh` (same split pattern as
`update-manifest-task` and `task-read-build-config`).

**Editability + Supply-chain + Testability:** all 3 covered. **Performance
(5-10s apk-add per PipelineRun)** is the one cost remaining — see the v0.4
follow-up below.

### ⏳ v0.4 follow-up — bake the actual `outpost/notify-runner` image

**What's left:** kill the per-PipelineRun apk-add by baking a tiny image
with `jq curl gettext openssl coreutils bash` pre-installed.

**Concrete sketch:**
- `core/images/notify-runner/Dockerfile` based on `alpine:3.20`, pinned
  digest. `COPY scripts/notify-fanout.sh /usr/local/bin/` and
  `COPY platform/lib/sign-webhook.sh /usr/local/bin/`.
- Build + push during bootstrap Phase 9 to the active registry plugin's
  host (self-hosted → in-cluster, ACR → ACR). Or publish to GHCR once
  and skip the local build step.
- `notify-task.yaml` step `image:` flips to
  `<registry>/outpost/notify-runner:<pinned-digest>`. The volumeMounts
  for the scripts ConfigMap can be dropped (scripts now live in the
  image). The `apk add` line goes away.

**Depends on:** decide publish strategy (in-cluster bake vs GHCR
release). Recommended: GHCR — eliminates per-install build cost.

**Milestone:** v0.4

---

## ✅ Done in v0.3 — per-kind plugin contract enforcement

`tests/bats/plugin-contract-per-kind.bats` dispatches on the `kind:`
field of each `plugin.yaml` and asserts per-kind required extras:
- `notification` → `argocd-cm-fragment.yaml` + `argocd-secret-fragment.yaml`
- `git-provider` → `trigger.yaml` (since v0.3 EventListener assembly)
- `registry` / `test-runner` / `rollout` → none

Negative test catches accidental copy-paste leftovers (e.g. a
`git-provider` plugin shipping `argocd-cm-fragment.yaml`).
`plugins/README.md` "Authoring" section updated with a per-kind
required-files table. New `kind:` value lands → dispatch test fails
loudly until a deliberate branch is added.

---

## ✅ Done in v0.3 — `outpost` CLI install (phase 1: `make install`)

Top-level `Makefile` ships `install` / `uninstall` / `version` / `help`.
`make install` is idempotent (re-run = no-op), validates that
`scripts/outpost` is executable, mkdir's the PREFIX dir, refuses to
clobber non-symlink strangers, replaces stale symlinks pointing
elsewhere, warns when `PREFIX` isn't on `$PATH`. `make uninstall` is
ownership-aware — only removes a symlink that points at this repo's
`scripts/outpost` (so the user can't accidentally `make uninstall`
some other `outpost` binary). 11 bats tests in
`tests/bats/makefile.bats` cover happy path + idempotency + 4 refusal
cases. README/zh-CN updated.

### ⏳ v0.4 follow-ups — phases 2 + 3 (community-driven)

2. **Homebrew formula** — `brew install smithyhaus/outpost/outpost` via
   a `homebrew-outpost` tap repo. Effort: ~1h CC, needs a tap repo
   under the org.
3. **GitHub Release artifact** — tag-cut a release with a
   self-contained `outpost` shell binary (no dependency on the repo
   checkout). Curl-installable. Effort: ~2h CC, needs a CI workflow.

Adoption-gated; phase 1 covers near-term need.

---

## ✅ Done in v0.4 — `outpost doctor` ex-ante diagnostic

Shipped as v0.4 Phase 2 (`fe1505e`, see
`docs/prp/reports/outpost-v0.4-phase2-doctor-preflight-report.md`).
`bash scripts/outpost doctor` (and the standalone `doctor.sh`) runs
*before* `bootstrap.sh` and mirrors `verify.sh`'s structure — human +
`--json` output, exit `0`/`1`/`2`, fully read-only/idempotent, plus a
`fix_hint` per check. Covers the failure modes that used to only
surface mid-bootstrap: host port collisions (5432/6379/5672/9308/15672)
with the actual `port_holder` process, Docker daemon down,
`host.docker.internal` DNS resolution (full-mode/WSL2), disk free in
`/var/lib/docker`, and for full mode `ROOT_DOMAIN` DNS resolution +
`CF_TUNNEL_TOKEN` format. Pure check logic lives in
`platform/lib/doctor-checks.sh` (unit-tested); `doctor.sh` is the
orchestrator. 166/166 bats tests passing across the full suite.

---

## CHANGELOG.md + Conventional-Commits → release-notes automation

**What:** Today the repo has no `CHANGELOG.md` and no `VERSION` file.
`README.md` says "v0.1.0" while `TODOS.md` has 5 entries marked
"✅ Done in v0.2", and `scripts/outpost version` only prints the git
SHA. There's no single place a user can read "what landed between
v0.1 and v0.2."

**Concrete TODO (v0.3, two layers):**
1. **Static (this PR):** Create `CHANGELOG.md` following
   [Keep a Changelog](https://keepachangelog.com/). Backfill v0.2
   from the existing `## ✅ Done in v0.2 — …` headings in `TODOS.md`
   (they're already written prose; just lift). Create a top-level
   `VERSION` file (`0.2.0`). Wire `scripts/outpost version` to read
   `VERSION` *and* git SHA.
2. **Automated (later):** Adopt Conventional Commits (already mostly
   in use — `feat:` / `fix:` / `docs:` / `refactor:`). Add a
   `.github/workflows/release.yml` that on tag push generates release
   notes from `git log` between the previous tag and this tag,
   grouped by type.

**Why:**
- README's current "v0.1.0" claim is false (5 features shipped in v0.2).
  New users open the repo, see v0.1.0, can't reconcile with the
  `bootstrap.d/` refactor or the Phase 9 plugins.
- Without a CHANGELOG, every release requires hand-summarizing the
  diff — already a friction point on the v0.2 cut.
- Issue template (`.github/ISSUE_TEMPLATE/bug.yml`) hardcodes
  `"v0.1.0 / commit abc1234"` as the version placeholder. Either
  pin a version that gets bumped, or just say `"see VERSION"`.

**Pros:** Cheap; clears a real onboarding confusion; future releases
write themselves.

**Cons:** Conventional-commit enforcement (PR-time hook) is a separate
optional layer; without it the release-notes quality depends on
contributors writing good messages. Suggest: enforce in CI only on
the v0.4 cycle, give v0.3 time to settle the convention.

**Context:** existing commits already follow `feat: / fix: / docs: /
refactor: / chore: / test:` — the convention exists in practice,
just not in writing. `CONTRIBUTING.md` does NOT currently document
this; add a short section.

**Depends on:** none. The static piece (CHANGELOG + VERSION + outpost
version + bug.yml placeholder) is < 30 min CC.

**Milestone:** v0.3 (static); v0.4 (automation)

---

## Make `upgrade.sh` actually work in full mode (scope shrunk in v0.3.0)

**What:** `upgrade.sh` today is 5 lines: `docker compose pull && up -d`.
That covers the Compose layer (PG / Redis / RabbitMQ / Manticore /
cloudflared / caddy in `local` mode; `cloudflared` + `caddy` only in
`full` mode's `edge` profile) but does *nothing* for the k3s layer.

**Scope shrunk by the v0.3.0 CI/CD engine swap
([ADR-0003](docs/decisions/0003-github-actions-engine-swap.md)):**
ArgoCD, Tekton, and Argo Rollouts (dashboard tier) are deleted outright —
their vendor manifests
(`core/k8s/vendor/argocd-install-v3.4.5.yaml`,
`tekton-pipeline-v1.14.0.yaml`, `argo-rollouts-dashboard-install-v1.9.0.yaml`)
are gone, so there is nothing left to version-drift-track for them. The
remaining k8s-layer upgrade surface is genuinely small: Sealed-Secrets
controller (`core/k8s/vendor/sealed-secrets-controller-v0.38.4.yaml`,
still vendored + pinned), Testkube (helm-installed when
`TESTKUBE_MODE=oss`), buildkitd/registry (`core/k8s/08-buildkit/`,
`plugins/registry/`), and the `outpost-ci` glue itself (`bootstrap.d/08-ci.sh`
is already idempotent re-`apply`).

**Why still a real (smaller) gap:** a full-mode user running
`bash upgrade.sh` after a Sealed-Secrets CVE announcement still only
refreshes the Compose edge layer — the k3s layer is silently unchanged.
Smaller blast radius than before, but the silent-failure shape is
unchanged.

**Concrete TODO (revised, smaller scope):**
- `upgrade.sh` becomes mode-aware: `local` mode keeps current behavior;
  `full` mode also re-applies `core/k8s/vendor/sealed-secrets-controller-*.yaml`
  and (if `TESTKUBE_MODE=oss`) runs `helm upgrade testkube`, then
  re-runs `bootstrap.d/08-ci.sh`'s idempotent `kubectl apply` steps
  (buildkitd, `core/k8s/03-ci/*`, the runner registration check) so a
  drifted CI engine also gets caught, not just the data-layer bridge Services.
- Define the vendor-pin bump procedure for the one CRD that remains
  (Sealed-Secrets): fetch new upstream release → save under
  `core/k8s/vendor/<name>-vX.Y.Z.yaml` → update the `bootstrap.d`
  reference → PR.

**Depends on:** none.

**Milestone:** v0.4

---

## README demo — asciinema or animated GIF

**What:** README is currently 250+ lines of prose tables. No motion
asset. New users hitting the GitHub page in 2026 expect a 20–40s
visual showing `bash bootstrap.sh` going from empty box to live
`INFRA.md` with connection strings (local mode is perfect for this —
no Cloudflare setup needed in the demo).

**Concrete TODO:**
- Record a local-mode bootstrap with asciinema (`asciinema rec`) on a
  fresh Docker-installed VM, edit out the dead time, embed in README
  above the existing "Quick start" section.
- Or: a GIF (smaller, plays inline in GitHub README). Trade-off:
  asciinema embeds via SVG and stays text-selectable; GIF is universal.
- Suggested copy: "0 → working Postgres + Redis + RabbitMQ + Manticore
  in 90s" with the timestamps visible.

**Why:** the local-mode value prop is hard to convey in text. The
demo is the highest-ROI single doc change for adoption.

**Pros:** Cheap (~30 min CC + the actual recording), no code change.
Lives in `docs/assets/` so it can be regenerated per release.

**Cons:** Assets bloat git history. Mitigate: keep under 1 MB; use
git LFS if you go GIF + record at multiple breakpoints.

**Context:** existing README has good information density but no
visual hook. Compare to projects like `supabase/cli`, `tilt-dev/tilt`,
`vercel/turbo` — all lead with a 20-second visual.

**Depends on:** none.

**Milestone:** v0.3

---

## Opt-in anonymous telemetry

**What:** Add a single optional env var `OUTPOST_TELEMETRY=anonymous`
(default: unset = off) that pings a one-line JSON event on
`bootstrap.sh` success and on each `outpost <subcommand>` invocation.
Payload: `{plugin_set, os, mode, outpost_version, run_id_random}`.
**Never** sends domain, repo URL, tokens, paths, or anything identifying.

**Why:** today there's no way to know which `REGISTRY_PLUGIN` /
`GIT_PROVIDER_PLUGIN` / notification provider combinations are actually
used in the wild. v0.4 prioritization is therefore guesswork. A simple
opt-in counter is enough to decide whether `gitlab` plugin gets
investment vs `aliyun-acr`.

**Pros:** data-driven roadmap; cheap to implement (~1h CC); fully
opt-in so privacy posture stays clean.

**Cons:**
- Even opt-in telemetry has a trust cost. Mitigate: ship with default
  off, document exactly what's sent, link to the (open-source) ingest
  endpoint, support `OUTPOST_TELEMETRY=off` as an explicit no.
- Requires an ingest endpoint someone has to operate. Options:
  - Self-hosted on the same Outpost (eat your own dog food) — visible
    in `verify.sh`.
  - GitHub Issues API: post a one-line comment to a "telemetry"
    issue. Cheap, no infra to run, but throttled.
  - Cloudflare Workers free tier — already a Cloudflare-shop project.

**Context:** ECC has the broader `~/.gstack/analytics/skill-usage.jsonl`
pattern (local-only telemetry; user can read & opt out by deleting
the file). Could adopt the same local-only pattern as v0.3 and only
add a remote-sink option in v0.4 once the schema is stable.

**Sketch:**
- `platform/lib/telemetry.sh` exports `emit_telemetry "event_name" k=v ...`
- Honor `OUTPOST_TELEMETRY={off|local|anonymous}` (default: off; local
  writes to `~/.outpost/usage.jsonl`; anonymous additionally posts to
  the ingest endpoint).
- Document in `README.md` §Privacy.

**Depends on:** decision on ingest strategy (none / local-only /
hosted). Recommend: start with `local` mode in v0.3, `anonymous`
remote in v0.4 after dogfooding the schema.

**Milestone:** v0.3 (local mode); v0.4 (anonymous remote)

---

## ✅ Done in v0.5 — application onboarding primitives (env-driven + no-clone)

Three commits delivered the "no-clone deployment" workflow:

- `refactor(caddy): env-driven routes + Caddyfile.d/ fragment dir`
  (commit `dd82061`) — `core/compose/Caddyfile` no longer carries per-app
  routing knowledge; built-in services use `{$VAR:default}` for both host
  prefix and upstream container:port. `core/compose/Caddyfile.d/*.caddy`
  fragments are mounted via `import`; rendered fragments are gitignored.
- `feat(onboard): outpost.app.yaml schema + onboard CLI` (commit `e550b73`)
  — app-side declarative descriptor with JSON Schema, `outpost onboard
  <repo>` reads it and renders Caddy + compose artefacts.
- `feat(distribution): one-shot install.sh + LLM-side skill template`
  (commit `6008c8c`) — `curl -fsSL .../install.sh | bash` with
  `APP_REPO=` chains install + onboard. `docs/onboarding/outpost-app.skill.md`
  ships as a Claude/Cursor skill template.

Two follow-up commits closed the post-review gaps:

- Subdomain prefixes for `argocd` / `hooks` / `registry` made env-driven
  (`ARGOCD_HOST`, `HOOKS_HOST`, `REGISTRY_SUBDOMAIN`) — parity with
  `search`/`mq` already shipped in `dd82061`.
- `spec.k3s.manifest_repo` actually consumed: `outpost onboard
  --manifests-dir <path> --lang <lang>` runs the existing `_manifest_scaffold`
  with the per-app overrides applied via a scoped env subshell. The
  previously schema-declared but unused `manifest_repo` / `manifest_branch`
  / `manifest_path` fields now drive the rendered argocd-application.
- `core/compose/overrides/*.yml` auto-included by `bootstrap.d/04-compose.sh`
  and `status.sh` via `shopt -s nullglob` loop. `outpost onboard` auto-runs
  `docker compose up -d <name>` for the new service (--no-up to opt out).
- `outpost off-board <name>` for inverse cleanup (compose tier).
- `outpost onboard --install-skill` drops the LLM skill template into the
  app repo's `.claude/skills/`.

Total bats coverage added: 5 new files (caddyfile-fragments, onboard-app,
outpost-app-schema, install, env-driven-hosts, compose-overrides, off-board),
~80 cases.

---

## outpost.app.yaml ↔ outpost.build.yaml relationship doc

**What:** App repositories may now carry two outpost-namespaced YAML
descriptors at their root: `outpost.app.yaml` (v0.5 — onboarding /
routing) and `outpost.build.yaml` (v0.3 — Tekton per-app build config).
Their relationship is not documented anywhere obvious; an operator
reading the README cold won't know which goes where.

**Concrete TODO:** add a short table to `i18n/en/docs/05-onboard-project.md`
(and the zh-CN mirror) plus a sentence in `SKILL.md §3 file pointer map`
documenting:
- `outpost.app.yaml`: declarative app metadata, tier, routes,
  k3s.manifest_repo. Read at install time by `outpost onboard`.
- `outpost.build.yaml`: per-app kaniko inputs (dockerfile, context,
  buildArgs, extraArgs). Read at *pipeline-run time* by the Tekton
  `read-build-config` task.
- They're independent files; an app may have either, both, or neither.

**Why:** ambiguity costs ~10 minutes per new contributor every time.
A 20-line doc fix amortises forever.

**Depends on:** none.

**Milestone:** v0.5.1 (docs-only patch release)

---

## install.sh remote distribution + version pinning

**What:** `install.sh` at the repo root works locally; the README
documents `curl -fsSL https://raw.githubusercontent.com/smithyhaus/Outpost/main/install.sh | bash`
as the canonical install path. But:
1. The `main` branch URL is fragile — a botched commit to main breaks
   every fresh install in the world.
2. There's no GitHub Action publishing install.sh to a stable URL
   (e.g. `outpost.sh/install` or a versioned `releases/v0.5/install.sh`).
3. `install.sh` clones `OUTPOST_GIT_REF=main` by default — same fragility.

**Concrete TODO:**
- Add a CI workflow that publishes install.sh under a stable URL on
  every tagged release (GitHub Releases asset is enough; cdn.jsdelivr.net
  also serves raw GitHub content with version pins).
- Default `OUTPOST_GIT_REF` to the latest *tagged* release rather than
  `main`; `install.sh` reads `VERSION` from the tarball if available.
- README updated to recommend the versioned URL for production installs,
  reserving `@main` for early adopters.

**Pros:** any one bad merge to main can't break global installs;
operators can pin to a specific Outpost release.

**Cons:** introduces a release-cadence requirement (today the project
runs from main).

**Depends on:** decision on release cadence (v0.5 = first tagged release?).

**Milestone:** v0.5.1

---

## SCM MCP — migrate from tier=compose to tier=k3s

> **v0.3.0 status note:** SCM MCP remains on `tier=compose` as a known,
> tracked exception — not a silent drift. It is blocked on source-side
> work (no buildable source available for this app during the v0.3.0
> engine swap), not on anything in `infras`. The `outpost.app.yaml`
> tier-contract enforcement described below is unaffected by the CI/CD
> engine swap: `tier=compose` apps still render a Caddy fragment +
> compose override exactly as before (§ below), independent of whether
> CI runs via Tekton or GitHub Actions. When SCM MCP's source becomes
> available, follow the migration steps below as originally written —
> they still apply verbatim except step 3, where `argocd-application.yaml`
> is no longer part of the scaffold (`manifest-sync` reads `apps/<name>/`
> directly; drop that file from the checklist).

**What:** SCM MCP was the first real-project onboard against Outpost
(commit `1b22f1b`, since reverted), and went onto `mcp.<ROOT_DOMAIN>`
via a Caddy fragment + manual Cloudflare Public Hostname. The v0.5.1
tier-contract enforcement makes this an explicit violation: stateless
applications belong on `*.apps.<ROOT_DOMAIN>` via k3s Traefik, not on
top-level subdomains via Caddy. Per-app tier check in
`onboard_app_validate` now rejects the old shape.

**Why it matters:** keeping SCM MCP on `mcp.<ROOT_DOMAIN>` means:
- Every new SCM MCP environment requires manual CF Dashboard work.
- The team can't reuse the existing `*.apps.<ROOT_DOMAIN>` wildcard
  rule that already covers every other app.
- Future maintenance and onboarding docs have a "this is the exception"
  asterisk that pollutes the platform's clean tier story.

**Concrete TODO** (in the SCM MCP repo, not the infras repo):

1. Rewrite `outpost.app.yaml` to match
   `examples/outpost.app.yaml.multiproduct.example`:
   ```yaml
   spec:
     tier: k3s
     k3s:
       manifest_repo: https://github.com/your-org/scm-manifests
   ```
   Remove the `compose:` block and the `routes:` array.

2. In the SCM MCP manifests repo, write `apps/scm-mcp/`:
   - `deployment.yaml` — one container exposing all 5 ports
     (8080 FE / 8081 API / 8090 SCM Cloud / 8091 SCM 3.0 / 8092 LinkMind DI)
   - `service.yaml` — one Kubernetes Service with all 5 ports named
   - `ingress.yaml` — Traefik IngressRoute on
     `Host(`mcp.apps.<ROOT_DOMAIN>`)` with multiple Rule entries:
     - `PathPrefix(`/scm-cloud/mcp`)` → port 8090
     - `PathPrefix(`/scm-3/mcp`)` → port 8091
     - `PathPrefix(`/linkmou-di/mcp`)` → port 8092
     - `PathPrefix(`/dash/api`)` → port 8081
     - `PathPrefix(`/`)` (catch-all) → port 8080 (Dashboard FE)
   - `kustomization.yaml` (let `outpost manifest scaffold` generate)
   - `argocd-application.yaml` (ditto)

3. Run from the SCM MCP repo root:
   ```bash
   outpost onboard . \
     --manifests-dir ~/code/scm-manifests \
     --lang go
   ```
   Then commit + push the manifests repo; ArgoCD picks up the new app.

4. Wait for ArgoCD to Sync + verify Healthy. Public URL becomes
   `https://mcp.apps.<ROOT_DOMAIN>` automatically (CF wildcard).

5. Once traffic is confirmed on the new path:
   - Remove the manual `mcp.<ROOT_DOMAIN>` Public Hostname from
     Cloudflare Dashboard.
   - Run `outpost off-board scm-mcp` on the infras host to remove any
     lingering Caddyfile.d/scm-mcp.caddy and overrides/scm-mcp.yml.

6. Update SCM MCP repo's `.claude/skills/outpost-deploy.skill.md` to
   the latest template (or run `outpost onboard . --install-skill
   --force` once the migration lands).

**Depends on:** SCM MCP team availability; nothing on infras side.

**Milestone:** SCM MCP next planning slot (no infras dependency).

---

## Unify `decommission` to cover compose-tier apps

**What:** `outpost decommission <app>` was designed for k3s-tier apps
(removed the manifest-repo entry for the app — pre-v0.3.0 this was an
ArgoCD Application; post-v0.3.0 it's the `apps/<name>/` directory
`manifest-sync` reads). v0.5 added `outpost off-board <name>` for
compose-tier cleanup (Caddyfile fragment + override + container removal).
Operators now have two commands for "remove this app" and the right
choice depends on the app's tier.

**Concrete TODO:** merge into a single `outpost decommission <name>`
that reads the on-disk artefacts (Caddyfile.d/<name>.caddy AND/OR
`apps/<name>/` in the manifest repo) and runs the appropriate cleanup
branch. Keep `off-board` as a backwards-compat alias for one release,
with a deprecation hint.

**Pros:** one command, no tier guess.

**Cons:** the unified command needs read access to the manifest repo
to detect the k3s case — same access decommission already requires.

**Depends on:** the unified decommission needs to handle the case where
an app is BOTH tier=compose AND has k3s manifests (probably an error /
warn-and-skip).

**Milestone:** v0.6

---
