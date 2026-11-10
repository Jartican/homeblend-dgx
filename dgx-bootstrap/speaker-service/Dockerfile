FROM nvcr.io/nvidia/nemo@sha256:5852a213751955315a5dd54ce50eff69ac87d474f33968135fc88f1cdbb1dd06

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*
RUN python -m pip install --no-cache-dir --requirement /app/requirements.txt
# NeMo's editable megatron-core package resolves through this source tree. The
# upstream image restricts its 3rdparty directory to root even though the code
# is not secret. Grant read/execute only so the runtime can remain non-root.
RUN chmod -R a+rX /opt/Megatron-Bridge/3rdparty
RUN groupadd --system --gid 10004 exospeaker \
    && useradd --system --uid 10004 --gid exospeaker --home-dir /vault/cache --shell /usr/sbin/nologin exospeaker
COPY --chown=10004:10004 core.py server.py /app/
COPY --chown=10004:10004 tests /app/tests

ENV HOME=/vault/cache PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10004:10004
EXPOSE 8000
ENTRYPOINT ["python", "/app/server.py"]
