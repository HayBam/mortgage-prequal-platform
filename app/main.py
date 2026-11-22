"""Broker Mortgage Pre-Qualification API.

Endpoints
  GET  /               broker portal web page (calls the API below from the browser)
  POST /v1/prequalify  broker API (needs the X-API-Key header)
  GET  /healthz        liveness probe: the process is running
  GET  /readyz         readiness probe: the broker API key is loaded
  GET  /version        the Git commit this image was built from
  GET  /metrics        Prometheus metrics
"""

import hmac
import json
import logging
import mimetypes
import os
import sys
import time
import uuid
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

from prequal import Application, evaluate

APP_VERSION = os.getenv("APP_VERSION", "dev")
GDS_LIMIT = float(os.getenv("GDS_LIMIT", "0.39"))
TDS_LIMIT = float(os.getenv("TDS_LIMIT", "0.44"))
# The key is mounted from Azure Key Vault as a file by the Secrets Store CSI driver.
API_KEY_FILE = Path(os.getenv("BROKER_API_KEY_FILE", "/mnt/secrets-store/broker-api-key"))
STATIC_DIR = Path(__file__).parent / "static"
# Set the portal's file types explicitly. Minimal images (and Windows) do not
# always know .woff2, and nosniff makes browsers trust the declared type.
mimetypes.add_type("font/woff2", ".woff2")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("text/css", ".css")

# Browser security headers. The portal loads only its own files, so the
# Content-Security-Policy allows nothing from other sites and no inline code.
# /docs and /redoc (FastAPI's API explorer) load their assets from a CDN, so
# they do not get the CSP.
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; "
       "img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; "
       "form-action 'self'; frame-ancestors 'none'")
SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


# --- Logging: one JSON line per event, never any customer financial data ---
class JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {"ts": self.formatTime(record), "level": record.levelname, "msg": record.getMessage()}
        entry.update(getattr(record, "extra_fields", {}))
        return json.dumps(entry)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("prequal")
log.addHandler(handler)
log.setLevel(logging.INFO)


# --- Prometheus metrics ---
REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["method", "path", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency", ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)
DECISIONS = Counter(
    "prequal_decisions_total", "Pre-qualification decisions", ["outcome"]
)


# --- Request and response models (FastAPI validates input against these) ---
class PrequalRequest(BaseModel):
    annual_income: float = Field(gt=0, le=10_000_000, examples=[120000])
    loan_amount: float = Field(gt=0, le=20_000_000, examples=[550000])
    contract_rate: float = Field(gt=0, le=25, description="Annual rate in percent", examples=[4.89])
    amortization_years: int = Field(default=25, ge=5, le=30)
    property_tax_annual: float = Field(default=0, ge=0, examples=[4800])
    heating_monthly: float = Field(default=100, ge=0)
    condo_fees_monthly: float = Field(default=0, ge=0)
    other_debt_monthly: float = Field(default=0, ge=0, examples=[450])


class PrequalResponse(BaseModel):
    request_id: str
    approved: bool
    qualifying_rate: float
    monthly_payment: float
    gds_ratio: float
    tds_ratio: float
    gds_limit: float
    tds_limit: float
    reasons: list[str]


app = FastAPI(title="Broker Mortgage Pre-Qualification API", version=APP_VERSION)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def load_api_key() -> str | None:
    """Read the key on each call so a rotated secret is picked up without a restart."""
    try:
        return API_KEY_FILE.read_text().strip() or None
    except OSError:
        return None


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # Use the route template (/v1/prequalify), not the raw URL, to keep metric labels bounded.
    route = request.scope.get("route")
    path = route.path if route else "unmatched"
    if path != "/metrics":
        REQUESTS.labels(request.method, path, str(response.status_code)).inc()
        LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
    return response


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.update(SECURITY_HEADERS)
    if not request.url.path.startswith(("/docs", "/redoc")):
        response.headers["Content-Security-Policy"] = CSP
    if request.url.path.startswith("/v1/"):
        # Decisions contain financial figures: no browser or proxy may cache them.
        response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/", include_in_schema=False)
def portal():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response):
    if load_api_key() is None:
        response.status_code = 503
        return {"status": "not ready", "reason": "broker API key not loaded"}
    return {"status": "ready"}


@app.get("/version")
def version():
    return {"version": APP_VERSION}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/prequalify", response_model=PrequalResponse)
def prequalify(body: PrequalRequest, x_api_key: str | None = Header(default=None)):
    request_id = str(uuid.uuid4())
    expected = load_api_key()
    # compare_digest takes the same time for any input, so it does not leak the key.
    if expected is None or x_api_key is None or not hmac.compare_digest(x_api_key, expected):
        DECISIONS.labels("unauthorized").inc()
        log.warning("rejected request", extra={"extra_fields": {"request_id": request_id, "reason": "bad api key"}})
        raise HTTPException(status_code=401, detail="invalid or missing API key")

    decision = evaluate(Application(**body.model_dump()), GDS_LIMIT, TDS_LIMIT)
    outcome = "approved" if decision.approved else "declined"
    DECISIONS.labels(outcome).inc()
    # Log the outcome only. Income, debts and loan amount stay out of the logs.
    log.info("decision", extra={"extra_fields": {"request_id": request_id, "outcome": outcome}})
    return PrequalResponse(request_id=request_id, **decision.__dict__)
