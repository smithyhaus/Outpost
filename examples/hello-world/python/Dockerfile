# syntax=docker/dockerfile:1
# ============================================================================
# Hello-Python — FastAPI + uvicorn
# ============================================================================
FROM python:3.12-slim AS base
WORKDIR /app

# System deps for uvicorn[standard] (httptools / uvloop wheels are prebuilt
# on most platforms but a compiler is needed if a wheel is missing).
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz').read()" || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
