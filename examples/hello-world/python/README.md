# hello-python

FastAPI + uvicorn for smoke-testing the Outpost CI/CD pipeline.

- Single `main.py`, two endpoints, no DB
- Uvicorn in production mode with `--no-access-log` (you can remove for debugging)
- Final image: `python:3.12-slim` (~140 MB after deps)

## Local sanity check

```bash
docker build -t hello-python:dev .
docker run --rm -p 8080:8080 hello-python:dev
curl http://localhost:8080/         # → Hello from Python! ...
curl http://localhost:8080/healthz  # → ok
```

## Push as your application repo

```bash
git init && git checkout -b main
git add .
git commit -m "init: hello-python"
git remote add origin https://gitee.com/<you>/hello-python.git
git push -u origin main
```

Full smoke-test walkthrough: `../README.md`.
