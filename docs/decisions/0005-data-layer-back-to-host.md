# 0005 — Data layer stays on the host (revert of 0004)

## Status

`Accepted` (2026-08-15). **Supersedes [ADR-0004](0004-data-layer-in-k3s.md)**
and restores the [ADR-0001](0001-two-layer-split.md) placement — with the
bridge hardening that was added after ADR-0001 (the
`coredns-hosts-reconciler` self-heal) kept in place.

## Context

ADR-0004 moved postgres/redis/rabbitmq/manticore into k3s (StatefulSets,
`local-path` PVCs, Retain policy) to eliminate the
`host.docker.internal` bridge — the recorded #1 whole-site outage mode
(WSL2 IP drift stranding all app pods at once).

Before any real box deployed that shape, the owner reverted it:

- **Stateful services belong on the host** as an operating principle for
  this deployment: running stateful workloads under k8s adds storage
  lifecycle coupling the owner does not want (k3s uninstall/reset removes
  `/var/lib/rancher`, taking `local-path` PV data with it), while Compose
  keeps data in plain named volumes managed independently of the cluster's
  lifecycle.
- The Cloudflare tunnel surface was **designed around two route classes**:
  HTTP UIs proxied through caddy (`search.*` / `mq.*`) and raw-TCP
  passthrough straight to the Compose containers (`pg.*` / `redis.*` /
  `rabbitmq.*`). The in-cluster move silently dropped the raw-TCP class.
- The bridge-fragility argument that motivated ADR-0004 is real but
  already mitigated: the `coredns-hosts-reconciler` CronJob (added in the
  data-plane hardening pass, pre-v0.3.0) rewrites the CoreDNS
  `host.docker.internal` entry within ~2 minutes of an IP drift.

## Decision

- The four data services run as Compose containers (`local-data` profile)
  in **both** modes. `full` mode brings up `edge` + `local-data` together
  (`bootstrap.d/04-compose.sh`).
- The k3s side is the ExternalName bridge again:
  `core/k8s/06-bridges/*.yaml` = 4 `ExternalName → host.docker.internal`
  Services + the `coredns-hosts-reconciler` CronJob. Bootstrap Phase 8
  injects the CoreDNS custom hosts entry (node InternalIP) and hard-fails
  if it cannot.
- `verify.sh` keeps the deep per-protocol data probes (now via
  `docker exec`) and adds two FAIL-level bridge checks: `data.bridge_dns`
  (coredns-custom entry vs the node's *current* InternalIP) and
  `data.bridge_reconciler` (CronJob present). A stale bridge is never
  silent — it FAILs verify and rides the existing notify path.
- cloudflared reference config restores both route classes (HTTP UIs via
  caddy, raw TCP via container names).
- v0.3.0's in-cluster data workloads are cleaned up by bootstrap if
  present (workloads/config only — PVCs are never deleted by cleanup).

## Consequences

- **(+)** Data volumes live outside the cluster lifecycle: `reset.sh`, k3s
  reinstalls and CRD surgery cannot touch them.
- **(+)** Day-to-day data ops are plain `docker exec` / `docker compose`;
  the raw-TCP tunnel class works again for remote clients.
- **(−)** The bridge is back, and with it the drift failure mode. Accepted
  with mitigations: reconciler self-heal (~2min window), FAIL-level drift
  detection in `verify.sh` (30-min timer + notify), and the Phase 8
  hard-fail at bootstrap time. The residual exposure is the ≤~2min
  reconciler window after a WSL restart.
- **(−)** `docker` daemon availability is back on the app-serving critical
  path in full mode (it already was for the ingress edge).
- Production migration story is unchanged from ADR-0001: point the
  ExternalName at a managed endpoint; app connection strings never change.
