FROM python:3.12-slim@sha256:09f7da3bc104798d0afb40bc08d23ab2da20a76130cec1f2ef170848f5d85217

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system --gid 10003 exovoice \
    && useradd --system --uid 10003 --gid exovoice --home-dir /nonexistent --shell /usr/sbin/nologin exovoice \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --requirement /app/requirements.txt
COPY core.py realtime_adapters.py realtime_auth.py realtime_core.py realtime_modes.py realtime_pipeline.py realtime_protocol.py realtime_runtime.py realtime_simulator.py server.py client.html speaker.html transcript.html /app/
COPY homeblend-client /app/homeblend-client
COPY tests /tmp/voice-gateway-tests
RUN PYTHONPATH=/app python -m unittest discover -s /tmp/voice-gateway-tests -p 'test_*.py' \
    && rm -rf /tmp/voice-gateway-tests
RUN chmod -R a+rX /app/homeblend-client \
    && install -d -o 10003 -g 10003 -m 0700 /var/lib/homeblend

USER 10003:10003
EXPOSE 8791
ENTRYPOINT ["python", "/app/server.py"]
