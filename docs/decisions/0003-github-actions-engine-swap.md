# 0003 — CI/CD engine swap: Tekton + ArgoCD → GitHub Actions self-hosted runner + manifest-sync CronJob

## Status

`Accepted` (2026-08-15).

## Context

Outpost's CI/CD engine (Tekton for build, ArgoCD for deploy) had been the
single largest source of operational fires since v0.1. Before proposing a
replacement we ran an attribution pass over the 116 commits since project
start, isolating the 72 that were incident fixes or hardening changes:

| Attribution | Share | Notes |
|---|---|---|
| Pure config error | ~12% (9/72) | All one-shot, bats-locked after the fix, **zero recurrence** — the "it's just my config" theory is falsified by the commit history itself. |
| Component selection (direct) | ~50% (36/72) | Webhook silent-loss in 3 distinct shapes (including a 9-day full outage), Tekton CRD footguns ×10, DiskPressure ×3+, manifest-push races. |
| Component selection (incl. CN-egress amplification) | ~62% | Of 14 cn-egress hardening commits, ~9 exist only because an ephemeral build pod re-pulls tools/images on every single build. |
| Own design debt | ~26% | Fake-OK verification culture (largely closed out already), the compose↔k3s data bridge (the single largest blast-radius item in the ledger), manifest concurrent-write pattern — **the engine swap does not fix these; they ride along with the WSL2 reinstall (ADR-0004).** |

The calibration point: ArgoCD's reconcile loop itself appears in zero
recurring incident classes. What was wrong was the CI half, the inbound
webhook transport, and the deploy side's *scale* — a platform engine built
for multi-team/multi-node fleets (Tekton: 16 CRDs, 4 controllers, 5
admission webhooks; ArgoCD: 7 processes) running a single person's single
node behind a CN residential/GFW egress path.

The user added an explicit constraint mid-review: **avoid a bespoke
CI/CD engine; prefer an existing, maintained one (e.g. Drone) over
hand-rolling a dispatcher.** That constraint ruled out the first-draft
verdict (a self-built polling dispatcher) and forced a real build-vs-buy
survey of existing engines against this environment's actual shape:
1 person, 1 node, CN egress, WSL2, gitee-primary source control.

### Candidates evaluated

| Candidate | Verdict | Why |
|---|---|---|
| **Drone CI** | Rejected | Has a native gitee driver (`go-scm/driver/gitee`) — but the server model is **forge-initiated inbound webhook**, which reproduces the exact failure class that caused the 9-day outage, just at a different receiver. Drone is also now in Harness's maintenance-mode ownership; its successor Gitness does not support gitee. |
| **Woodpecker CI** | Rejected | Genuinely light (server ~50-100MB) but has **no gitee driver** (addon-only route), and is architecturally the same forge-inbound-webhook model as Drone. |
| **Gitee Go** | Rejected | Free-tier minutes are capped (200/repo, 1000/org monthly — low confidence, needs re-verification), cloud black-box, no local build-cache control. |
| **Tekton, kept + hardened** | Rejected | Locked at 2/5 on both "component fit" and "operational cost" axes: 16 CRDs / 4 controllers / 5-6 pods per build serving one person; ~82k LOC of vendored YAML that re-triggers a full image-verification pass on every upgrade. |
| **Gitea + Gitea Actions** | Backup option | The only fully-offline, end-to-end-pull design (`act_runner` long-polls a local Gitea) — but it requires moving **git hosting itself** onto this box, putting the single source of truth on the most fragile machine in the fleet. Kept as Plan-B, not adopted. |
| **GitHub Actions, self-hosted runner** | **Selected** | Officially confirmed pure-outbound 50s long-poll, zero inbound requirement; first-class HTTP proxy support (works behind v2ray); resident RSS <100MB; org-level runners shareable across private repos (already in production use for an unrelated org). The engine itself (queueing, scheduling, retries, logs, UI, concurrency groups) is entirely GitHub's — Outpost's own build surface shrinks to ~40 lines of workflow YAML per repo plus this repo's already-hardened `scripts/ci/*`. |

### Deploy side (CD)

