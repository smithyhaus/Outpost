# TODOS

Items deliberately deferred from v0.1. Each entry has enough context for
a future contributor to pick it up cold.

---

## Replace deprecated kaniko catalog Task

**What:** `core/k8s/05-tekton/pipeline-build.yaml` references the
upstream Tekton catalog `kaniko` Task (currently version 0.7). That
Task is marked `tekton.dev/deprecated: "true"` upstream. The pinned
executor image (`gcr.io/kaniko-project/executor:v1.5.1`) is multi-arch
(linux/amd64 + linux/arm64 + linux/ppc64le, verified via
`docker manifest inspect`), so it still works on Apple Silicon k3d for
v0.1, but it won't get security/CI updates from upstream.

**Concrete TODO:** either
- Switch to a maintained build Task (Buildah, BuildKit, `image-build` from
  Tekton's newer catalogs); requires deciding whether to allow privileged
  containers in the cluster, or
- Bake our own minimal Task wrapping a recent `gcr.io/kaniko-project/executor`
  image (v1.20+ pulls security fixes).

**Today's user-visible workaround:** none required — the deprecated
Task functions correctly. Just be aware upstream may eventually delete it.

**Depends on:** none.

**Milestone:** v0.2

---

## Multi-provider EventListener wiring (Gitee-only today)

**What:** The git-provider plugins (`plugins/git-provider/{gitee,github,gitlab}`)
each emit a `<provider>-trigger-fragment` ConfigMap describing how the
EventListener's `triggers:` block should be assembled for that provider.
But `core/k8s/05-tekton/eventlistener.yaml` is currently a **hardcoded
Gitee** EventListener — it ignores those fragments. Result: today
`GIT_PROVIDER_PLUGIN=github` and `GIT_PROVIDER_PLUGIN=gitlab` apply the
plugin's TriggerBinding + ConfigMap, but the EventListener still routes
through `gitee-push-binding` and the `X-Gitee-Token` CEL filter.

**Concrete TODO:** in `bootstrap.sh` Phase 8, instead of applying the
hardcoded `eventlistener.yaml`, read the active plugin's
`<provider>-trigger-fragment` ConfigMap, splice its `trigger.yaml` block
into a generic EventListener template, and apply the result. Drop the
hardcoded `eventlistener.yaml`. Move webhook-secret-substitution into
the plugin layer (each plugin already has the right CEL filter).

**Pros:** `GIT_PROVIDER_PLUGIN` actually means something for github /
gitlab. Plugin model is honest.

**Cons:** small Bash YAML manipulation (yq dependency).

**Today's user-visible workaround:** keep `GIT_PROVIDER_PLUGIN=gitee`
(the default) — the only fully wired path in v0.1. The provider-agnostic
Secret rename (`gitee-credentials` → `git-credentials`,
`gitee-manifest-repo` → `git-manifest-repo`) and `${GIT_HOST}` parameter
make the eventual github/gitlab cutover purely local to this file.

**Depends on:** none.

**Milestone:** v0.2

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

## AI-tool ecosystem coverage (AGENTS.md / Cursor / Copilot)

**What:** Author additional AI metadata files alongside the existing
`SKILL.md` (Claude) and `llms.txt`:
- `AGENTS.md` — Cursor / Cline convention
- `.github/copilot-instructions.md` — GitHub Copilot Workspace

Generate them from `SKILL.md` rather than maintain three independent
sources.

**Why:** v0.1 chose "SKILL.md + llms.txt only", which trades away ~80% of
the AI-tool ecosystem. Adding the two formats above is cheap (≤30 min
CC time) once we have a generator.

**Pros:**
- Cursor / Cline / Aider users get first-class onboarding.
- Demonstrates that "AI-friendly by design" is real, not lip service.

**Cons:**
- Three docs to keep in sync. Mitigation: a generator script that derives
  the secondary files from `SKILL.md`.

**Context:** `SKILL.md` already follows a structured layout (Identity →
Architecture → File pointer map → Invariants → Operating principles →
Verification → Common tasks → Out of scope). A generator can extract
these sections and reformat per target tool.

**Depends on:** none.

**Milestone:** v0.2

---

## Helm chart packaging

**What:** Ship a Helm chart for the k3s layer (ArgoCD + Tekton + bridges +
plugins) so operators on existing clusters can install just that layer
without using `bootstrap.sh`.

**Why:** Some users already have k3s / k8s clusters. They want the
GitOps + Tekton parts but not the Compose data layer. A Helm chart is
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

## i18n drift detection (CI workflow)

**What:** A GitHub Actions step that warns if the file set under
`i18n/<lang>/` diverges between languages, or if a file in one language
has been edited more recently than its peer.

**Why:** Without automation, EN and zh-CN drift over months. Today we rely
on PR review, which is fragile.

**Pros:**
- Cheap to implement.
- Prevents the most common bilingual-doc decay.

**Cons:**
- False positives when a translation legitimately lags by one PR.
- Requires git history analysis (modified time) — not just file presence.

**Context:** `tests/lint.sh` is the natural home for the file-presence
check. Drift-by-mtime is a separate workflow step.

**Depends on:** none.

**Milestone:** v0.2

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

## ADR (Architecture Decision Records)

**What:** Add `docs/decisions/` containing ADRs for the major
architectural choices (two-layer split, cloudflared as the only ingress,
plugin model, etc.).

**Why:** As contributors arrive, "why not Helm-chart everything" / "why
not k8s for data services" / "why Cloudflare specifically" will recur.
ADRs preempt the discussion.

**Pros:** durable institutional knowledge.

**Cons:** writing burden upfront.

**Context:** [Michael Nygard's ADR format](https://github.com/joelparkerhenderson/architecture-decision-record).

**Depends on:** none.

**Milestone:** v0.2 if a maintainer has appetite; otherwise community

---

## v0.3 from app-team review

The five items below were raised by the app-team review pass on v0.2
(see `i18n/en/docs/proposals/cicd-test-gate.md` review thread). Each is
a real DX gap or hardening opportunity.

### Per-app build params (`outpost.build.yaml`)

**What:** Pipeline currently hardcodes `Dockerfile`, `./` context, no
`--build-arg`, no `--secret` mount, fixed 5Gi PVC, fixed EXTRA_ARGS.
Add 6 optional Pipeline params (dockerfile / context / build-args /
build-secret-name / pvc-size / extra-args), all driven from a repo-root
`outpost.build.yaml` (same shape as `outpost.test.yaml`). No file → use
defaults.

**Why:** monorepos can't build sub-paths today; private npm/pypi tokens
can only get baked into base images; large Maven/.NET projects blow the
5Gi PVC.

**Milestone:** v0.3

---

### EventListener CEL whitelist of `body.repository.url`

**What:** Today a single `GIT_WEBHOOK_SECRET` covers every project on
the Outpost. Anyone with the secret can submit ANY `body.repository.url`
and trigger a kaniko build of arbitrary code (compute / registry abuse;
manifest update fails because they don't have manifest-repo write).

**Why:** narrow the blast radius without going to per-repo secrets
(which the user has to update across N repos every rotation).

**Concrete TODO:** add a CEL filter
`body.repository.git_http_url in ['<repo1>', '<repo2>', ...]` populated
from `.env`. Expand list per-onboard.

**Milestone:** v0.3

---

### kaniko build cache

**What:** `pipeline-build.yaml`'s kaniko step has no `--cache=true
--cache-repo=...`. Every push pulls base images and rebuilds every layer.
Java/.NET on China-network cold-cache routinely hit the 90m timeout
(observed empirically — that's why the timeout is 90m).

**Concrete TODO:** carve a `cache/` path in the self-hosted registry
(`docker-registry.registry.svc.cluster.local:5000/cache`); pass
`--cache=true --cache-repo=<host>/cache` in EXTRA_ARGS for the
self-hosted plugin. ACR has its own cache; just point at the same path.

**Expected impact:** 30~90 min builds → 5~10 min on warm cache.

**Milestone:** v0.3

---

### `verify.sh --app <name>`

**What:** verify.sh currently only runs platform-level checks. App teams
need an app-scoped variant: ArgoCD Application status, latest PipelineRun
status, last webhook delivery (currently not stored anywhere — would need
EventListener log scraping or a small ring buffer), `apps/<name>` pod
ready states, last 10 events in `<name>` namespace.

**Why:** an app team onboarded today has to compose 5 kubectl commands
to know if their app is healthy. Self-service triage matters.

**Milestone:** v0.3

---

### PR / branch preview environments

**What:** Today the gitee CEL filter accepts any non-tag branch push, but
the pipeline always writes to the same `apps/<repo>/` path in the manifest
repo. Two PRs on different branches race the manifest repo and silently
overwrite each other.

**Architecture sketch:** EventListener routes PR/MR events through a
different TriggerTemplate that creates `PipelineRun`s targeting
`apps/<repo>-pr<n>/`, served at `<repo>-pr<n>.apps.<root>` via the
existing wildcard. main-branch path stays unchanged. Lifecycle: clean
up PR namespaces on PR close (a small Tekton finally task).

**Why:** PR preview is the most-asked DX feature in our user base;
"open a PR, get a deployment" is competitive table stakes vs Vercel /
Railway / Coolify.

**Cons:** complexity creep (cleanup, namespace churn, quota conflict
with main `apps`), wildcard cert (already covered by Cloudflare).

**Milestone:** v0.3 if there's appetite; could be its own RFC.

---
