# rollout / argo-rollouts

Progressive delivery + **automated rollback**. v0.3: controller-only,
**default OFF** (`ROLLOUT_PLUGIN=none`) — opt in per-cluster, then opt in
per-app by adopting the `Rollout` CRD.

## What gets installed (when ROLLOUT_PLUGIN=argo-rollouts)

bootstrap.sh applies the vendored, version-pinned controller (server-side,
like other CRD-heavy installs):

```bash
kubectl apply --server-side=true --force-conflicts \
  -f core/k8s/vendor/argo-rollouts-install-v1.9.0.yaml
```

Then this plugin's resources:
- `ConfigMap/outpost-rollout` in `argo-rollouts` — strategy + thresholds marker
- `AnalysisTemplate/outpost-default` in `argo-rollouts` — Web provider HTTP probe (no Testkube needed)
- `AnalysisTemplate/outpost-smoke` in `argo-rollouts` — Job provider runs a Testkube TestWorkflow
- ServiceAccount + ClusterRoleBinding so the smoke Job can call the Testkube API

**No dashboard, no IngressRoute** — the v0.2-era Rollouts dashboard + Traefik
BasicAuth wiring is retired along with Tekton/ArgoCD. Canary progress is now
visible via `kubectl argo rollouts get rollout <name> --watch` or
`kubectl describe rollout <name>`.

## Default thresholds (unchanged)

```yaml
failureLimit: 2              # 2 consecutive analysis failures = abort
consecutiveErrorLimit: 3     # 3 consecutive provider errors = treat as flaky
interval: 30s
successCondition: result == "Passed" # for Job provider
                            # OR result == 200 for Web provider
```

## How apps adopt it

Convert your `Deployment` → `Rollout` in the manifest repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
  namespace: apps
spec:
  replicas: 3
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 30s }
        - analysis:
            templates:
              - templateName: outpost-default      # OR outpost-smoke
              - templateName: outpost-smoke         # only if test-runner=testkube
            args:
              - name: service-name
                value: my-app
              - name: app-name
                value: my-app
        - setWeight: 50
        - pause: { duration: 30s }
        - setWeight: 100
  selector:
    matchLabels: { app: my-app }
  template: { ... }    # same as Deployment.spec.template
```

The manifest-sync CronJob is **Rollout-kind aware**: it waits on the
Rollout's rollout status the same way it waits on a plain Deployment
rollout before reporting `deploy-succeeded`. If analysis fails at any step →
automatic rollback to the previous stable ReplicaSet → the sync job reports
`deploy-failed` and `notify-fanout.sh` fans that out to every enabled
notification channel.

## How to enable

```env
ROLLOUT_PLUGIN=argo-rollouts    # default: none (controller not installed)
```

## Caveats

- Plugin install does **not** force-convert existing Deployments. You opt apps in by editing their manifests in the manifest repo.
- The smoke template requires `test-runner=testkube`.
- No bundled dashboard in v0.3 — use `kubectl argo rollouts` CLI plugin for a terminal UI.

## References

- Argo Rollouts AnalysisTemplate: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts Best Practices: https://argo-rollouts.readthedocs.io/en/stable/best-practices/