ArgoCD is removed outright. Deployment moves to a **manifest-sync CronJob**:
a k3s CronJob `git pull`s the gitee-side manifest repo every
`MANIFEST_SYNC_INTERVAL` minutes, applies changed apps (`kubectl apply -k`
+ rollout-wait), and notifies. Single-writer, serial, roughly the same LOC
class as `update-manifest.sh` itself — **this is deliberately not a second
bespoke engine**: scheduling is k8s's own CronJob primitive, and the
semantics are literally "poll, pull, apply on a timer," not a
reconciliation control loop with its own state machine.

If a future maintainer wants a zero-glue GitOps controller again, an
ArgoCD core-install remains a documented option — but it brings back 3
CRDs, 3 processes, and ~30k LOC of vendored YAML for a feature set this
project's own incident ledger shows zero use of (canary via Argo Rollouts
AnalysisTemplate, multi-cluster, app-of-apps).

## Decision

Replace Tekton + ArgoCD with:

- **CI**: the official `actions/runner`, installed as a systemd service on
  the WSL2 host, registered at the **org level** against
  `GITHUB_RUNNER_URL` so it serves every app repo without per-repo
  re-registration. App repos each carry a ~40-line
  `templates/github/outpost-build.yml` workflow (`on: push` to the deploy
  branch, `runs-on: [self-hosted, outpost]`, per-repo concurrency group)
  that calls this repo's `scripts/ci/build-image.sh` (buildctl against the
  in-cluster buildkitd NodePort, sha-7 push to the registry NodePort),
  `scripts/ci/run-tests.sh` (Gate A, opt-in no-op), and
  `scripts/update-manifest.sh` (unchanged — 6-attempt jittered push retry
  kept, cross-repo workflow concurrency still exists).
- **CD**: the `manifest-sync` CronJob in namespace `outpost-ci`
  (`core/k8s/03-ci/cronjob.template.yaml`, ServiceAccount `outpost-sync`
  scoped to apps-namespace apply rights + heartbeat ConfigMap write, no
  cluster-admin), writing `sync-heartbeat` (`last_sync_ts` / `applied_head`
  / `last_result`) every run.
- **Source-of-truth split (gitee vs github)**: gitee stays the primary push
  target, the manifest repo, and the reconciliation baseline (fast,
  domestic, unchanged developer habit). github becomes purely the CI
  trigger surface — app repos need a github copy, synced either by
  dual-push (`git remote set-url --add --push origin <url>` for both
  remotes — failures are visible in the terminal at push time) or gitee's
  official **one-way** push-mirror (never the bidirectional mirror; gitee's
  own docs warn of a 30-minute cross-push race that can lose commits).
- **Anti-silence, three independent layers** (see `verify.sh`): (1)
  reconciliation — an authenticated `git ls-remote` of every
  `OUTPOST_REPOS` entry's live branch head, diffed against the tag actually
  deployed in the manifest repo; a mismatch persisting past
  `OUTPOST_STALENESS_THRESHOLD` is FAIL, naming the repo, regardless of
  *which* link in the chain broke; (2) liveness — runner systemd unit +
  GitHub API runner-online + sync-heartbeat age, all FAIL-level; (3) a host
  `systemd` timer (`platform/systemd/outpost-verify.timer`, 30min,
  `Persistent=true`) runs `verify.sh --quiet` and notifies on FAIL from
  outside both the cluster and GitHub.

## Consequences

**Easier:**

- Zero inbound webhook surface anywhere — no shared secret to leak, no
  gitee-webhook-delivery reliability class of incident to defend against.
- No CRD/controller/admission-webhook footgun surface for build or deploy;
  cluster CRD count drops from 23+ to 1 (sealed-secrets), +4 optional if a
  future maintainer opts into `ROLLOUT_PLUGIN=argo-rollouts`.
- Deploy and rollback stay fully domestic (gitee + local cluster) even when
  github.com or the outbound proxy is degraded — only the CI *trigger* path
  depends on GitHub reachability, not the deploy path.
- Per-build container churn drops sharply (persistent host runner vs.
  ephemeral Tekton pods re-pulling tools every build) — this alone removed
  the root cause of ~9 of the 14 CN-egress hardening commits.

**Harder / locked in:**

