FROM python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

ARG DF_SLIM_VERSION=0.1.0
ARG DF_SLIM_WHEEL=deepfilternet_slim-0.1.0-py3-none-manylinux_2_28_aarch64.whl
ARG DF_SLIM_SHA256=4aff696052c40ed73a1b26c5364529222f0ca15de759995e1ce2dea7466be3b8

RUN groupadd --system --gid 10006 exodenoise \
    && useradd --system --uid 10006 --gid exodenoise --home-dir /nonexistent --shell /usr/sbin/nologin exodenoise \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --requirement /app/requirements.txt \
    && pip download --no-deps --only-binary=:all: \
       --platform manylinux_2_28_aarch64 --python-version 311 --implementation cp \
       --dest /tmp "deepfilternet-slim==$DF_SLIM_VERSION" \
    && echo "$DF_SLIM_SHA256  /tmp/$DF_SLIM_WHEEL" | sha256sum --check --strict \
    && pip install --no-deps "/tmp/$DF_SLIM_WHEEL" \
    && rm "/tmp/$DF_SLIM_WHEEL"

COPY server.py /app/server.py
USER 10006:10006
EXPOSE 8000
ENTRYPOINT ["python", "/app/server.py"]
