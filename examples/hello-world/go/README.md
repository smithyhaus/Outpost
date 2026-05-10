# hello-go

Plain `net/http` for smoke-testing the Outpost CI/CD pipeline.

- Single `main.go`, two endpoints, no external deps
- Static binary in a `scratch` image — final image ~5 MB
- Fastest to build and the cheapest to run of the six samples
- **`manifest/` ships the kustomize layout** — `kustomization.yaml` +
  three resources. On each push the Tekton `update-manifest` task
  rewrites `.images[name=registry.<root>/hello-go].newTag` rather than
  patching `deployment.yaml` directly. To try the legacy mode instead,
  delete `manifest/kustomization.yaml` before copying.
- **`manifest/rollout.yaml` is an Argo Rollouts variant** — same Pod
  spec, wrapped in a Rollout CRD with a canary + auto-rollback strategy.
  Use it to demo / verify Phase J. Pick one:
  - `git rm rollout.yaml` → keep the simple `Deployment` (default)
  - `git rm deployment.yaml` → use the canary `Rollout` (analysis fails →
    automatic traffic restore to the previous stable ReplicaSet)

## Local sanity check

```bash
docker build -t hello-go:dev .
docker run --rm -p 8080:8080 hello-go:dev
curl http://localhost:8080/         # → Hello from Go! ...
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-go"
git remote add origin https://gitee.com/<you>/hello-go.git
git push -u origin main
```

Full smoke-test walkthrough: `../README.md`.
