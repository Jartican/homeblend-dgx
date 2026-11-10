# Exocortex DGX Spark bootstrap

This bundle recreates the current Exocortex infrastructure on a DGX Spark while
keeping generated credentials out of source control.

The deployed HomeBlend system is portable infrastructure, not a copied model
process: versioned scripts/configuration are cloned from the private repository,
then the bootstrap downloads pinned containers and model weights onto the target
Spark. Runtime secrets and machine identity remain outside Git. Inference runs
on the DGX GPUs; Windows, macOS, Linux, phones, and glasses are clients.

## Fresh-machine entry point

For a newly provisioned DGX Spark, first enable Ubuntu LUKS full-disk encryption
in the OS installer. Then clone or copy this directory and run as the intended
non-root Exocortex user:

```bash
bash bootstrap-new-dgx.sh
```

This orchestrates privileged prerequisites, PostgreSQL/pgvector, both model
runtimes, LiteLLM, Claude Code, Open WebUI, SearXNG/MCP tools, the Exocortex
routing/logging gateway, schema semantic documentation, and final verification.
If Docker group membership requires a new login, the script stops with explicit
instructions; rerunning it after login preserves and resumes completed work.

Disk encryption and interactive tailnet enrollment are deliberate provisioning
boundaries. Supply `TAILSCALE_AUTH_KEY` for scripted enrollment, or authenticate
interactively afterward. Secrets belong only in protected runtime environment
files and must never be committed.

Agents and engineers continuing this work must read `CONTEXT.md` before making
changes and update it after every material infrastructure, security, or
operational change.

## Components

- Ollama with `qwen3.8:27b`
- vLLM with NVIDIA Qwen3-8B NVFP4 for low-latency chat and tool calls
- Claude Code routed through a localhost-only LiteLLM gateway
- PostgreSQL 16 with pgvector
- Persistent Postgres data and timestamped custom-format backups

Fresh installations create the canonical PostgreSQL database `exocortex` with
the application role `exocortex`. Raw conversational telemetry uses the
`exocortex_raw` schema. Existing populated PostgreSQL containers are preserved
and require a backup-first migration instead of an in-place destructive rename.
- Open WebUI
- Shared Streamable-HTTP MCP gateway with `search_web` and guarded `fetch_url`
- Private SearXNG search backend
- Tailscale onboarding and tailnet-only Open WebUI publishing
- User-service persistence for LiteLLM

LiteLLM exposes stable logical routes rather than coupling Exocortex to one
runtime:

| Route | Runtime | Model | Intended use |
|---|---|---|---|
| `exocortex-chat-fast` | vLLM | `nvidia/Qwen3-8B-NVFP4` | conversational turns, tool dispatch |
| `exocortex-agent-quality` | Ollama | `qwen3.8:27b` | heavier agent/reasoning work |

The current fast-route smoke test completed a short chat response in 0.87s and
a structured tool call in 0.64s after warmup. Treat these as a functional
baseline, not a full concurrency benchmark.

On a fresh encrypted installation, `bootstrap-new-dgx.sh` also deploys and
tests the `exocortex-home-blend` OpenAI-compatible route automatically. Set
`DEPLOY_HOME_BLEND_ROUTER=0` only when deliberately provisioning the underlying
fast and quality routes without the blended facade.

## Fresh DGX

Provision Ubuntu/DGX OS with encrypted storage, copy this directory to the new
DGX, then run as the intended non-root Exocortex user:

```bash
cd ~/dgx-bootstrap
chmod +x ./*.sh
./bootstrap-new-dgx.sh
```

The wrapper validates the bundle, runs the privileged and non-root stages,
configures tailnet-only Open WebUI publishing, and finishes with the complete
verifier. If Docker group membership requires a new session, it exits with code
2; log out and back in, then rerun the same command. If Tailscale needs an
interactive login, it exits with code 3; run `sudo tailscale up`, then rerun it.

For unattended Tailscale enrollment, pass a short-lived auth key only to the
wrapper process:

