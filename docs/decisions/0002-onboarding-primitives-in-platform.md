# 0002 — Onboarding primitives belong in the platform

## Status

`Accepted` (2026-05-20). Supersedes the architectural decision recorded in
commit `c1e1050` ("revert: 把 onboarding 编排移出 infras", 2026-05-08),
which was never written up as an ADR.

## Context

On 2026-05-08, commit `ec7a077` added `scripts/seal-secret.sh` — a thin
`kubeseal` wrapper — plus Chinese onboarding docs. Forty minutes later
`c1e1050` reverted it, on the principle: *infras is platform + templates +
docs; it must not carry app-level onboarding logic, because each app's
secret fields and databases differ — that is the app's own business.* The
commit deleted the wrapper and rewrote the onboarding docs to "each app
writes its own onboard script."

That principle was a reasonable theory. It was then tested. Between late
April and mid-May 2026 the author tried to onboard a real project (SCM MCP)
under exactly that regime — apps onboard themselves — and the result is the
v0.4 PRD's entire Evidence section: 6 `ci: re-trigger` commits, 21
hand-written manifest YAMLs, a hand-rolled 95-line `scripts/onboard.sh`
(`建库 + sealed-secret`), and the project parked unfinished. The minimalist
boundary did not produce "apps onboard themselves cleanly"; it produced
"every app re-derives the same onboarding scaffolding by hand, badly."

The principle was also already eroding in practice. After `c1e1050` deleted
the standalone wrapper, an `outpost seal <app> KEY=VALUE …` subcommand — a
`kubeseal` wrapper by another name — was added to the `outpost` CLI and
still ships today. The strict "no wrapper" stance of `c1e1050` was, de
facto, already abandoned.

The v0.4 PRD ("Real-Project Onboarding") makes `outpost onboard <repo>` its
centerpiece and Phase 3 ships onboarding *primitives* (`db create`,
`seal-from-template`, `manifest scaffold`). The PRD never references
`c1e1050`. Two same-author decisions, 12 days apart, point in opposite
directions with nothing reconciling them. This ADR reconciles them.

The forces in play:

- `c1e1050`'s worry is real: outpost must not become a junk-drawer of one
  app's specifics.
- The minimalist alternative has been empirically falsified for this
  product's stated goal ("接得了真项目" — onboard a real project).
- The boundary is salvageable: the *mechanism* of onboarding is generic;
  only the *content* is app-specific.

## Decision

Onboarding **primitives** belong in the outpost platform. `c1e1050`'s "no
onboarding logic in infras" is superseded.

The boundary `c1e1050` was reaching for is preserved as a
**mechanism-vs-content** rule: outpost ships the generic *mechanism* of
onboarding; each app owns its *content*. outpost must never hardcode any
specific app's secret keys, DB schema, or manifest values.

Concrete artifacts this governs (v0.4 Phase 3):

- `outpost db create <app>` — creates an empty database named for the app;
  no schema, no seed data.
- `outpost seal-from-template <app> --template <path> --output <path>` — the
  app supplies the template (its content); outpost supplies envsubst + a
  strict residue check + `kubeseal` (the mechanism).
- `outpost manifest scaffold <app> --lang <lang>` — generic per-language
  skeletons; app-specific values come from `outpost.app.yaml` in the app
  repo, not from outpost.

Review test for any future onboarding feature: *would this line of code
need to change if a different app were onboarded?* If yes, it belongs in
the app (its template, its `outpost.app.yaml`), not in outpost.

## Consequences

**Easier:**

- `outpost onboard` (v0.4 Phase 5) has a coherent set of primitives to
  orchestrate, instead of every app re-deriving them by hand — the SCM MCP
  failure mode.
- The mechanism-vs-content rule gives Phase 3 reviewers a concrete, testable
  line to reject scope creep against (PRD risk R6).

**Harder / locked-in:**

- outpost now owns the correctness of onboarding mechanism across every
  provider and language — a real maintenance surface. Mitigated by the PRD's
  Phase 8 acceptance gauntlet.
- The `outpost.app.yaml` schema becomes load-bearing: it is the designated
  home for everything that is app-content. If it is under-designed, pressure
  will push app-specifics back into outpost. The schema must be reviewed
  with that in mind.

**Explicitly not solved:**

- This ADR does not decide *shared substrate vs. per-project infra* — a
  separate decision, slated for its own ADR in PRD Phase 9.
- It does not settle webhook-registration scope (`c1e1050` is silent on it;
  see PRD Phase 4 / OQ-2).

**Documentation debt created:**

- `i18n/{en,zh-CN}/docs/05-onboard-project.md` and `08-seal-secret.md` still
  carry `c1e1050`'s "each app writes its own onboard script" framing. They
  contradict this ADR and must be reconciled when v0.4 Phase 3/5 land
  (PRD Phase 9 doc-sync).

## Alternatives considered

- **Keep `c1e1050`'s boundary (no onboarding logic in outpost):** rejected —
  empirically falsified by the SCM MCP onboarding attempt, and already
  contradicted by the shipped `outpost seal` subcommand. Holding it would
  require re-scoping away the v0.4 PRD's centerpiece.
- **Full reversal with no boundary (outpost absorbs whatever onboarding
  needs):** rejected — this is the junk-drawer outcome `c1e1050` rightly
  feared. The mechanism-vs-content rule keeps the useful half of the
  original concern.
- **Leave it unrecorded (let the PRD silently win):** rejected — that is the
  state this ADR was written to fix. A future contributor reading `c1e1050`
  would still believe onboarding is forbidden.

## References

- Commit `c1e1050` "revert: 把 onboarding 编排移出 infras" (2026-05-08) — the
  superseded decision.
- Commit `ec7a077` — the original `seal-secret.sh` that `c1e1050` reverted.
- `docs/prp/prds/outpost-v0.4-real-project-onboarding.prd.md` — Evidence
  section; Phase 3 and Phase 5; risk R6; Decisions Log.
- `scripts/outpost` → `cmd_seal` — the `kubeseal` wrapper that already
  re-crossed `c1e1050`'s line.
- ADR [`0001`](0001-two-layer-split.md) — the two-layer split this builds
  on, unaffected by this decision.
