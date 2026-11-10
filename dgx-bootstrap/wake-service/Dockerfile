FROM python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

ARG KWS_MODEL_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2
ARG KWS_MODEL_SHA256=f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a

RUN groupadd --system --gid 10005 exowake \
    && useradd --system --uid 10005 --gid exowake --home-dir /nonexistent --shell /usr/sbin/nologin exowake \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl bzip2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --requirement /app/requirements.txt \
    && mkdir -p /opt/kws \
    && curl --fail --location --output /tmp/kws.tar.bz2 "$KWS_MODEL_URL" \
    && echo "$KWS_MODEL_SHA256  /tmp/kws.tar.bz2" | sha256sum --check --strict \
    && tar --extract --bzip2 --file /tmp/kws.tar.bz2 --strip-components=1 --directory /opt/kws \
    && rm /tmp/kws.tar.bz2 \
    && chmod -R a+rX /opt/kws

COPY server.py /app/server.py
USER 10005:10005
EXPOSE 8000
ENTRYPOINT ["python", "/app/server.py"]