```bash
TAILSCALE_AUTH_KEY='tskey-auth-...' TAILSCALE_HOSTNAME='exocortex-dgx' \
  ./bootstrap-new-dgx.sh
```

`bootstrap-root.sh` installs or validates all host prerequisites:

- Ubuntu 24.04 ARM64 / DGX Spark architecture, memory, disk, and user checks
- CA certificates, curl, Git/Git LFS, jq, rsync, unzip, OpenSSL
- Python 3, venv/pip, compiler/build tools, libpq, and PostgreSQL 16 client
- Docker Engine, Buildx, Compose, NVIDIA Container Toolkit/runtime
- Non-root Docker access for the Exocortex user
- Ollama and its systemd service
- vLLM container, NVFP4 Qwen3-8B weights, tool parser, and prefix cache
- Tailscale and its systemd service
- UFW is installed, but existing firewall policy is preserved by default
- systemd user lingering for boot persistence

The non-root stage then downloads the model and container images, generates
protected credentials, creates Postgres/pgvector, installs Claude Code and
LiteLLM, starts the private MCP/search network, and starts Open WebUI with the
canonical fast-model and Exocortex MCP connections already declared. The first
Open WebUI account still becomes the administrator, but it does not need to
re-enter the model or tool-server URLs.

Known-working vLLM, pgvector, SearXNG, and Open WebUI images are pinned by digest
in `config/stack.example.env`. LiteLLM is pinned by version. Update those pins
deliberately and run `validate-bootstrap.sh` plus the live smoke tests before
promoting a newer dependency set.

The canonical fresh-machine wrapper enables the reviewed Exocortex UFW policy
by default. It allows OpenSSH and Tailscale traffic, permits Docker-to-Ollama
traffic, and denies direct access to the model, database, and WebUI host ports.
It writes a numbered-rule snapshot under `/var/backups/exocortex` first. To
manage the firewall separately, opt out explicitly:

```bash
ENABLE_EXOCORTEX_UFW=0 ./bootstrap-new-dgx.sh
```

When the lower-level `bootstrap-root.sh` is run directly, firewall changes remain
opt-in through `ENABLE_EXOCORTEX_UFW=1`.

For unattended Tailscale enrollment, pass a short-lived, reusable=false auth
key only to the root process; do not store it in `bootstrap.env`:

```bash
sudo env TAILSCALE_AUTH_KEY='tskey-auth-...' \
  TAILSCALE_HOSTNAME='exocortex-dgx' ./bootstrap-root.sh
```

Rotate/revoke that key after provisioning.

To inspect prerequisites without changing the machine:

```bash
sudo EXOCORTEX_USER="$USER" ./bootstrap-root.sh --check
```

## Configuration and secrets

The first non-root run creates or migrates:

```text
~/.config/exocortex/stack.env
```

It is mode `0600`. Back it up using a password manager or encrypted secrets
store. Never commit it. `config/stack.example.env` documents supported
settings. Stable model routes are in `config/models.yaml`; tool enablement and
safety limits are in `config/tools.yaml`; search-provider selection is in
`config/search.yaml`. Changing providers does not change the MCP URL or client
configuration.

## Production phone enrollment and Voice Core publication

Use this order on every new Spark. It keeps Voice Core loopback-only until the
signed client has an independently revocable credential:

1. Install the DGX OS with encrypted storage, clone this repository, and run
   `dgx-bootstrap/bootstrap-new-dgx.sh` as the intended non-root user.
2. Run `dgx-bootstrap/verify-dgx.sh`. Do not continue if its encryption,
   application-authentication, or container checks fail.
3. Read the exact MagicDNS HTTPS hostname from `tailscale serve status`. On the
   Mac used to sign the iPhone app, run
   `python3 omi-phone-app/configure-voice-core-host.py <device>.tail<id>.ts.net`,
   generate the Xcode project, and install the signed app on the phone.
4. On the DGX, run `dgx-bootstrap/enroll-phone-client.sh iphone-primary`. The
   raw token is displayed once; the DGX stores only its SHA-256 hash. Enter the
   token directly into the app's Voice Core credential field so iOS stores it
   in the device-only Keychain. Never place it in a file, shell history, chat,
   Git, screenshots, or app logs.
