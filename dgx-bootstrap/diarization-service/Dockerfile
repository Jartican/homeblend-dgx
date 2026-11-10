FROM nvcr.io/nvidia/nemo@sha256:5852a213751955315a5dd54ce50eff69ac87d474f33968135fc88f1cdbb1dd06

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --requirement /app/requirements.txt \
    && chmod -R a+rX /opt/Megatron-Bridge/3rdparty
RUN groupadd --system --gid 10004 exovoice \
    && useradd --system --uid 10004 --gid exovoice --home-dir /vault/cache --shell /usr/sbin/nologin exovoice
COPY --chown=10004:10004 server.py /app/server.py

ENV HOME=/vault/cache PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10004:10004
EXPOSE 8000
ENTRYPOINT ["python", "/app/server.py"]
