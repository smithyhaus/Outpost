# hello-vue

Smallest possible Vue app for smoke-testing the Outpost CI/CD pipeline.

- Vite 5 + Vue 3 (Composition API not needed for this size — plain SFC)
- Built once at image-build time, served by `nginx:1.27-alpine` on 8080
- nginx itself answers `/healthz`

## Local sanity check

```bash
docker build -t hello-vue:dev .
docker run --rm -p 8080:8080 hello-vue:dev
curl http://localhost:8080/         # → HTML page
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-vue"
git remote add origin https://gitee.com/<you>/hello-vue.git
git push -u origin main
```

Full smoke-test walkthrough: `../README.md`.