5. Confirm the signed app and Tailscale are active on the phone. Then run
   `sudo dgx-bootstrap/configure-tailnet-voice.sh` on the DGX. The script refuses
   to publish `/voice` unless the registry is valid, the compatibility bridge
   is off, HTTP routes are protected, and the content-free audit sink is ready.
6. Re-run `dgx-bootstrap/verify-dgx.sh` and complete physical phone tests over
   cellular as well as Wi-Fi before calling the deployment production.

`enroll-phone-client.sh` and `manage-voice-clients.py` are also the rotation and
revocation path for a lost or replaced phone. Each other client must receive a
different credential. Prototype clients without secure credential provisioning
must not be used to justify enabling the anonymous compatibility bridge in
production.

The browser phone smoke page can exercise authenticated HTTP and WebSocket
paths while the native app is being signed, but its credential exists only in
that tab. It is a test harness, not the production credential store.

## Shared tools

`setup-tools-mcp.sh` builds two isolated containers. SearXNG has no published
host port. The MCP gateway is published only at `127.0.0.1:8766/mcp` and is
registered with Claude Code under the user-scoped name `exocortex`.

The containers have no GPU, Docker socket, or host filesystem access. Their
root filesystems are read-only, Linux capabilities are dropped, privilege
escalation is disabled, and CPU/memory/PID limits are applied. `fetch_url`
rejects non-HTTP schemes, embedded credentials, nonstandard ports, and any DNS
answer that is not a globally routable address. Web content is always labeled
as untrusted external data.

Run the live search and private-network-block test with:

```bash
~/dgx-bootstrap/test-tools-mcp.sh
```

Do not expose port 8766 to LAN or tailnet clients directly. When a glasses or
mobile client is selected, publish it through an authenticated TLS frontend or
have its trusted backend call the MCP gateway locally.

On a fresh installation, Open WebUI starts on the private `exocortex-tools`
Docker network. Its supported environment configuration declares
`http://vllm-qwen3-8b:8000/v1` as the OpenAI-compatible model endpoint and
`http://exocortex-mcp-gateway:8000/mcp` as the enabled Streamable HTTP MCP
server. Neither endpoint is exposed publicly. Existing Open WebUI containers
are preserved; the setup script reports when their persistent database predates
the declarative settings.

Verified phone workflow: add Exocortex under Admin Settings > Integrations as an
MCP Streamable HTTP server, set its access to Public, restart/refresh Open
WebUI, select `exocortex-chat-fast`, and enable Exocortex from the four-square
Integrations control beside the message box. The complete Qwen 8B -> MCP ->
SearXNG search loop passed with good interactive response time.

Claude Code on the DGX is registered to the same user-scoped `exocortex` MCP
endpoint. A live `claude-qwen` test confirmed the 27B quality route invoked
`search_web` through SearXNG and returned the official NVIDIA DGX Spark page.
The observed complete turn took about 52 seconds; use Open WebUI plus the 8B
route for low-latency conversation and the 27B Claude Code route for heavier
agent work.

The optional non-persisting Claude smart router listens only on DGX loopback
port `4011`. It defaults bounded turns to 8B, caps that route to 4K output
tokens, sends large or explicitly complex turns to 27B, and falls back to 27B
after a fast-route HTTP failure. It does not write prompts or responses to
PostgreSQL. From Windows, copy `clients/claude-dgx.ps1` to the home directory
and run one of:

```powershell
.\claude-dgx.ps1                    # automatic route
.\claude-dgx.ps1 -Route fast        # force 8B
.\claude-dgx.ps1 -Route quality     # force 27B
```

The launcher uses a loopback-only SSH tunnel to `sparkie`; confirm that
`ssh sparkie` works first. Claude Code adds a substantial system/tool protocol,
so the fast route is slower and less reliable than direct Open WebUI chat.

### Codex fast delegation experiment

