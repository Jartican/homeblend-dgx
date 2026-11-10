param(
    [ValidateSet("auto", "fast", "quality")]
    [string]$Route = "auto"
)

$ErrorActionPreference = "Stop"
$claude = Join-Path $env:APPDATA "npm\claude.cmd"
$ssh = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$localPort = 14011
$sshTarget = "sparkie"
$routerUrl = "http://127.0.0.1:$localPort"

if (-not (Test-Path -LiteralPath $claude)) { throw "Claude Code was not found at $claude" }
if (-not (Test-Path -LiteralPath $ssh)) { throw "Windows OpenSSH was not found at $ssh" }

function Test-Router {
    try {
        $health = Invoke-RestMethod -Uri "$routerUrl/health" -TimeoutSec 2
        return $health.status -eq "ok"
    } catch { return $false }
}

$tunnelProcess = $null
if (-not (Test-Router)) {
    $tunnelProcess = Start-Process -FilePath $ssh -WindowStyle Hidden -PassThru -ArgumentList @(
        "-N", "-L", "127.0.0.1:${localPort}:127.0.0.1:4011",
        "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3", $sshTarget
    )
    $ready = $false
    foreach ($attempt in 1..20) {
        Start-Sleep -Milliseconds 500
        if ($tunnelProcess.HasExited) { throw "The SSH tunnel exited early. Confirm that 'ssh sparkie' works." }
        if (Test-Router) { $ready = $true; break }
    }
    if (-not $ready) {
        Stop-Process -Id $tunnelProcess.Id -ErrorAction SilentlyContinue
        throw "The DGX smart router did not become reachable through the SSH tunnel."
    }
}

try {
    $routerKey = (& $ssh $sshTarget "sed -n 's/^EXOCORTEX_CLAUDE_ROUTER_KEY=//p' ~/.config/exocortex/gateway.env" | Select-Object -First 1).Trim()
    if (-not $routerKey) { throw "The router key could not be read from the DGX." }
    $model = switch ($Route) {
        "fast" { "exocortex-chat-fast" }
        "quality" { "exocortex-agent-quality" }
        default { "exocortex-smart" }
    }
    $env:ANTHROPIC_AUTH_TOKEN = $routerKey
    $env:ANTHROPIC_API_KEY = ""
    $env:ANTHROPIC_BASE_URL = $routerUrl
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "32768"
    Write-Host "Claude Code -> SSH tunnel -> DGX smart router ($Route)"
    Write-Host "Selected alias: $model"
    & $claude --model $model @args
    exit $LASTEXITCODE
} finally {
    if ($tunnelProcess -and -not $tunnelProcess.HasExited) {
        Stop-Process -Id $tunnelProcess.Id -ErrorAction SilentlyContinue
    }
}
