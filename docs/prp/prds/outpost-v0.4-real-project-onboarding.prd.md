# Outpost v0.4 — Real-Project Onboarding

> **From "demo green" to "real-project green":** close the gap between what `bootstrap.sh` claims to deliver and what an actual application needs to actually go live.

## Problem Statement

Outpost v0.2 ships a bootstrap that goes "all green" in demo mode, but when its own author tried to onboard a real project (SCM MCP), it took ~6 `ci: re-trigger` commits, ~21 hand-written YAML files, a custom `scripts/onboard.sh`, a 270-line `ONBOARDING-CICD.md`, and eventually a pause from exhaustion — without ever reaching first green deploy. Until a real project can be onboarded end-to-end without bespoke scaffolding, outpost cannot honestly claim its three core capabilities (one-shot base services / one-shot k3s CI/CD / Cloudflare exposure) work outside a demo.

## Evidence

- **SCM MCP commit cluster (Apr 28 – May 10, 2026)** shows ≥ 12 distinct failure walls hit during onboarding:
  - 6 × `ci: re-trigger after …` commits (pipeline params, kaniko host, timeout, gitconfig, PSA, network egress)
  - `9c6f639 feat(deploy): 适配 ufaster GitOps` adds **21 files** by hand (Dockerfile + `deploy/k8s/*.yaml` × 15 + ONBOARDING + Compose) — none of which are scaffolded by outpost today
  - `b0b1ad4 feat(onboard): scripts/onboard.sh 一键 provision (建库 + sealed-secret)` — the author wrote a 95-line shell script to do what outpost should have shipped as `outpost onboard`
  - `40d864c fix(deploy): specs 改回入 git (build-time fetch 在 CI 网络下不可行)` — reverted 28 spec files into git because outpost's build network couldn't reach external services, with no preflight warning
- **`ONBOARDING-CICD.md` § "已知问题清单"** explicitly lists 5 outstanding outpost-side issues that block ArgoCD sync, break Next.js silently, race dev branches into prod, etc.
- **`scripts/outpost`** today exposes 9 commands (`status / verify / open / new-app / logs / rollback / seal / decommission / version`) — **missing `onboard`**, which is the very command the user had to hand-roll.
- **Stated user quote (May 20, 2026)**: "我的 mcp 没有跑成功，在 cicd 阶段就停掉了…我没有绕开，只是休息了一会。"
- **Project lineage**: between v0.2 and v0.3, the author already shipped 14 fixes triggered by SCM MCP feedback (see `TODOS.md` ✅ entries) — this PRD codifies the remaining real-project gap into a single coherent v0.4.

## Proposed Solution

Treat v0.4 as a **closing / finishing release**, not an exploration. Hold the architecture exactly as v0.2 designed it (two-layer Compose + k3s, shared substrate, single Cloudflare Tunnel, five-plugin model, bash CLI) and spend the entire version budget on three things: **(1)** write the missing `outpost onboard <repo>` command that absorbs everything `SCM MCP/scripts/onboard.sh` and `ONBOARDING-CICD.md` do today, **(2)** plug the 12 documented failure walls at their source files (preflight, Tekton tasks, EventListener CEL, ConfigMap reconcile, build-arg schema), and **(3)** make the AI-agent contract explicit (canonical `ONBOARDING.md`, structured JSON output everywhere, idempotent steps, semantic error codes with fix hints). Validate by running the resulting outpost against an acceptance gauntlet of at least 4 real projects before tagging.

## Key Hypothesis

We believe **closing the 12 documented onboarding walls + shipping `outpost onboard <repo>` + an explicit AI-agent contract** will make **a real project go from `git init` (or `git clone` of a legacy repo) to a first green deploy at `https://<app>.apps.<domain>` in < 10 minutes, with no bespoke shell scripts or hand-written manifests, on an already-bootstrapped outpost** for the project author and his small team.

We'll know we're right when:
- zff personally re-onboards SCM MCP using only `outpost onboard` (no hand edits), reaches first green deploy in < 10 min
- zff onboards 2 additional new projects (1 Go service, 1 Next.js app) the same way
- zff onboards 1 legacy project (an existing repo not designed for outpost) with the same command in < 15 min
- one teammate, following only `ONBOARDING.md`, onboards a 5th project unaided

## What We're NOT Building

