# 0001 — Two-layer split: Compose for data, k3s for apps

> **Amendment history**: [ADR-0004](0004-data-layer-in-k3s.md)
> (2026-08-15) briefly moved the `full`-mode stateful services from
> Compose into k3s `StatefulSet`s, but was **reverted the same day by
> [ADR-0005](0005-data-layer-back-to-host.md)** before any deployment ran
> it. The placement decided in THIS ADR — data in Compose, bridged into
> k3s — is current again, now hardened with the
> `coredns-hosts-reconciler` self-heal.

## Status

`Accepted` (2026-05-06; carried through every release since). Amended by
ADR-0004, whose change was reverted by ADR-0005 (both 2026-08-15) — the
placement described here is current. See note above.

## Context

Outpost needs to run, on a single machine, both:

- **Stateful infrastructure** that almost every project assumes: Postgres,
  Redis, RabbitMQ, Manticore Search. These are long-lived; their state is
  precious; they're upgraded rarely.
- **Stateless applications + CI/CD** that drive a GitOps workflow:
  ArgoCD, Tekton, image registry, user app pods. These churn constantly;
  their state is reconstructable from manifests + the container registry.

Three obvious paths:

1. **Everything in Compose** — minimal moving parts, but no real path to
   a GitOps workflow without bolting on Jenkins/Drone/etc. and reinventing
   declarative deploys.
2. **Everything in k3s** — true cloud-native shape, but operators now need
   to manage `StatefulSet` + PVC + volume snapshots + backup CRDs for the
   stateful pieces, and a `helm upgrade` of Postgres is a real ops event
   on a dev box.
3. **Two layers**: Compose for the stateful infra, k3s for the apps + CI/CD.

The user we're optimizing for is a developer running this on their own
laptop or a small VPS — not an SRE team. So the cost of (2)'s "you must
understand PVs/PVCs to upgrade Postgres" is real.

## Decision

Run two layers, bridged by Kubernetes `ExternalName` Services in an
`infra-bridges` namespace. Apps reference DNS names like
`postgres.infra-bridges.svc.cluster.local`; the bridge resolves to
`host.docker.internal:5432`, which lands on the Compose container.

Concrete artifacts:

- `core/compose/docker-compose.yml` — the stateful layer.
- `core/k8s/06-bridges/*.yaml` — the bridges (one ExternalName Service
  per data service).
- All app manifests in `examples/` and the docs reference the bridge
  DNS names, never `host.docker.internal` directly.

## Consequences

**Easier:**

- Blow away k3s and rebuild it without losing data. Apps are declarative
  in the manifest repo; the CD engine recreates them (ArgoCD as written in
  2026-05; `manifest-sync` since [ADR-0003](0003-github-actions-engine-swap.md)).
  Data volumes sit outside the cluster lifecycle, so k3s reinstalls and CRD
  surgery are routine. This is the #1 operational win.
  > **Correction (v0.3.1):** `reset.sh` is NOT in that safe set. It runs
  > `docker compose --profile edge --profile local-data down -v`, which
  > deletes the data volumes in both modes. Take a logical dump first —
  > see `docs/prp/runbooks/wsl2-redeploy-0.3.md` §0.
- **Production migration is a one-line change.** Repoint the bridge's
  `spec.externalName` from `host.docker.internal` to managed
  Postgres / Redis / RabbitMQ. App connection strings are unchanged.
- **Operational scope is contained.** The data layer doesn't require K8s
  expertise; the app layer doesn't require volume/PV expertise.

**Harder:**

- Two stacks to install (docker compose + k3s). Mitigated by `bootstrap.sh`
  driving both, plus `OUTPOST_MODE=local` for the data-only path.
- `host.docker.internal` resolution requires a host alias on Linux/WSL2.
  Mitigated by `--add-host=host.docker.internal:host-gateway` in
  `core/compose/docker-compose.yml`.
- Cross-layer traffic doesn't get NetworkPolicy isolation (it leaves the
  pod, hits the host network, comes back). For a single-machine dev box
  this is acceptable; for shared infra it'd matter.

**Locked in:**

- We're committed to the bridge ExternalName pattern. Moving away (e.g.
  to a Service Mesh, to running data in-cluster) would require updating
  every app that uses the bridge DNS.

## Alternatives considered

- **Everything in Compose:** rejected because the GitOps story (push to
  git → ArgoCD deploys) is the value prop, and reinventing it on top of
  Compose costs more than running k3s.
- **Everything in k3s (StatefulSets):** rejected because the operator
  burden for stateful upgrades on a dev box is higher than the value of
  uniform tooling. Also, a single-node k3s + 5 stateful pods + a PVC layer
  is more memory-hungry than the equivalent Compose stack.
- **Pure Compose with a separate "deploy script" instead of GitOps:**
  rejected — that's literally what GitOps replaced. Reinventing it for one
  use case is the wrong instinct.

## References

- `ARCHITECTURE.md` — the high-level diagram and bridge table.
- `SKILL.md` §2 — the load-bearing invariants.
- TODOS.md → "Helm chart packaging" — the long-deferred path for users
  who already have a k3s/k8s cluster and want only the GitOps layer.
