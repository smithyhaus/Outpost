# TODOS

Items deliberately deferred from v0.1. Each entry has enough context for
a future contributor to pick it up cold.

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