- **PR / branch preview environments** — already deferred in `TODOS.md`; routes to v0.5
- **Helm chart packaging** — already deferred in `TODOS.md`; routes to v0.5
- **Tunnel plugin abstraction** (frp / tailscale / ngrok) — already deferred in `TODOS.md`; routes to v0.5
- **Cross-machine fleet sync** (office Mac + home Mac + VPS sharing one outpost state) — real pain raised by user in Phase 2, but scoped out: solving "接得了真项目" first is already a full version
- **GUI / Web configuration console** — outpost stays CLI-first; dashboards (Argo CD / Tekton / Rollouts) remain read-only
- **CLI language rewrite** — bash CLI preserved; `infras.sln` stays as VS wrapper for the C# example only
- **Per-project independent base infrastructure** (the "N PG instances" option) — explicitly decided against; outpost continues the shared-substrate route (1 PG / 1 Redis / 1 MQ per host, isolation via DB / keyspace / vhost)
- **Enterprise compliance / SOC2 / on-prem hardening bundle** — out of target audience
- **Opt-in remote telemetry** — v0.4 may add `local`-only usage log; remote sink stays in v0.5
- **Multi-tenant outpost** (one outpost serving several humans with isolation) — not a goal

## Success Metrics

| Metric | Target | How Measured | Status of baseline |
|--------|--------|--------------|--------------------|
| Real-project onboarding wall-clock (human, baseline = outpost already bootstrapped) | < 5 min for greenfield / < 10 min for legacy | Stopwatch on the 4 gauntlet projects | Today: hours + manual scaffolding |
| Real-project onboarding wall-clock (AI agent, unattended) | < 15 min | Claude Code session log on at least 2 of the 4 gauntlet projects | Today: not possible |
| Hand-written YAML files per onboarded project | 0 (everything from templates) | `git diff --stat` of manifests repo after onboard | Today: ~21 files (SCM MCP `9c6f639`) |
| `ci: re-trigger after …` commits per onboarded project | 0 | git log scan post-onboard | Today: 6 (SCM MCP) |
| Gauntlet pass rate (G1 + G2 + G3 + G5) | 4 / 4 | Manual run before tagging | Today: 0 / 4 |
| `outpost doctor` exit before bootstrap if env is bad | All 12 walls' preflight conditions caught ex-ante | Synthetic-failure tests | Today: walls surface mid-pipeline |

## Open Questions

- [ ] **OQ-1**: Canonical AI-onboarding doc — merge `SKILL.md` + `AGENTS.md` + `i18n/*/docs/05-onboard-project.md` into one authoritative `ONBOARDING.md`, or promote `SKILL.md` as the single entry and have the others stub to it?
- [ ] **OQ-2**: `outpost onboard` needs a wider PAT scope than current `GIT_TOKEN` (must include `repo:webhook:write`). Force token re-issue, or gracefully degrade to "we couldn't register the webhook; here's a 3-line instruction for the UI"?
- [ ] **OQ-3**: Frontend SSR/SPA build-args (Next.js `NEXT_PUBLIC_*`, Vite `VITE_*`, etc.) — extend `outpost.build.yaml` with a `frontend.envArgs` schema, or document-and-warn only?
- [ ] **OQ-4**: Version naming — v0.4 (incremental, matches TODOS) or v1.0 (semantically: "first version that handles real projects")? Or 0.4 → 0.5 → 1.0 three-step where 1.0 only ships after cross-machine fleet sync?
- [ ] **OQ-5**: Cross-machine fleet sync — confirmed out of v0.4; revisit timing after v0.4 ships?
- [ ] **OQ-6**: Webhook secret rotation UX — today `GIT_WEBHOOK_SECRET` is shared across all repos. After v0.4 makes onboard easy, rotation becomes "I have 8 webhooks to update". Does v0.4 need `outpost rotate-webhook-secret`?
- [ ] **OQ-7**: Idempotency boundary — when `outpost onboard` is re-run on an already-onboarded app, does it (a) no-op silently, (b) reconcile drift like ArgoCD, or (c) require explicit `--reconcile`?

---

## Users & Context

**Primary User**

