from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

app = FastAPI(title="hello-python", docs_url=None, redoc_url=None)


@app.get("/", response_class=PlainTextResponse)
def root() -> str:
    return (
        "Hello from Python!\n\n"
        "If you see this through your Outpost domain, the full-mode CI/CD\n"
        "pipeline is working: git push -> Tekton build -> registry ->\n"
        "ArgoCD sync -> Traefik -> here.\n"
    )


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    return "ok\n"
