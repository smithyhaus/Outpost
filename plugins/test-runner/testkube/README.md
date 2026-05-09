# test-runner / testkube

Kubernetes-native test orchestration. Used by both Gate A (pre-deploy, in Tekton pipeline) and Gate B (post-deploy, in Argo Rollouts analysis) — **the same test definition serves both gates**.

## What gets installed

bootstrap.sh runs (auto-downloads helm if absent — pinned to v3.16+):

```bash
helm install testkube oci://registry-1.docker.io/kubeshop/testkube \
  --namespace testkube --create-namespace
```

Then this plugin's `manifest.yaml`:
- `ConfigMap/outpost-test-runner` in `tekton-pipelines` — tells the run-tests Task to invoke `testkube run testworkflow ...`.
- `ResourceQuota/testkube-quota` in `testkube` — keeps a runaway test from OOM'ing the cluster.

## How tests are wired

In your application repo, add `outpost.test.yaml`:

```yaml
version: 1
sidecars:
  - name: postgres
    image: postgres:16-alpine
    env: { POSTGRES_PASSWORD: testpass }
runner:
  image: my-app/test:latest          # OR dockerfile: ./Dockerfile.test
  command: ["pytest", "-v"]
gates:
  pre-deploy:
    timeout: 10m
  post-deploy-smoke:
    enabled: true
    image: my-app/smoke:latest
    timeout: 5m
```

The Tekton `run-tests` Task converts this into a `TestWorkflow` CRD on the fly and invokes `testkube run testworkflow <repo>-pre-deploy --watch`. Failure code → pipeline aborts → notify-task fires → manifest never updated.

## How to enable

```env
TEST_RUNNER=testkube
TESTKUBE_MODE=oss             # default; bootstrap auto-installs the agent
```

For Pro/Cloud (Phase 2 — not in MVP):

```env
TESTKUBE_MODE=cloud
TESTKUBE_CLOUD_API_KEY=tkcapi_...
```

## Caveats

- Each `TestWorkflow` run spins ≥1 pod. The default ResourceQuota is intentionally tight (8Gi RAM / 4 CPU requests). Bump it in `manifest.yaml` if your tests are heavy.
- TestWorkflow logs are stored by Testkube's MongoDB sidecar. On a tiny cluster, you may want to set a retention policy (`testkube.tests.history` field).
- The bundled `testkube-cli:latest` is pinned at install — bump deliberately, not by re-running bootstrap.

## References

- Testkube + Tekton integration: https://docs.testkube.io/articles/tekton
- TestWorkflow CRD reference: https://docs.testkube.io/articles/test-workflows-creating