- **Who**: zff — software architect with a small team, runs many projects in parallel including AI-assisted greenfield apps (e.g., SCM MCP) and inherited legacy systems. Operates both solo and in team mode. .NET / Python / Go fluent; comfortable on bash; uses Claude Code / AI agents heavily. Sole maintainer of outpost.
- **Current behavior**: when AI lets him spin up a working app in a single afternoon, he hits the infrastructure wall and either (a) writes a one-off `scripts/onboard.sh` per project, (b) hand-edits 20+ manifest YAML files, or (c) parks the project and walks away — as he did with SCM MCP after the CI/CD wall.
- **Trigger**: a new business idea / customer request / inherited maintenance handoff arrives. AI gets the code to "locally runnable" in ~30 min. The infra+pipeline scaffolding is now the bottleneck.
- **Success state**: he hands a repo URL (or `pwd`) to outpost (or to an AI agent invoking outpost), takes a coffee break, and comes back to a working `https://<app>.apps.<domain>` with logs/dashboards/argocd-app-of-apps already wired.

**Secondary User**

- **Teammate** of the primary user — wants to onboard their own project to the shared outpost without needing to read the architecture doc or be on-call to the maintainer. ONBOARDING.md must be enough.
- **AI coding agents** (Claude Code etc.) — operate outpost on the human's behalf. Need machine-parseable output, idempotent commands, and a single canonical doc.

**Job to Be Done**

> When I start a new project, OR take over maintaining a legacy project, I want to throw outpost's onboarding doc at an AI agent (or run a single command myself) so it auto-builds a locally-debuggable + remotely-accessible dev environment for me — so that the infra layer matches the AI-driven coding cadence instead of being the bottleneck.

**Non-Users**

- Enterprise IT / platform engineering departments (outpost is not Rancher / OpenShift / Vela)
- Compliance-bound orgs (finance / govt / SOC 2 mandatory) — outpost has no on-prem hardening bundle
- People unwilling to spend ~$10–100/yr on a domain + Cloudflare account
- Kubernetes experts who want to hand-craft manifests — outpost is opinionated, not a toolkit
- Anyone who refuses CLI — no GUI configuration is on the roadmap

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| **Must** | `outpost onboard <repo-url-or-path>` — end-to-end project onboarding (DB create, sealed-secret render+seal, manifest scaffold, ArgoCD app-of-apps wire, webhook register, wait-for-green) | Replaces the entire `SCM MCP/scripts/onboard.sh` + 21 hand-written YAMLs; this is the version's centerpiece |
| **Must** | `outpost doctor` — ex-ante preflight that catches every documented wall before it surfaces mid-pipeline | TODOS.md v0.3 entry; without this, walls B1-B6 still surface 5 min into pipeline |
| **Must** | Fix 6 × B-class walls in source files: pipeline params restore, kaniko push host hardening, default timeout bump, gitconfig in clone task, PSA labels on `tekton-pipelines` namespace, network egress preflight | The "ci: re-trigger" commits are direct evidence |
| **Must** | Fix 5 × A-class walls by giving `outpost onboard` the primitives: `db create`, `seal-from-template`, `manifest-scaffold`, `webhook register`, `upgrade reconcile-configmaps` | These are the SCM MCP onboard.sh contents |
| **Must** | Fix C-class walls: kustomization integrity check (C1), EventListener CEL pinned to main by default (C3), build-pod egress preflight (C5) | Single-line fixes mostly; high ROI |
| **Must** | Canonical `ONBOARDING.md` at repo root — single AI-agent-readable doc; collapses or redirects from `SKILL.md` / `AGENTS.md` / `docs/05` | Resolves OQ-1; without it AI agents wander |
| **Must** | Structured JSON output for every onboard sub-step + semantic exit codes + `fix_hint` payloads | AI-agent autonomy depends on this |
| **Must** | Idempotency contract on every `outpost onboard` sub-step (partial-failure rerun is safe) | AI retry is the common case, not exceptional |
| **Should** | Frontend build-arg schema in `outpost.build.yaml` (`frontend.envArgs.NEXT_PUBLIC_*` → kaniko `--build-arg`) | Resolves OQ-3 wall C2; without it FE silently breaks |
| **Should** | `outpost rotate webhook-secret` — re-roll `GIT_WEBHOOK_SECRET` and re-register every known webhook | OQ-6; secondary but matters once onboard is easy enough to use frequently |
| **Should** | Acceptance gauntlet committed under `tests/gauntlet/{scm-mcp,go-svc,next-app,legacy-port}/` with reproducible scripts | Turns the success-metric gauntlet into a regression test |
| **Could** | `outpost onboard --dry-run` — preview every file it would write + every API it would call | AI-agent debugging aid |
| **Could** | `outpost.app.yaml` schema in app repo root — declarative app description consumed by onboard | Cleaner than CLI flags for complex apps; can grow incrementally |
| **Won't (this version)** | PR / branch preview environments | Deferred; in TODOS v0.5 |
| **Won't** | Helm chart packaging | Deferred; in TODOS v0.5 |
| **Won't** | Tunnel plugin abstraction (frp / tailscale / ngrok) | Deferred; in TODOS v0.5 |
| **Won't** | Cross-machine fleet sync | Real pain but not this version |

