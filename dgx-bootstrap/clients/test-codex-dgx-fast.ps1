param(
    [string]$Prompt = "Reply with exactly CODEX_LOCAL_OK. Do not use tools."
)

$ErrorActionPreference = "Stop"
$ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$codexRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
$codexCli = Get-ChildItem -LiteralPath $codexRoot -Recurse -Filter codex.exe |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$clientDir = Split-Path -Parent $PSCommandPath
$instructionFile = Join-Path $clientDir "codex-dgx-fast-instructions.md"
$isolatedHome = Join-Path $clientDir "codex-dgx-fast-home"
$workspace = (Resolve-Path (Join-Path $clientDir "..\..")).Path

if (-not $codexCli) { throw "The Codex CLI runtime was not found under $codexRoot" }
New-Item -ItemType Directory -Path $isolatedHome -Force | Out-Null
$env:CODEX_HOME = $isolatedHome

$tunnel = Start-Process -FilePath $ssh -WindowStyle Hidden -PassThru -ArgumentList @(
    "-N", "-L", "127.0.0.1:14000:127.0.0.1:4000",
    "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "sparkie"
)

try {
    Start-Sleep -Seconds 2
    if ($tunnel.HasExited) { throw "SSH tunnel exited early; verify 'ssh sparkie'." }
    $env:EXOCORTEX_LITELLM_KEY = (& $ssh sparkie "sed -n 's/^LITELLM_KEY=//p' ~/.config/exocortex/stack.env" |
        Select-Object -First 1).Trim()
    if (-not $env:EXOCORTEX_LITELLM_KEY) { throw "LiteLLM key was not found on the DGX." }

    $options = @(
        "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
        "--skip-git-repo-check", "--sandbox", "read-only", "-C", $workspace,
        "-m", "exocortex-chat-fast",
        "-c", 'model_provider="exocortex"',
        "-c", "model_context_window=16384",
        "-c", ('model_instructions_file="' + $instructionFile.Replace('\', '\\') + '"'),
        "-c", "tools.web_search=false",
        "-c", "features.multi_agent=false",
        "-c", 'model_providers.exocortex.name="Exocortex DGX"',
        "-c", 'model_providers.exocortex.base_url="http://127.0.0.1:14000/v1"',
        "-c", 'model_providers.exocortex.env_key="EXOCORTEX_LITELLM_KEY"',
        "-c", 'model_providers.exocortex.wire_api="responses"',
        "-c", "model_providers.exocortex.request_max_retries=0",
        "-c", "model_providers.exocortex.stream_max_retries=0",
        $Prompt
    )
    & $codexCli @options
    exit $LASTEXITCODE
}
finally {
    if ($tunnel -and -not $tunnel.HasExited) {
        Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue
    }
}
