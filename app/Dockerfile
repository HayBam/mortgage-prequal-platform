# Two-stage build: dependencies are installed in a "build" stage, and only the
# results are copied into the final image. The final image has no build cache
# and nothing beyond what the app needs to run.

# ---- Stage 1: install dependencies ----
FROM python:3.15-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Stage 2: runtime image ----
FROM python:3.15-slim

# The Git commit SHA, passed in by the pipeline and served at /version.
ARG APP_VERSION=dev

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}

# Apply the latest Debian security patches, remove pip, then create an
# unprivileged user. The container never runs as root.
# pip comes with the base image but the app never uses it at runtime. pip also
# carries its own vendored copies of urllib3, msgpack and setuptools, which
# Trivy flags (HIGH) whenever those copies fall behind. Removing pip shrinks
# the attack surface and drops those findings.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip \
 && rm -f /usr/local/bin/pip /usr/local/bin/pip3* \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /install /usr/local
WORKDIR /app
COPY main.py prequal.py ./
COPY static/ ./static/

USER 10001
EXPOSE 8000

# Docker-level health check (Kubernetes uses its own probes from deployment.yaml).
HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