### MVP Scope

Minimum to validate the hypothesis: **all Must-haves above**, validated against the acceptance gauntlet **G1 (SCM MCP) + G2 (Go service) + G3 (Next.js app) + G5 (legacy port)**. G4 (.NET / Java) is nice-to-have; if missing, v0.4 still ships.

### User Flow (critical path, shortest journey to value)

**For the primary user (greenfield)**:
```
0. (one-time, already done) bash bootstrap.sh
1. cd ./my-new-app
2. (write code with AI assistance until make dev passes)
3. outpost onboard .                 # ← new in v0.4
   ├─ doctor: preflight passes (or refuses with fix hint)
   ├─ db: CREATE DATABASE my_new_app (idempotent)
   ├─ secret: render template, kubeseal, push to manifests
   ├─ manifest: scaffold deployment + service + ingress + kustomization
   ├─ argocd-app: write argocd-apps/my-new-app.yaml + commit
   ├─ webhook: POST to git provider API (Gitee/GitHub/GitLab)
   ├─ wait: poll Tekton + ArgoCD until first green or 10-min timeout
   └─ open: print https://my-new-app.apps.<domain> + open browser
4. coffee (≤ 10 min)
```

**For the AI agent**:
```
1. read ONBOARDING.md (single canonical entry)
2. run `outpost doctor --json` → parse, decide
3. run `outpost onboard . --json` → parse each sub-step result
4. on any non-zero exit, read fix_hint, attempt remediation, retry the failing sub-step idempotently
5. report final URL or remaining fix_hint to the human
```

**For the legacy-project owner**:
```
1. cd /path/to/inherited-repo
2. outpost onboard . --legacy        # tells onboard to be tolerant of missing Dockerfile etc.
   └─ detects language, scaffolds Dockerfile from examples/, then proceeds as greenfield
3. iterate
```

---

## Technical Approach

**Feasibility**: **HIGH**. No architecture changes, no new dependencies, no language switch. Every wall has a known-good fix already discovered during SCM MCP. The version is a finishing pass, not exploration.

**Architecture Notes**
- Two-layer Compose + k3s preserved verbatim; `outpost onboard` operates as a thin choreography layer above existing primitives (host PG container, sealed-secrets controller, manifests repo, Tekton, ArgoCD, git provider plugins).
- Plugin contract preserved: existing plugin authors do not need to change code. `git-provider/*/register-webhook.sh` is a new optional file with safe fallback.
- Bash CLI preserved. `scripts/outpost` gains new subcommands (`onboard`, `doctor`, `db`, `rotate`) and a `--json` flag pattern propagated consistently.
- `ONBOARDING.md` becomes the canonical AI-agent entry; `SKILL.md` / `AGENTS.md` shrink to short stubs pointing at it.
- New file: `core/templates/app-skeleton/` — the template tree that `outpost onboard` instantiates into manifests repo (deployment / service / ingress / kustomization / argocd-app / sealed-secret-template).

**Technical Risks**

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| **R1** Per-provider webhook API drift (Gitee, GitHub, GitLab each have different PAT scopes + endpoints) | M | Gracefully degrade to printed instructions if API call fails; ship Gitee first (already the default), GitHub second, GitLab third — partial coverage still beats today |
| **R2** Frontend build-arg schema bloats `outpost.build.yaml` into a frontend-specific monster | M | Keep `frontend.envArgs` as a flat string map; document that complex Vite/Webpack flows can stay manual in `extraArgs[]` |
| **R3** AI-agent <15-min SLO realistic only when bootstrap is already done; cold-start bootstrap remains 5–10 min | H | Explicit SLO baseline = "outpost already bootstrapped"; document cold-start separately as a one-time cost |
| **R4** Idempotency contract harder to enforce in shell than in a typed language | M | Adopt per-step state files (`~/.outpost/state/<app>.json`) so re-runs read prior state; add bats tests covering "rerun after step N succeeded / failed" |
| **R5** Acceptance gauntlet itself rots (gauntlet projects evolve, break) | L | Pin gauntlet projects to specific commits; refresh per release cycle |
| **R6** Scope creep — once `onboard` exists, every wish becomes a flag | M | This PRD's Out-of-Scope list is the contract; new flags require a new PRD |
| **R7** Documentation drift: `ONBOARDING.md` + `SKILL.md` + i18n copies diverge again | M | Single source-of-truth file; `SKILL.md` becomes 5-line stub; reuse existing i18n drift detection from v0.3 |

