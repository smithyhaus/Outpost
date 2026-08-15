# 0004 — Data layer moves into k3s (`full` mode)

## Status

`Superseded by [ADR-0005](0005-data-layer-back-to-host.md)` (2026-08-15) —
reverted by owner decision before any real deployment ran this shape;
stateful services stay in host Compose. Kept for the record of why the
in-cluster move was attempted. Originally: Accepted (2026-08-15), amending
[ADR-0001](0001-two-layer-split.md).

## Context

ADR-0001 put postgres/redis/rabbitmq/manticore in Compose and bridged them
into k3s via `ExternalName` Services resolving to
`host.docker.internal:<port>`. On the Mac dev box this was reliable. On
WSL2 it is not: the WSL virtual NIC's IP is not guaranteed stable across
reboots, and `host.docker.internal` resolution depends on a CoreDNS
`hosts`-file bridge that has to be kept in sync with that drifting IP. When
it drifted, all four data services became unreachable from k3s
simultaneously — every one of the (at the time) 17 business apps lost their
database/cache/queue/search connection at once. This is the single largest
blast-radius failure mode in the project's incident ledger: one moving
part (a virtual NIC IP) with a fan-out to the entire application fleet.

The community counter-arguments against "put stateful services in
Kubernetes" are well known and were re-examined here specifically, not
dismissed by default:

- *"K8s adds StatefulSet/PVC/volume-snapshot/backup-CRD operational burden
  the host doesn't need."* True for the general case. On a **single-node**
  cluster, though, a `StatefulSet` with a `local-path` PVC is operationally
  no heavier than a Compose named volume — there is no multi-node
  scheduling, no volume migration, no CSI complexity to reason about. The
  argument's premise (multi-node operational burden) doesn't hold in a
  single-node topology.
- *"Kubernetes doesn't give you HA for free, so why pay the complexity
  tax."* Also true — but the counterfactual isn't "Compose gives you HA and
  k3s doesn't." Neither does. Compose has exactly the same single-instance,
  single-point-of-failure shape this project already runs. Moving to k3s
  does not trade away HA it never had.
- *"Data survivability is scarier inside k8s (reset.sh nukes the
  namespace)."* This is the one real new risk this ADR introduces (see
  Consequences) and is mitigated explicitly (PVC `Retain`, `reset.sh`
  guardrails, dump-first discipline) rather than argued away.

Net: on this specific topology (single node, single operator, dev/small-
team backend, no HA requirement either way), the standard "keep data out of
k8s" argument's premises don't transfer, and the concrete failure this
project already suffered (WSL IP drift → full-fleet outage) is a k3s-native
non-issue once the data layer is a first-class k3s workload reachable by
the same in-cluster Service DNS every app already uses.

## Decision

In `full` mode, postgres/redis/rabbitmq/manticore run as `StatefulSet`s in
the `infra-bridges` namespace (`core/k8s/06-bridges/{postgres,redis,
rabbitmq,manticore}.yaml`), each backed by a `local-path` PVC with
`persistentVolumeReclaimPolicy: Retain`. **Service names are unchanged**
(`postgres.infra-bridges.svc.cluster.local`, etc.) — the Service now
selects real in-cluster pods instead of resolving `ExternalName` to
`host.docker.internal`. Application connection strings require **zero
edits**. The production-migration path ADR-0001 promised (repoint the
Service to managed Postgres/Redis/RabbitMQ) is preserved — swap the
selector-based Service back to an `ExternalName`, same as before.

`local` mode is unaffected: it stays pure Compose (`local-data` profile),
for developers who want the data layer without standing up k3s at all.
`full` mode's Compose stack shrinks to an `edge` profile (`caddy` +
`cloudflared`) — the data-service Compose definitions those apps might
otherwise still reference are dropped for `full` installs; `caddy`/
`cloudflared` remain in Compose because they front the Cloudflare Tunnel,
which is not a k3s concern.

The `host.docker.internal` / CoreDNS `coredns-custom` bridge
(`core/k8s/06-bridges/coredns-hosts-reconciler.yaml`) is deleted — there is
nothing left that resolves it.

## Consequences

**Easier:**

- The single largest blast-radius failure mode (WSL IP drift → 4-service,
  full-fleet outage) is eliminated by construction — in-cluster Service DNS
  doesn't depend on a host-network IP that can drift across reboots.
- One fewer moving part to reason about during incident response: no
  CoreDNS-bridge-freshness check, no `host.docker.internal` reachability
  probe, no separate "is the Compose data container even running" check
  distinct from the k8s pod check.
- `verify.sh`'s data-layer checks collapse to ordinary in-cluster pod/Service
  health — the same shape as every other k3s workload check, not a special
  case.

**Harder / locked in:**

- **`reset.sh` blast radius grows** — a careless namespace wipe now touches
  live application data, not just rebuildable app manifests. Mitigated by:
  PVC `persistentVolumeReclaimPolicy: Retain` (a namespace/PVC delete does
  not delete the underlying volume data), explicit `reset.sh` guardrails
  that refuse to touch `infra-bridges` without an extra confirmation flag,
  and dump-first discipline documented in the redeploy runbook
  (`docs/prp/runbooks/wsl2-redeploy-0.3.md`) before any destructive
  operation.
- Single-node `StatefulSet` + `local-path` PVC upgrades (e.g. bumping the
  Postgres image) are a real k8s operational event (`kubectl rollout` on a
  singleton with an attached RWO volume needs care) in a way a Compose
  `docker compose up -d postgres` was not. Documented in the operator
  runbook; acceptable trade for eliminating the outage class above.
- Backup/restore is now a `pg_dumpall`/RabbitMQ-definitions-export/PVC-
  snapshot discipline instead of "the Compose volume is just a directory on
  the host" — slightly higher ceremony, captured in the redeploy runbook's
  data-snapshot section.

**Explicitly not solved:**

- This ADR does not add StatefulSet volume snapshots, automated backups, or
  multi-node data replication — none of those match this project's
  single-node/single-operator scope. If a future maintainer needs them,
  that is a new decision, not an extension of this one.

## Alternatives considered

- **Keep the ADR-0001 bridge, fix only the IP-drift symptom** (e.g. a
  static WSL IP, a tighter CoreDNS reconciler poll): rejected — treats the
  symptom, not the structural cause (a bridge that depends on a host-network
  IP at all). The fix that removes the entire failure class is preferred
  over one that narrows its window.
- **Move data to managed cloud services immediately** (skip self-hosting
  data entirely): rejected — out of scope for a self-hosted dev/small-team
  backend; the whole point of Outpost is running your own stack. The
  Service-swap migration path to managed services remains available
  whenever an operator wants it, unchanged by this ADR.
- **Do nothing (accept the outage class as a known WSL2 quirk)**: rejected
  — this is precisely the failure mode driving the WSL2 reinstall this ADR
  rides alongside; leaving it unaddressed during a full reinstall would be
  choosing to reproduce the largest-blast-radius incident class on day one
  of the new box.

## References

- ADR [`0001`](0001-two-layer-split.md) — the two-layer split this ADR
  amends (Compose-vs-k3s split unchanged; only which layer hosts stateful
  services in `full` mode changes).
- `docs/prp/plans/outpost-cicd-dispatcher-engine.plan.md` §3 — "数据层裁决"
  (data-layer verdict), part of the same review pass as ADR-0003.
- `docs/prp/runbooks/wsl2-redeploy-0.3.md` — the data-snapshot,
  restore-and-verify, and `reset.sh` guardrail procedures this ADR depends
  on operationally.
- `core/k8s/06-bridges/` — the StatefulSet manifests this ADR governs.
