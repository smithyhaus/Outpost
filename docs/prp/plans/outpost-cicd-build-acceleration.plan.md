# Plan: CI/CD Build Acceleration (kaniko→buildkit + persistent cache + base prewarm)

> **Status: DESIGN — needs cluster validation. NOT yet implemented.**
> The fail-fast reorder (run-tests before build) and webhook auto-registration
> shipped separately and are live. This plan covers the remaining per-build
> latency wins, all of which mutate the live build path and therefore must be
> validated on the WSL2 cluster before merge. Do not mark done from a laptop.

## Summary

After moving Gate A (`run-tests`) ahead of the image build, the dominant
remaining latency is the image build itself. Root causes, evidence-anchored:

1. **kaniko v1.5.1** (`core/k8s/05-tekton/catalog/kaniko-0.7.yaml:54`) — pinned to
   a 2021 build of an **archived** project (`tekton.dev/deprecated: "true"`,
   line 34). Slow layer snapshotting on multi-stage Dockerfiles; the 90-min
   task budget (`pipeline-build.yaml`) exists because of it.
2. **Fresh empty workspace per run** (`triggertemplate.yaml:64-72`) — every
   PipelineRun gets a new 5Gi `local-path` PVC. No on-disk dependency cache
   (npm/maven/nuget) survives between builds; only kaniko's registry-backed
   layer cache (`--cache-repo`) helps, and only when layers are unchanged.
3. **Base-image pulls over the CN mirror every cold build**
   (`m.daocloud.io` in `kaniko-0.7.yaml:54-57`) — the single biggest slice of a
   cold Java/.NET build.

This plan replaces kaniko with **buildkit** (native parallelism + registry
`mode=max` cache + inline cache), adds a **persistent dependency-cache
workspace**, and **prewarms base images** into the in-cluster registry.

## Problem → Solution

**Current**: serial kaniko build, cold every time, base images re-pulled over a
flaky CN mirror. Multi-stage builds routinely approach the 90-min cap.

**Desired**: buildkit builds with warm layer + dependency caches and locally
mirrored base images, so a typical incremental build drops from tens of minutes
to a few, and cold builds stop re-pulling bases over public egress.

## Metadata

- **Complexity**: High (touches the live build task + workspace model; needs cluster)
- **Risk**: High — build path change; **must** be staged behind a flag with a kaniko fallback
- **Files**: 1 CREATE buildkit Task, 1 UPDATE pipeline (flagged branch), 1 CREATE prewarm Job, 1 UPDATE registry-config lib, tests
- **Prereq**: registry supports cache export (`docker-registry` distribution: yes; ACR: yes)

---

## Stage 1 — buildkit Task (drop-in, behind a flag)

Add a new Task alongside kaniko (do **not** delete kaniko). Select via a new
`BUILD_ENGINE` env (`kaniko` default, `buildkit` opt-in) so rollback is a
one-line revert. Draft Task (rootless buildkitd, in-pod):

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: buildkit
  namespace: tekton-pipelines
spec:
  params:
    - name: IMAGE
    - name: DOCKERFILE
      default: ./Dockerfile
    - name: CONTEXT
      default: ./
    - name: EXTRA_ARGS           # platform args from read-build-config
      type: array
      default: []
    - name: CACHE_REPO           # e.g. docker-registry.registry.svc.cluster.local:5000/cache
  workspaces:
    - name: source
    - name: dockerconfig
      optional: true
      mountPath: /root/.docker
    - name: cache                # persistent dep cache (Stage 2); optional
      optional: true
  steps:
    - name: build
      # Pin a digest + mirror it via scripts/vendor-tekton-catalog.sh, same as kaniko.
      image: m.daocloud.io/docker.io/moby/buildkit:v0.16.0-rootless
      workingDir: $(workspaces.source.path)
      securityContext:            # rootless still needs these on containerd/WSL2
        seccompProfile: { type: Unconfined }
        runAsUser: 1000
        runAsGroup: 1000
      script: |
        #!/usr/bin/env sh
        set -e
        # Local daemon so we control the mirror + insecure registry.
        buildctl-daemonless.sh build \
          --frontend dockerfile.v0 \
          --local context=$(workspaces.source.path)/$(params.CONTEXT) \
          --local dockerfile=$(dirname $(params.DOCKERFILE)) \
          --opt filename=$(basename $(params.DOCKERFILE)) \
          --output type=image,name=$(params.IMAGE),push=true,registry.insecure=true \
          --export-cache type=registry,ref=$(params.CACHE_REPO),mode=max,registry.insecure=true \
          --import-cache type=registry,ref=$(params.CACHE_REPO),registry.insecure=true
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
        - name: DOCKER_CONFIG
          value: /root/.docker