---

## Implementation Phases

<!--
  STATUS: pending | in-progress | complete
  PARALLEL: phases that can run concurrently (e.g., "with 3" or "-")
  DEPENDS: phases that must complete first (e.g., "1, 2" or "-")
  PRP: link to generated plan file once created
-->

| # | Phase | Description | Status | Parallel | Depends | PRP Plan |
|---|-------|-------------|--------|----------|---------|----------|
| 1 | Foundation hardening | Re-scoped 2026-05-20: B1/B2/B3/B5/B6 already fixed in v0.3 cycle. Fix C3 (webhook pin to deploy branch) + add bats regression locks for all 6 walls | complete | - | - | [plan](../plans/outpost-v0.4-phase1-cicd-wall-hardening.plan.md) · [report](../reports/outpost-v0.4-phase1-cicd-wall-hardening-report.md) |
| 2 | `outpost doctor` ex-ante | Preflight subcommand catching every documented wall before bootstrap or onboard runs; JSON output; idempotent | complete | - | 1 | [plan](../plans/outpost-v0.4-phase2-doctor-preflight.plan.md) · [report](../reports/outpost-v0.4-phase2-doctor-preflight-report.md) |
| 3 | Onboard primitives | New subcommands `outpost db create`, `outpost seal-from-template`, `outpost manifest scaffold` — extracted/generalized from `SCM MCP/scripts/onboard.sh`; each idempotent + JSON | complete | with 4 | 1 | [plan](../plans/outpost-v0.4-phase3-onboard-primitives.plan.md) · [report](../reports/outpost-v0.4-phase3-onboard-primitives-report.md) |
| 4 | Webhook auto-register | `plugins/git-provider/{gitee,github,gitlab}/register-webhook.sh` + graceful manual-fallback path; resolves OQ-2 | pending | with 3 | 1 | - |
| 5 | `outpost onboard <repo>` orchestration | Top-level command that calls 3+4 in sequence, owns state file under `~/.outpost/state/`, supports `--legacy`, `--dry-run`, `--json`; wait-for-green poll loop | pending | - | 2, 3, 4 | - |
| 6 | AI-agent contract | Canonical `ONBOARDING.md` at repo root; semantic exit codes; `fix_hint` JSON schema; `SKILL.md` / `AGENTS.md` shrunk to stubs; resolves OQ-1 | pending | with 7 | 5 | - |
| 7 | Frontend build-arg schema | `outpost.build.yaml` extended with `frontend.envArgs.*` → kaniko `--build-arg` propagation; resolves OQ-3 / wall C2 | pending | with 6 | 5 | - |
| 8 | Acceptance gauntlet | `tests/gauntlet/{scm-mcp,go-svc,next-app,legacy-port}/` — reproducible scripts that run `outpost onboard` against each and verify green; tag-blocker | pending | - | 6, 7 | - |
| 9 | Docs sync + zh-CN parity + CHANGELOG + tag | i18n EN ↔ zh-CN drift checked via existing v0.3 tooling; CHANGELOG entry; VERSION bump; ADR for "shared substrate, not per-project infra" decision | pending | - | 8 | - |

### Phase Details

**Phase 1: Foundation hardening** *(re-scoped 2026-05-20 after codebase exploration)*
- **Exploration finding**: B1 (pipeline params), B2 (kaniko push host), B3 (timeouts), B5 (gitconfig), B6 (PSA baseline) were ALL already fixed during the v0.3 cycle — commits `890032f`, `06b2fbe`, `6a1cba1`/`d9736fa`, `eb5fdc7`, `7e32c13`. Only C3 (webhook fires on any branch) is genuinely open. The CEL ref filter also lives in `plugins/git-provider/*/trigger.yaml`, not `eventlistener-base.yaml` as the PRD originally guessed.
- **Goal**: Fix C3, and lock all 6 walls behind automated regression tests so a future refactor cannot silently re-open them.
- **Scope**: pin the CEL ref filter to a configurable `OUTPOST_DEPLOY_BRANCH` (default `main`) across the `gitee` / `github` / `gitlab` trigger plugins; add the `OUTPOST_DEPLOY_BRANCH` config default + `.env.example` doc; new `tests/bats/cicd-walls.bats` covering B1/B2/B3/B5/B6/C3; fix `eventlistener-assemble.bats` setup() for the new envsubst var.
- **Success signal**: `bats tests/bats/cicd-walls.bats` 11/11 green; no `trigger.yaml` accepts arbitrary branches; full bats suite stays green.
- **Status**: ✅ complete 2026-05-20 — `cicd-walls.bats` 11/11, `eventlistener-assemble.bats` 10/10, full suite 154/154, lint green.
- **Plan**: `docs/prp/plans/outpost-v0.4-phase1-cicd-wall-hardening.plan.md`
- **Report**: `docs/prp/reports/outpost-v0.4-phase1-cicd-wall-hardening-report.md`