`delegate_fast` lets the primary OpenAI Codex model send bounded drafting,
classification, extraction, comparison, or summarization work to Qwen 8B while
remaining responsible for judgment and verification. Qwen receives only the
explicit task/context passed to the tool and has no filesystem, shell, web, MCP,
or write access. Inputs are capped at 32,000 characters, outputs at 1,024 tokens,
and responses are marked `must_verify=true` and `persisted=false`.

On Windows, after `ssh sparkie` works:

```powershell
powershell -ExecutionPolicy Bypass -File .\clients\install-codex-fast-delegate.ps1
```

Restart Codex or open a new task afterward. The DGX-side helper is installed by
the main bootstrap. Do not delegate secrets, raw location, security decisions,
destructive actions, or final verification. Delegating trivial work may not save
hosted usage because the primary Codex harness and review turn still run.

Fresh Postgres deployments bind to `127.0.0.1` by default. An existing
container is preserved exactly, including its current binding.

## Operations

```bash
claude-qwen
backup-exocortex-postgres
~/dgx-bootstrap/test-tools-mcp.sh
~/dgx-bootstrap/verify-dgx.sh
systemctl --user status litellm-qwen
journalctl --user -u exocortex-claude-router -f
journalctl --user -u litellm-qwen -f
```

Run the versioned synthetic coding-agent benchmark (Qwen 27B file-tool loop,
fixed tests in a network-disabled Docker sandbox):

```bash
~/dgx-bootstrap/run-coding-lab.sh                         # one-task smoke
~/dgx-bootstrap/run-coding-lab.sh --family parser_fix   # ten-task family
```

The main bootstrap installs this from the complete repository with
`setup-coding-lab.sh`. Only synthetic/public fixtures are authorized on the
current unencrypted DGX. Raw benchmark outputs stay under the lab's ignored
`runs/` directory.

Deploy and test the loopback-only vLLM Semantic Router research challenger:

```bash
~/dgx-bootstrap/setup-vllm-semantic-router.sh
~/dgx-bootstrap/test-vllm-semantic-router.sh
```

Train reproducible diagnostic KNN/SVM artifacts only after exporting a
three-profile matrix into `~/exocortex-offload-lab/artifacts/router-v0.6`:

```bash
~/dgx-bootstrap/train-vllm-semantic-router.sh
```

This is shadow infrastructure. It does not replace HomeBlend or add an Open
WebUI model. The learned artifacts include a frontier label and require a
separately authorized frontier API plus Qwen3-compatible runtime embedding
configuration before any live three-way experiment.

Database backups are written to `~/backups/postgres`. Copy them off the DGX;
local-only backups do not protect against disk or machine loss.

## Exocortex gateway trial

The canonical fresh-machine wrapper requires encrypted PostgreSQL storage and
deploys the raw-conversation logging gateway. This is deliberately fail-closed:
storage encryption is an OS-provisioning prerequisite, not something the
bootstrap attempts to retrofit onto a populated root disk.

Before retaining raw conversations, verify that PostgreSQL is backed by an
encrypted block device:

```bash
./check-postgres-encryption.sh
./deploy-exocortex-gateway.sh --check
```

When the preflight passes, deploy the localhost-only trial gateway:

```bash
./deploy-exocortex-gateway.sh
./test-exocortex-gateway.sh
```

If storage is not encrypted, deployment stops before applying the schema. A
synthetic-data-only experiment can be explicitly enabled with
`--allow-unencrypted-test`; never send real conversation or location data in
that mode. The trial listens on `127.0.0.1:4010`, safely creates the canonical
database and role if missing, applies `exocortex_raw`, and stores its client key
in protected `~/.config/exocortex/gateway.env`.

## Migration boundaries

- Tailscale identity/auth state and application data are never copied by this
  repository. A fresh machine enrolls as a new tailnet device.
- Inject any scoped model-provider credential at runtime from a protected
  secrets store; never add credentials to Compose or Git.
- PostgreSQL data migration requires an encrypted backup and an explicit,
  tested restore. Bootstrap creates infrastructure, not production data
  replicas.
