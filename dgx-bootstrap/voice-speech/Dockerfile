ARG SPEACHES_BASE_IMAGE=ghcr.io/speaches-ai/speaches@sha256:2fedebb4b4dccd37ab8f233374ae32bd5b11ee96e8033d2a0a230b9cd052e409
FROM ${SPEACHES_BASE_IMAGE}

USER root
COPY verify_phonemizer.py /tmp/verify_phonemizer.py
RUN /home/ubuntu/speaches/.venv/bin/python /tmp/verify_phonemizer.py \
    && rm /tmp/verify_phonemizer.py
USER ubuntu
