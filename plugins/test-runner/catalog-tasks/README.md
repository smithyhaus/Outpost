# test-runner / catalog-tasks

Lightweight alternative to the `testkube` plugin. Uses Tekton's public catalog tasks per language. Good for teams that prefer minimal cluster footprint over a unified test UX.

## What gets installed

`bootstrap.sh` applies the following Tekton catalog tasks into `tekton-pipelines`:

- [golang-test](https://hub.tekton.dev/tekton/task/golang-test)
- [pytest](https://hub.tekton.dev/tekton/task/pytest)
- [jest](https://hub.tekton.dev/tekton/task/jest)
- [junit-runner](https://hub.tekton.dev/tekton/task/junit-runner)
- [dotnet-test](https://hub.tekton.dev/tekton/task/dotnet-test)

## How to enable

```env
TEST_RUNNER=catalog-tasks
```

## Trade-offs vs Testkube

| Aspect | testkube | catalog-tasks |
|---|---|---|
| Cluster footprint | ~6 pods + MongoDB | 0 (tasks run on demand) |
| Unified test config | `outpost.test.yaml` for all languages | Per-language Task params |
| Gate A (pre-deploy) | ✅ | ✅ |
| Gate B (post-deploy via Job analysis) | ✅ | ❌ — fall back to HTTP probe (Web provider) |
| Test result UX | Web dashboard, history | PipelineRun logs only |
| Multi-engine (Cypress, k6, Postman) | ✅ 30+ engines | Per-engine Catalog task or roll-your-own |

## Authoring tests

Each repo's pipeline binds to the language's catalog task directly. There's no shared `outpost.test.yaml` contract. Example for Go:

```yaml
# In your application repo's tekton/pipeline.yaml override
- name: run-tests
  taskRef:
    name: golang-test
    kind: Task
  params:
    - name: package
      value: ./...
```

For full repos, prefer `testkube` for the unified contract.
