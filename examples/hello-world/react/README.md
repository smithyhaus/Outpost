# hello-react

Smallest possible React app for smoke-testing the Outpost CI/CD pipeline.

- Vite 5 + React 18, built once at image-build time
- Served statically by `nginx:1.27-alpine` on port 8080
- nginx itself answers `/healthz` (no app code in the hot path)

## Local sanity check (optional)

```bash
docker build -t hello-react:dev .
docker run --rm -p 8080:8080 hello-react:dev
curl http://localhost:8080/         # → HTML page
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-react"
git remote add origin https://gitee.com/<you>/hello-react.git
git push -u origin main
```

## Wire up the manifest repo

Copy the four YAMLs (3 in `manifest/`, plus `argocd-application.yaml`)
into your manifest repo. Replace `example.com` and the manifest repo
URL with your real values.

Full walkthrough: `../README.md`.
