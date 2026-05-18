# Architecture Decision Records

Why this exists: as contributors arrive, the same architectural questions
recur — *"why not Helm-chart everything?"*, *"why not k8s for data
services?"*, *"why Cloudflare specifically?"*. ADRs preempt the discussion
by capturing the **decision + context + alternatives + consequences** at
the moment we made the call.

Format: [Michael Nygard's ADR template](https://github.com/joelparkerhenderson/architecture-decision-record/blob/main/locales/en/templates/decision-record-template-by-michael-nygard/index.md).
Light by design; we'd rather have 10 honest 1-page ADRs than 3 polished
treatises.

## Index

| #    | Title                                            | Status   |
|------|--------------------------------------------------|----------|
| 0001 | [Two-layer split: Compose + k3s](0001-two-layer-split.md) | Accepted |

## Authoring a new ADR

1. Copy [`0000-template.md`](0000-template.md) to `NNNN-short-title.md`,
   using the next available number.
2. Fill in **Context** (the situation; the forces; what other paths we
   considered), **Decision** (what we did), and **Consequences** (what
   becomes easy, hard, locked-in).
3. Set **Status** to `Proposed` while the PR is open; flip to `Accepted`
   when it lands. Use `Deprecated` or `Superseded by #NNNN` when later
   ADRs revisit the topic — don't delete old ADRs.
4. Add a row to the index above.

## When to write an ADR

- A decision you'd defend in a code review against "why didn't you just X?"
- A scope cut that's likely to be questioned later
- A pinning choice (e.g. picking Argo Rollouts over Flagger) where the
  alternative is real and someone might propose switching
- Anything that took more than 30 minutes of discussion to settle

Don't ADR every small choice. A noisy decision log is worse than no log.