- `github.com` reachability becomes a real dependency for the **CI
  trigger** path (not the deploy path). Proxy/GFW jitter delays build
  queueing. Mitigated three ways: the reconciliation layer turns any
  resulting staleness into a named FAIL; the deploy/rollback hot path is
  unaffected; and `scripts/ci/*` are plain scripts runnable by hand on the
  host as a manual escape hatch (not a second engine — the workflow step
  and the manual invocation are the same code).
- The runner executes app-repo code on the host (single-tenant is
  acceptable here, would not be for a shared box). Mitigated by keeping the
  runner group private-repos-only (GitHub default) and never routing public
  PRs to it; `GITHUB_RUNNER_PAT` is scoped to the minimum needed to mint
  runner registration tokens and is revocable after registration.
- Runner `systemd` service installation has known friction (`svc.sh`
  permission/exit-203 class issues) — preflighted in bootstrap; the redeploy
  runbook documents the `systemctl status` verification step and a known
  busy-wait CPU bug to watch for.
- Losing ArgoCD's UI and Argo Rollouts' automatic canary abort: the incident
  ledger shows zero use of either. Registry now retains
  `OUTPOST_REGISTRY_KEEP_TAGS` (10) tags plus manifest git history bounding
  rollback depth; canary remains available as an opt-in, default-off
  plugin.
- A gitee→github sync break (dual-push misconfigured, or a broken mirror)
  is now a distinct failure mode. It is caught by the same reconciliation
  layer (live HEAD vs deployed tag mismatch) and the dual-push failure mode
  specifically surfaces immediately in the developer's own terminal at push
  time.

**Explicitly not solved by this ADR:**

- The data-layer bridge fragility (WSL IP drift → full-fleet outage) — see
  ADR-0004, decided alongside this one but scoped separately.
- Long-term "what if this needs multi-node" scaling — out of scope for a
  single-person/single-node platform; if that need arises, ArgoCD
  core-install remains a documented fallback (see Alternatives).

## Alternatives considered

- **Self-built polling dispatcher** (the original first-draft verdict):
  rejected once the user's "avoid self-built CI/CD" constraint was applied
  — a real existing engine (GitHub Actions runner) meets every requirement
  a bespoke dispatcher would have had to reinvent (queueing, retries, logs,
  concurrency groups, UI).
- **Drone CI, Woodpecker CI, Gitee Go, Tekton-kept, Gitea+Actions**: see the
  candidate table above.
- **ArgoCD core-install kept, only Tekton removed**: rejected — the
  incident ledger shows ArgoCD itself in zero recurring incident classes,
  but its 3 CRDs / 3 processes / ~30k vendored LOC buy capabilities
  (multi-cluster, canary AnalysisTemplate automation, app-of-apps) this
  project has never used. The manifest-sync CronJob captures the actually-
  used 20% (declarative deploy from a git manifest repo) at a fraction of
  the operational surface.
- **Do nothing / keep the status quo**: rejected on the strength of the
  incident attribution itself — ~50-62% of hardening commits trace directly
  to the component choice, not to configuration; staying the course meant
  signing up for the same recurring incident classes indefinitely.

## References

- `docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md` — the full
  multi-agent research artifact (6 subsystem audits + 116-commit incident
  archaeology + external evidence research + 3-way adversarial review +
  synthesis + user-constraint revision) this ADR summarizes.
- GitHub Docs — self-hosted runners (outbound-only long-poll) and
  using-a-proxy-server; GitHub community discussion #26630.
- `docs.drone.io/server/overview`, `drone/go-scm` (gitee driver),
  `docs.drone.io/faq/gitness` (Gitness does not support gitee).
- `woodpecker-ci.org` forges overview (no gitee driver).
- `help.gitee.com` — webhook delivery reliability notes; sync-between-
  gitee-github mirror docs (bidirectional-risk warning).
- GitHub Docs — rate-limits (confirms `git ls-remote` is not REST-limited);
  GitHub community discussion #44515.
- GitHub Docs — runner-groups; GitHub Changelog 2020-04-22 (org-level
  runner sharing across private repos).
- ADR [`0001`](0001-two-layer-split.md) — the two-layer split this
  decision operates within (unaffected: Compose vs k3s split is orthogonal
  to which CI/CD engine runs inside the k3s layer).
- ADR [`0004`](0004-data-layer-in-k3s.md) — the companion data-layer
  decision made in the same review pass.