```

Notes / open questions for cluster validation:
- **Rootless on WSL2 containerd**: confirm `--oci-worker-no-process-sandbox` +
  Unconfined seccomp is accepted, else fall back to privileged buildkitd or a
  buildkit `Deployment` + `buildctl` remote (`--addr tcp://buildkitd:1234`).
- **Insecure registry**: mirror the `--skip-tls-verify/--insecure` posture the
  self-hosted branch already uses for kaniko (`registry-config.sh:75`).
- `mode=max` exports **all** layer caches (incl. intermediate) — the big
  multi-stage win. Verify the self-hosted `docker-registry` accepts cache
  manifests (distribution registry does).

## Stage 2 — persistent dependency cache workspace

kaniko can't use a host dep cache (it builds inside image layers), but buildkit
`RUN --mount=type=cache` can. Add a **named, reused** PVC workspace (not a
per-run `volumeClaimTemplate`) mounted at the buildkit cache dir so `.m2` / npm
store / nuget survive across builds.

- Single-node WSL2 → `ReadWriteOnce` local-path is fine; Tekton's affinity
  assistant co-locates pods. **Concurrency caveat**: two builds sharing one RWO
  PVC serialize. Options: (a) accept serialization (single-node dev is already
  effectively serial), or (b) one cache PVC **per app** keyed by repo-name.
  Recommend (b): a per-run `volumeClaimTemplate` can't key on repo-name, so
  pre-create `cache-<app>` PVCs during onboarding and bind by name.
- Dockerfiles must opt in with `RUN --mount=type=cache,target=/root/.m2 ...`.
  Document this in the onboarding guide; no-op for apps that don't.

## Stage 3 — base-image prewarm

Prime the in-cluster registry so cold builds pull bases from `svc.cluster.local`
instead of the CN mirror. A CronJob/Job that `crane copy`s the common bases
(node, maven/temurin, dotnet/sdk+aspnet, python) from the mirror into
`docker-registry.registry.svc.cluster.local:5000`, run once at bootstrap +
weekly refresh. Draft:

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: base-image-prewarm, namespace: registry }
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: prewarm
          image: m.daocloud.io/gcr.io/go-containerregistry/crane:v0.20.2
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              REG=docker-registry.registry.svc.cluster.local:5000
              for b in library/node:20-alpine library/maven:3.9-eclipse-temurin-21 \
                       library/python:3.12-slim ; do
                crane copy --insecure m.daocloud.io/docker.io/$b $REG/base/$b
              done
```
Then set buildkit's `--opt build-arg:BASE_MIRROR=$REG/base` (or a Dockerfile ARG
convention) so app images pull bases in-cluster. Requires an app-side ARG
convention — document, keep optional.

## Staged rollout

1. Land Stage 1 buildkit Task **inert** (`BUILD_ENGINE=kaniko` default). Verify
   the Task applies and a manual PipelineRun with `BUILD_ENGINE=buildkit` on ONE
   throwaway app behaves correctly.
2. Flip one real app to buildkit; compare wall-clock cold + warm vs kaniko.
3. Add Stage 3 prewarm; re-measure cold builds.
4. Add Stage 2 cache workspace + one Dockerfile `--mount=type=cache`; re-measure.
5. Only after 3 green real-app builds: consider making buildkit the default.

## Validation (definition of done — cluster required)

- [ ] `kubectl apply` of the buildkit Task succeeds; a PipelineRun with
      `BUILD_ENGINE=buildkit` reaches `Succeeded`.
- [ ] Built image runs identically to the kaniko-built one (same entrypoint,
      same digest of app layers where inputs unchanged).
- [ ] **Measured**: warm incremental build wall-clock < 50% of the kaniko
      baseline for the same commit (capture `kubectl get pipelinerun` durations,
      paste PASS/FAIL numbers into the report).
- [ ] Cold build no longer pulls bases from `m.daocloud.io` (grep buildkit logs
      for the in-cluster registry host instead).
- [ ] kaniko path still works when `BUILD_ENGINE=kaniko` (fallback intact).
- [ ] `verify.sh` still green; bats still green.

## Rollback

Set `BUILD_ENGINE=kaniko` (or revert the pipeline flag commit) and re-bootstrap
Phase 8. kaniko Task is never deleted until buildkit has 2 weeks of green real
builds. The prewarm Job and cache PVCs are additive and safe to leave.

## Out of scope / follow-ups

- Deploy-side pull latency (large blobs over cloudflared HTTP/2) — separate plan;
  push already bypasses cloudflared via in-cluster Service (`pipeline-build.yaml`
  registry-push note). Node pull path optimization is its own investigation.
- run-tests `apk add` per run — minor; pin a prebuilt test-runner image later.
