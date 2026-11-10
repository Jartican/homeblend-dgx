# HomeBlend DGX

HomeBlend is a private-by-design voice and agent stack for an NVIDIA DGX Spark,
an iPhone companion, and Omi-compatible audio devices. The reusable source,
secure defaults, tests, and example configuration live here. Deployment
identity, personal data, credentials, and live operational state do not.

See [the public/private boundary](docs/PUBLIC-PRIVATE-BOUNDARY.md) before
deploying or publishing changes. New installations should start with
`dgx-bootstrap/bootstrap-new-dgx.sh`; production voice access remains
fail-closed until a named client is enrolled.

## Local models for development

This repository uses a project-local Ollama runtime with model weights stored outside OneDrive at `%LOCALAPPDATA%\Exocortex\ollama\models`.

## Current bootstrap

- Coding: `qwen2.5-coder:3b` (Q4_K_M, about 1.9 GB)
- Fast vision: `qwen2.5vl:3b` (Q4_K_M, about 3.2 GB)
- Optional quality tests: `qwen2.5-coder:7b` and `qwen2.5vl:7b`
- API: `http://127.0.0.1:11434`
- OpenAI-compatible base URL: `http://127.0.0.1:11434/v1`

Start the server and run the coding smoke test:

```powershell
npm.cmd run models:start
npm.cmd run models:smoke
npm.cmd run models:status
```

Test vision with a local image:

```powershell
npm.cmd run models:smoke-vision -- C:\path\to\image.png
```

Pull another model with the project-local runtime:

```powershell
$env:OLLAMA_MODELS = "$env:LOCALAPPDATA\Exocortex\ollama\models"
.\.local\ollama\ollama.exe pull qwen2.5vl:3b
```

Use the OpenAI SDK by setting its base URL to `http://127.0.0.1:11434/v1` and any non-empty API key. The native Ollama endpoints remain available under `/api`.

Keep initial context windows modest (4K-8K) on the 6 GB GPU. Context/KV cache consumes memory in addition to model weights.

Application code calls the provider-neutral gateway in `src/models/gateway.mjs`. Capability routes and concrete model/provider mappings live in `config/models.json`; see `docs/model-gateway.md` for the design.

## Local chat UI

Run the Dash-based local model lab:

```powershell
conda activate .\.conda-env
python app.py
```

Then open `http://127.0.0.1:8050`. It talks directly to the local Ollama API and stores conversation history only in browser storage.
