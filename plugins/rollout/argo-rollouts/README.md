# rollout / argo-rollouts

Progressive delivery + **automated rollback** for the cluster. MVP-required.

## What gets installed

bootstrap.sh applies (server-side, like other CRD-heavy installs):

```bash
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml
```

Then this plugin's resources:
- `ConfigMap/outpost-rollout` in `tekton-pipelines` — strategy + thresholds
- `AnalysisTemplate/outpost-default` in `argo-rollouts` — Web provider HTTP probe (no Testkube needed)
- `AnalysisTemplate/outpost-smoke` in `argo-rollouts` — Job provider runs a Testkube TestWorkflow
- `IngressRoute` for the dashboard at `https://rollouts.${ROOT_DOMAIN}`
- ServiceAccount + ClusterRoleBinding so the smoke Job can call the Testkube API

## Default thresholds (locked decision §10.3)

```yaml
failureLimit: 2              # 2 consecutive analysis failures = abort
consecutiveErrorLimit: 3     # 3 consecutive provider errors = treat as flaky
interval: 30s
successCondition: result == "Passed" # for Job provider
                            # OR result == 200 for Web provider
```

## How apps adopt it

Convert your `Deployment` → `Rollout`:

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

If analysis fails at any step → automatic rollback to the previous stable ReplicaSet → ArgoCD notifications fire (the Application enters `Degraded`/`Suspended`).

## How to enable

```env
ROLLOUTS_DASHBOARD_HOST=rollouts.${ROOT_DOMAIN}    # optional; default shown
```

The plugin is **MVP-required** in `bootstrap.sh` Phase 9 — it is always applied in `full` mode.

## Caveats

- Plugin install does **not** force-convert existing Deployments. You opt apps in by editing their manifests in the manifest repo.
- The smoke template requires `test-runner=testkube`. With `catalog-tasks`, only `outpost-default` (Web HTTP probe) applies.
- Dashboard has no auth — gate it via Cloudflare Access if exposed publicly.

## References

- Argo Rollouts AnalysisTemplate: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts Best Practices: https://argo-rollouts.readthedocs.io/en/stable/best-practices/