**Phase 2: `outpost doctor`**
- **Goal**: Catch failure modes before they cost 5 minutes of pipeline time.
- **Scope**: new `scripts/outpost-doctor.sh` (or inline in router), checks: host ports free, Docker daemon up, `host.docker.internal` resolvable, disk free in `/var/lib/docker`, `ROOT_DOMAIN` resolves, `CF_TUNNEL_TOKEN` looks valid, kaniko multi-arch image reachable, build-pod egress to external services (configurable allow-list), `tekton-pipelines` PSA label set. `--json` output. Idempotent.
- **Success signal**: synthetic-failure tests — kill Docker → doctor red; bind port 5432 → doctor red; bad CF token → doctor red. All with `fix_hint`.
- **Scope corrections (2026-05-20, from codebase exploration)**: (a) host ports are `5432/6379/5672/9308` (Manticore replaced Meilisearch — port was `7700` pre-migration; 9306/9312 also bound but doctor only checks the load-bearing port) — TODOS' `15672` is caddy-proxied, not host-bound; (b) the `tekton-pipelines` PSA-label check is dropped — that label is bootstrap *output*, not a precondition (already regression-locked by `cicd-walls.bats` B6); (c) `doctor.sh` lives at repo root (sibling of `verify.sh`), not `scripts/`; (d) egress check is `--egress`-flag-driven, not a config var.
- **Plan**: `docs/prp/plans/outpost-v0.4-phase2-doctor-preflight.plan.md`
- **Status**: ✅ complete 2026-05-20 — `doctor.sh` + `doctor` subcommand shipped; `doctor-checks.bats` 7/7, `doctor.bats` 5/5, full suite 166/166, lint green.
- **Report**: `docs/prp/reports/outpost-v0.4-phase2-doctor-preflight-report.md`

**Phase 3: Onboard primitives**
- **Prerequisite**: ADR [`0002` — Onboarding primitives belong in the platform](../../decisions/0002-onboarding-primitives-in-platform.md) must be Accepted first. It supersedes commit `c1e1050` ("no onboarding logic in infras") and defines the mechanism-vs-content boundary this phase must hold: outpost ships generic mechanism, the app owns its content.
- **Goal**: Each piece of what `onboard.sh` does today, callable independently and idempotently.
- **Scope**: `outpost db create <app>` (idempotent `CREATE DATABASE`), `outpost seal-from-template <app> --template <path> --output <path>` (envsubst + strict residue check + kubeseal), `outpost manifest scaffold <app> --lang <lang> --manifests-dir <path>` (write 5 YAML from template tree), each emits structured JSON with `{step, status, written_files[], next_action}`
- **Success signal**: each subcommand has bats tests proving rerun = no-op when prior state matches, reconcile when drifted
- **Plan**: `docs/prp/plans/outpost-v0.4-phase3-onboard-primitives.plan.md`
- **Status**: ✅ complete 2026-05-21 — `onboard-lib.bats` 15/15, `onboard-primitives.bats` 15/15, full suite 197/197, lint green
- **Report**: `docs/prp/reports/outpost-v0.4-phase3-onboard-primitives-report.md`

**Phase 4: Webhook auto-register** *(parallel with Phase 3)*
- **Goal**: Eliminate the manual "go to Gitee UI and configure webhook" step.
- **Scope**: for each git-provider plugin, add `register-webhook.sh` that calls the provider's webhook-create API using existing `GIT_TOKEN`; degrades to "print these 3 steps" if PAT scope insufficient or API unreachable; documents required scope per provider
- **Success signal**: `outpost onboard` on a fresh repo results in a working webhook in the provider UI without human clicks (Gitee first; GitHub + GitLab follow)

