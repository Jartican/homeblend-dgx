FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install --yes --no-install-recommends git ripgrep ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10002 homeblend \
    && useradd --system --uid 10002 --gid homeblend --home-dir /nonexistent --shell /usr/sbin/nologin homeblend

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --requirement /app/requirements.txt
COPY core.py server.py /app/

USER 10002:10002
EXPOSE 8770
ENTRYPOINT ["uvicorn", "server:app", "--host", "127.0.0.1", "--port", "8770", "--no-access-log"]
