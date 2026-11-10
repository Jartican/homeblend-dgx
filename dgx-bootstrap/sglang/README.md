# SGLang Qwen3.8 27B runtime

This Compose service runs the active Exocortex quality model with SGLang. It
uses the Qwen3.8 27B NVFP4 base checkpoint without the incompatible DSpark
speculative draft path observed on SGLang v0.5.18.

The HTTP port binds to loopback because LiteLLM is the authenticated gateway.
No Hugging Face token is stored in Compose. Public checkpoints download without
one; if a future private checkpoint requires authentication, inject a scoped
token at execution time and never commit it.

The static memory fraction is 0.45 and maximum context is 131,072 tokens so the
27B server can coexist with the Qwen 8B vLLM service on a 128 GB DGX Spark.

```bash
cd ~/dgx-spark-llm
docker compose up -d --force-recreate sglang-qwen
curl -fsS http://127.0.0.1:30000/v1/models
```

The Ollama `qwen3.8:27b` files may remain installed as an offline fallback, but
do not keep that runtime loaded while SGLang and vLLM are active.
