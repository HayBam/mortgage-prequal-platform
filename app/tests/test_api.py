import pytest
from fastapi.testclient import TestClient

import main

GOOD_BODY = {"annual_income": 150000, "loan_amount": 450000, "contract_rate": 4.5,
             "property_tax_annual": 4800, "other_debt_monthly": 300}


@pytest.fixture
def client(tmp_path, monkeypatch):
    key_file = tmp_path / "broker-api-key"
    key_file.write_text("test-key\n")
    monkeypatch.setattr(main, "API_KEY_FILE", key_file)
    return TestClient(main.app)


def test_health_and_ready(client):
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").status_code == 200


def test_not_ready_without_key(client, monkeypatch, tmp_path):
    monkeypatch.setattr(main, "API_KEY_FILE", tmp_path / "missing")
    assert client.get("/readyz").status_code == 503


def test_prequalify_needs_api_key(client):
    assert client.post("/v1/prequalify", json=GOOD_BODY).status_code == 401
    assert client.post("/v1/prequalify", json=GOOD_BODY, headers={"X-API-Key": "wrong"}).status_code == 401


def test_prequalify_approves(client):
    r = client.post("/v1/prequalify", json=GOOD_BODY, headers={"X-API-Key": "test-key"})
    assert r.status_code == 200
    assert r.json()["approved"] is True


def test_invalid_input_is_rejected(client):
    r = client.post("/v1/prequalify", json={**GOOD_BODY, "annual_income": -1},
                    headers={"X-API-Key": "test-key"})
    assert r.status_code == 422


def test_metrics_exposed(client):
    client.post("/v1/prequalify", json=GOOD_BODY, headers={"X-API-Key": "test-key"})
    body = client.get("/metrics").text
    assert "prequal_decisions_total" in body
    assert 'path="/v1/prequalify"' in body


def test_portal_page_is_served_with_strict_csp(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "Haventree Bank<span" in r.text and "-Interview" in r.text
    assert "not affiliated" in r.text  # the disclaimer must stay on the page
    csp = r.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "unsafe-inline" not in csp
    assert r.headers["x-frame-options"] == "DENY"


def test_portal_assets_are_served(client):
    for path, kind in [("/static/app.js", "javascript"), ("/static/app.css", "text/css"),
                       ("/static/fonts/PlusJakartaSans-latin.woff2", "font/woff2")]:
        r = client.get(path)
        assert r.status_code == 200, path
        assert kind in r.headers["content-type"], path


def test_decisions_are_never_cached(client):
    r = client.post("/v1/prequalify", json=GOOD_BODY, headers={"X-API-Key": "test-key"})
    assert r.headers["cache-control"] == "no-store"


def test_api_docs_still_work(client):
    # Swagger UI loads from a CDN, so /docs must not get the strict CSP.
    r = client.get("/docs")
    assert r.status_code == 200
    assert "content-security-policy" not in r.headers
