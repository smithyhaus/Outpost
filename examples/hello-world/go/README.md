# hello-go

Plain `net/http` for smoke-testing the Outpost CI/CD pipeline.

- Single `main.go`, two endpoints, no external deps
- Static binary in a `scratch` image — final image ~5 MB
- Fastest to build and the cheapest to run of the six samples

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
