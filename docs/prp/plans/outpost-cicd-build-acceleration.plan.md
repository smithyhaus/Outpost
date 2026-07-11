# Plan: CI/CD Build Acceleration — buildkit + persistent pnpm store + concurrency cap

> **Status: DESIGN, adversarially reviewed. Partially validated on cluster.**
> Supersedes the first draft. Incorporates: live diagnosis (kaniko CACHE HIT=0),
> the real app Dockerfile, a multi-agent research pass, and an adversarial
> verify that found 3 blockers + several holes (folded in below). Execution is
> staged behind a flag; each stage has a measurable gate. Cluster changes apply
> via kubectl/render_apply from the operator machine; only a full re-clone +
> bootstrap on the WSL host needs the user.

## Diagnosis (measured, not assumed)

`build-and-push` (kaniko v1.5.1, archived) is 12–41 min = ~85% of pipeline. Live
TaskRun log of a 41-min build: **kaniko CACHE HIT = 0**, CACHE MISS = 4. Timeline:
first `pnpm install` ~7.8 min, prod-deps `pnpm install` ~20.7 min. Base-image
pull is fast. So the cost is **dependency install re-run every build with zero
layer-cache reuse**.

Two root causes, from the real Dockerfile (`smithyhaus/fst-procurement-service`,
Node22·pnpm·NestJS+Prisma, 4 stages deps/build/prod-deps/runtime):

1. **`--single-snapshot` defeats `--cache=true`.** `platform/lib/registry-config.sh`
   builds `KANIKO_EXTRA_ARGS="… --cache=true --cache-repo=… --single-snapshot …"`.
   `--single-snapshot` collapses the build to ONE final-filesystem layer, so kaniko
   never writes/reads per-command cache layers → CACHE HIT=0 by construction. The
   Dockerfile is otherwise cache-friendly (`COPY package.json pnpm-lock.yaml* ./`
   BEFORE `pnpm install`), so per-layer caching *would* hit on an unchanged lockfile.

2. **`pnpm update "@hy/*"` floats internal packages every build** (in both deps and
   prod-deps RUN lines). This is a deliberate "always take latest internal package"
   pattern. It is *correctness-incompatible with layer caching*: once the install
   layer caches, the update is frozen and builds ship stale `@hy/*`. So **any**
   layer-cache win (kaniko OR buildkit registry cache) is unsafe for these apps
   until `@hy/*` is pinned in the lockfile and the `pnpm update` line removed —
   an app-repo change.

## Why buildkit (not just the kaniko flag fix)

- Removing `--single-snapshot` restores kaniko layer caching → fast **unchanged-
  lockfile** builds. But (a) it inherits the `@hy/*` staleness gate, and (b) it does
  NOT help a **changed-lockfile** build (the 20-min install still re-downloads).
- The only approach that is **both fast and correct while keeping `@hy/*` floating**
  is buildkit `RUN --mount=type=cache` on the pnpm store: the store keeps the
  downloaded tarballs across builds, so `pnpm install`/`pnpm update` re-resolve at
  LAN speed without re-downloading, and the result is always a fresh, correct
  install (no frozen layer). This is the target end-state.
- buildkit also gives registry cache `mode=max`, native concurrency throttling in
  one daemon, and content-addressed (correctness-safe) cache keys.

## Architecture (corrected after adversarial review)

- **A dedicated `buildkit` namespace labeled `pod-security.kubernetes.io/enforce=privileged`.**
  BLOCKER found + VALIDATED: `tekton-pipelines` is `enforce=baseline`
  (`bootstrap.d/08-argocd-tekton.sh`, `core/k8s/00-namespaces.yaml`), which **forbids
  `privileged:true`** — a privileged buildkitd there is rejected at admission. A probe
  confirmed a privileged pod IS admitted in a `enforce=privileged`-labeled namespace.
  kaniko survives baseline only via `runAsUser:0` (root ok, privileged not).
- **One long-lived rootful (privileged) `buildkitd` Deployment** owning a persistent
  RWO local-path PVC at `/var/lib/buildkit` (layer cache + pnpm store survive runs).
  `strategy: Recreate` (RWO, single node). SPOF (a daemon OOM kills all in-flight
  builds) — accepted for single-tenant homelab; size memory generously.
- **A thin `buildkit` client Task in `tekton-pipelines`** (non-privileged → passes
  baseline) that runs `buildctl --addr tcp://buildkitd.buildkit.svc.cluster.local:1234
  build …`. Drop-in for the kaniko Task: same IMAGE/DOCKERFILE/CONTEXT/EXTRA_ARGS
  params, source+dockerconfig workspaces, IMAGE_DIGEST/IMAGE_URL results.
