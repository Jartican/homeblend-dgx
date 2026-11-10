FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system --gid 10001 exocortex-mcp \
    && useradd --system --uid 10001 --gid exocortex-mcp --home-dir /nonexistent --shell /usr/sbin/nologin exocortex-mcp

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --requirement /app/requirements.txt
COPY server.py /app/server.py
COPY test_mcp.py /app/test_mcp.py

USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["python", "/app/server.py"]