**Phase 5: `outpost onboard` orchestration**
- **Goal**: The one command this entire version exists to deliver.
- **Scope**: top-level `cmd_onboard` in `scripts/outpost`, ordered call into Phases 2-4 primitives, state file at `~/.outpost/state/<app>.json`, `--legacy` (auto-Dockerfile-scaffold for repos missing one), `--dry-run` (preview), `--json` (machine output), final wait-for-green loop with 10-min timeout; clear `fix_hint` on failure
- **Success signal**: zff runs `outpost onboard ./scm-mcp` from a clean state and reaches first green deploy in ≤ 10 min without manual edits

**Phase 6: AI-agent contract** *(parallel with Phase 7)*
- **Goal**: An AI agent given only `ONBOARDING.md` can run the full onboard unattended.
- **Scope**: write new `ONBOARDING.md` at repo root (single canonical source); shrink `SKILL.md` and `AGENTS.md` to stub-and-link form (per the same pattern v0.3 used for copilot-instructions); document semantic exit codes (`0` success / `21` env missing / `22` port busy / `23` network egress fail / `24` PAT scope insufficient / `25` template residue / `26` ArgoCD timeout / `27` user-action-required) and `fix_hint` JSON schema; pin AI-agent verification playbook to use these codes
- **Success signal**: Claude Code session given only `ONBOARDING.md` + a fresh repo URL completes `outpost onboard` in ≤ 15 min without human intervention on at least one gauntlet project

**Phase 7: Frontend build-arg schema** *(parallel with Phase 6)*
- **Goal**: Stop the Next.js / Vite silent-fail trap.
- **Scope**: extend `outpost.build.yaml` with `frontend.envArgs: {NEXT_PUBLIC_FOO: "..."}` map; `scripts/read-build-config.sh` propagates to kaniko `--build-arg` list; manifest scaffold emits `Dockerfile` template that declares matching `ARG`s for frontend langs (`react`, `vue`, `next`); doc page under `i18n/{en,zh-CN}/docs/`
- **Success signal**: G3 (Next.js gauntlet project) deploys with `NEXT_PUBLIC_API_URL` correctly visible in the browser bundle

**Phase 8: Acceptance gauntlet**
- **Goal**: Turn the success criteria into a runnable, repeatable test.
- **Scope**: `tests/gauntlet/scm-mcp.sh` (re-onboard real SCM MCP repo pinned to a specific commit), `tests/gauntlet/go-svc.sh` (scaffold + onboard a minimal Go service from `examples/hello-world/go`), `tests/gauntlet/next-app.sh` (Next.js app with `NEXT_PUBLIC_*`), `tests/gauntlet/legacy-port.sh` (an existing repo not designed for outpost, onboarded with `--legacy`); each script asserts: zero `ci: re-trigger`, < 10-min wall clock, green ArgoCD + reachable URL
- **Success signal**: 4/4 green on a fresh outpost install; this is the tag blocker

**Phase 9: Docs / i18n / CHANGELOG / tag**
- **Goal**: Ship cleanly with the same hygiene v0.2 / v0.3 established.
- **Scope**: i18n EN ↔ zh-CN drift caught by existing v0.3 lint; CHANGELOG entry covering all 9 phases; VERSION bumped to `0.4.0` (or `1.0.0` per OQ-4 resolution); new ADR under `docs/decisions/` capturing the "shared substrate, not per-project infra" decision (it's been implicit since v0.1 — now under load it's worth recording why)
- **Success signal**: `git tag v0.4.0` (or v1.0.0); `outpost version` prints the right value; README updated; CHANGELOG reads cleanly

### Parallelism Notes

