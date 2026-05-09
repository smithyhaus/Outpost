# hello-world-python smoke tests.
# Phase 2: wired in by switching outpost.test.yaml runner.command to `pytest tests/`.
from fastapi.testclient import TestClient

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from main import app  # noqa: E402

client = TestClient(app)


def test_healthz_returns_ok():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_root_returns_greeting():
    r = client.get("/")
    assert r.status_code == 200
    assert "Hello from Python" in r.json()["message"]