- **daemon `buildkitd.toml`**: `[registry."docker.io"] mirrors=["docker.m.daocloud.io"]`;
  `[registry."docker-registry.registry.svc.cluster.local:5000"] http=true insecure=true`
  (daemon does all pulls/pushes). GC sized UNDER the PVC (blocker: default 70GB > 50Gi
  PVC → ENOSPC): on a 50Gi PVC use `maxUsedSpace=40GB, reservedSpace=8GB, minFreeSpace=5GB`.
  `worker.oci max-parallelism` caps concurrent build steps (the real concurrency governor).
- **Cutover behind `BUILD_ENGINE_TASK`** (default `kaniko`, kept vendored+applied) —
  a single `taskRef` name in `pipeline-build.yaml`; rollback = flip one word.

## Unproven on WSL2 — MUST validate before cutover (adversarial holes)

1. **overlayfs snapshotter under nested k3s** — buildkit's default overlayfs inside
   k3s's overlayfs is a known WSL2 failure mode; may need `snapshotter="native"` or
   fuse-overlayfs. Gate: buildkitd pod reaches Ready (readinessProbe = `buildctl debug
   workers`) AND a throwaway build snapshots.  ← probe underway this session.
2. **RUN sandbox DNS** — buildkit's build sandbox may not inherit CoreDNS, so
   `@hy/*` fetch from `host.docker.internal:4873` / verdaccio could fail to resolve.
   Gate: a throwaway build whose RUN curls the Verdaccio host succeeds.
3. **buildkit image tag+digest** — pin a REAL tag resolved via the daocloud mirror
   (probe uses `v0.16.0`; verify before wiring the daemon+client to the same digest).
4. **IMAGE_DIGEST** parsed from buildctl `--metadata-file` — validate non-empty on
   first run (update-manifest keys off the tag, not digest, so a miss degrades gracefully).

## Staged rollout (each stage gated by a measurement)

- **Stage 0 — feasibility probe** (throwaway, no repo change): privileged buildkitd
  in a probe namespace; confirm Ready + `buildctl debug workers` healthy + one test
  build snapshots + resolves the Verdaccio DNS. GO/NO-GO for the whole plan.
- **Stage 1 — daemon + client Task, inert**: commit `core/k8s/06-buildkit/{namespace,
  configmap,deployment,service,pvc}.yaml` + `task-buildkit.yaml`; wire Phase 8 to apply
  them; keep `BUILD_ENGINE_TASK=kaniko`. Validation: daemon Ready, Task applies.
- **Stage 2 — cut ONE service to buildkit** via a manual PipelineRun with the buildkit
  task; measure cold build (populates cache) then a warm rebuild of the SAME commit.
  Gate: warm `build-and-push` < 50% of the kaniko baseline for that service; image runs.
- **Stage 3 — app correctness + pnpm store (app-repo change, REQUIRED before default)**:
  in each `fst-*` repo, pin `@hy/*` in `pnpm-lock.yaml` + drop `pnpm update "@hy/*"`,
  and add `RUN --mount=type=cache,target=/root/.local/share/pnpm/store,sharing=shared …`
  to the install RUNs. (`sharing=shared` not `locked` so concurrent builds don't queue
  on one lock; pnpm store is concurrency-tolerant.) Gate: changed-lockfile warm build's
  install drops to download-delta.
- **Stage 4 — concurrency cap**: a `ResourceQuota` (+ `LimitRange`) on tekton-pipelines
  caps concurrent build TaskRun pods (Tekton holds excess TaskRuns *Pending*, not
  Failed). Right-size the thin client pod's requests DOWN (real CPU burns in the daemon,
  governed by `max-parallelism`). LimitRange MUST land before the quota/first run.
- **Stage 5 — flip default** to buildkit only after ≥3 green real builds; keep kaniko
  vendored for one-word rollback. Optionally re-add the base-image prewarm Job for
  Java/.NET (kept out of this iteration).

## Rollback

Flip `BUILD_ENGINE_TASK=kaniko` (or revert the pipeline commit) + re-render Phase 8.
kaniko Task stays vendored+applied throughout. Never delete `buildkitd-cache` PVC
(Delete reclaim = cache lost); the pruner only reaps PipelineRuns + Failed pods.

## Cheap interim option (documented, NOT auto-enabled)

Removing `--single-snapshot` from `registry-config.sh` restores kaniko caching for
unchanged-lockfile builds with zero new infra — BUT carries the same `@hy/*`
staleness gate, so it is unsafe to enable before the Stage-3 app fix. Listed for
completeness; the buildkit path is preferred because it keeps `@hy/*` floating AND
fast.