- **Phases 3 + 4** can run in parallel: onboard primitives (db / seal / manifest) and webhook auto-register touch disjoint files and have no runtime ordering between them.
- **Phases 6 + 7** can run in parallel: AI-agent doc/contract work and frontend build-arg schema are independent surfaces.
- **Phases 1, 2, 5, 8, 9** are strictly sequential — each is a foundation the next depends on, with no useful parallelism.
- **Phase 8 (gauntlet) is the tag blocker** — even if 1-7 land "done", v0.4 does not ship until G1+G2+G3+G5 pass on a fresh install.

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| Product framing | "Finishing release" — close the gap between v0.2 claims and real-project reality | Feature-additive v0.4 (more plugins, more capabilities) | Real-world evidence (SCM MCP commit cluster) showed the gap, not missing features |
| Onboarding logic location | Onboarding *primitives* live in the platform; each app owns its *content* (templates + `outpost.app.yaml`) | "No onboarding logic in infras" — commit `c1e1050` (2026-05-08) | `c1e1050`'s minimalist stance was empirically falsified by the SCM MCP onboarding attempt (see Evidence); the reversal + the mechanism-vs-content boundary are recorded in ADR `0002` |
| CLI language | Keep bash | Rewrite in Go / Rust / .NET (user is .NET-native; `infras.sln` exists) | Smallest body of work; v0.4 is closure, not refactor; revisit at v0.5 if pain returns |
| Multi-project strategy | Shared substrate (1 PG / 1 Redis / 1 MQ per host, DB / keyspace / vhost isolation) | Per-project independent infra (N PG instances) | v0.2 architecture already chose this; v0.4 doubles down rather than fork — recorded as new ADR in Phase 9 |
| AI-agent canonical doc | Single `ONBOARDING.md` at repo root | Keep dispersed across SKILL.md / AGENTS.md / docs/05 | AI agent today doesn't know which one to read; user's JTBD ("丢给 AI") demands one entry |
| Webhook PAT degradation | Auto-register if PAT scope allows, fall back to printed manual instructions | Force PAT re-issue / refuse to onboard without PAT scope | User shouldn't be blocked from progress by a token scope; degradation is one printed paragraph |
| MVP slicing (X1 / Y4) | All 12 walls in one big version, bash preserved | Slice into 4 small versions (DX first / stability first / etc.) | User explicitly chose Y4 ("12 堵全要，没得选") to deliver "real-project capable" as one coherent thing |
| Cross-machine fleet sync | Out of scope for v0.4 | Include as Phase 10 of v0.4 | Already a full version's work to "接得了真项目"; fleet sync is a different problem axis |
| SLO baseline | "outpost already bootstrapped" | "From a fresh machine including bootstrap" | bootstrap.sh cold start is 5–10 min just for image pulls — would dominate the SLO and obscure onboard quality |

---

## Research Summary

**Market Context**

The local-dev-infra market is dense but unintegrated for outpost's specific niche ("solo architect + AI-cadence + several parallel projects"). Closest neighbors don't overlap:
- **Coolify / Dokploy / CapRover** — VPS-target PaaS; ignore the laptop side, don't help with multi-project port arbitration on a single host
- **Coder / Daytona / Gitpod** — remote-first dev environments; don't run "PG + Redis + MQ on my Mac"
- **Tilt / Skaffold / Garden** — inner-loop dev tooling; assume cluster already exists, no infra scaffolding
- **devbox / flox / devcontainer** — toolchain portability only; no services / no routing
- **cloudflared / ngrok / Tailscale Funnel** — tunnel primitives; outpost composes one

Result: **outpost already occupies the empty niche**; the gap is execution quality, not positioning. The v0.4 work is *making the existing positioning honest*, not finding a new one. Most-applicable patterns from the broader ecosystem: opinionated CLI + single declarative manifest (`outpost.app.yaml` schema, taken from devbox / flox); per-app namespace + Traefik host routing (already in v0.2); single canonical AI-agent doc (a wayofdev / Coolify-style convention).

**Technical Context**

- Outpost v0.2/v0.3 architecture is sound and reusable verbatim: two-layer Compose + k3s, ExternalName bridges, single Cloudflare Tunnel, five-axis plugin model. No structural change needed.
- `scripts/outpost` (bash, 12 KB) is the right place to grow `onboard` / `doctor` / `db` / `rotate` subcommands — pattern already established (`status` / `verify` / `open` / `seal`).
- `bootstrap.d/` decomposition (10 phase scripts) gives a clean place to hook every B-class fix without rewriting bootstrap.
- `core/templates/` is a new directory introduced by Phase 5 to hold the app skeleton (deployment / service / ingress / kustomization / argocd-app / sealed-secret-template).
- Existing v0.3 infrastructure for ConfigMap-mounted scripts (`update-manifest-task`, `read-build-config-task`, `notify-runner-scripts`) is the canonical pattern for any new Tekton-side script in v0.4.
- The 12 walls map cleanly to specific files; no wall requires inventing new architecture.
- Acceptance gauntlet `tests/gauntlet/` is a new directory; reuses existing bats / shellcheck CI; SCM MCP commit-pinned reference shrinks gauntlet drift risk.

---

*Generated: 2026-05-20*
*Status: DRAFT — needs validation (read once, mark OQ-1..OQ-7, then implement Phase 1)*
