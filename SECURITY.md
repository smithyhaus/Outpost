# Security policy

## Reporting a vulnerability

**Do not open a public issue for security findings.**

Use GitHub's "[Report a security advisory]" feature on this repository
(Security tab → Advisories → New draft advisory). If that is unavailable,
contact the maintainers privately via the email address listed on the
maintainer profiles.

We will acknowledge within 7 days and aim for a fix or mitigation within
30 days for high-severity issues.

## Scope

In scope:

- Code in this repository (`bootstrap.sh`, plugins, manifests, tests)
- Default configurations that ship to users (e.g. anonymous self-hosted
  registry by design — call out if you think a different default is safer)
- Documentation that misleads users into insecure configurations

Out of scope:

- Vulnerabilities in upstream components (Postgres, Redis, k3s, ArgoCD,
  Tekton, Cloudflare). Report those upstream.
- Self-inflicted misconfiguration (e.g. user committed `.env` to a public
  repo). We're happy to advise but cannot fix in code.
- Findings against deployments not running Outpost unmodified.

## Operator responsibilities

Outpost's defaults assume a single-developer / small-team trust
model. If you operate it differently, you are responsible for:

- Putting **Cloudflare Access** (or similar) in front of `argocd.<domain>`,
  `mq.<domain>`, and `registry.<domain>` if exposing them publicly.
- Rotating `GIT_WEBHOOK_SECRET` if it leaks (and updating it everywhere:
  `.env`, EventListener manifest, every Git provider's webhook config).
- Securing the host running the stack — Outpost assumes the host's
  Docker socket and kubeconfig are not adversary-accessible.
- Not committing `.env` or `INFRA.md` (they're in `.gitignore` for a
  reason).

## Disclosure

We follow [coordinated disclosure](https://en.wikipedia.org/wiki/Coordinated_vulnerability_disclosure).
After a fix is released, we publish the advisory referencing the original
report and credit the reporter (unless they prefer to remain anonymous).
