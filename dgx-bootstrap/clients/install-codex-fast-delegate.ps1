$ErrorActionPreference = "Stop"

$codexRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
$codexCli = Get-ChildItem -LiteralPath $codexRoot -Recurse -Filter codex.exe |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$pythonExe = (Get-Command python -ErrorAction Stop).Source
$server = Join-Path (Split-Path -Parent $PSCommandPath) "exocortex_fast_mcp.py"
$codingServer = Join-Path (Split-Path -Parent $PSCommandPath) "exocortex_coding_mcp.py"

if (-not $codexCli) { throw "The Codex CLI runtime was not found under $codexRoot" }
if (-not (Test-Path -LiteralPath $server)) { throw "Missing MCP bridge: $server" }
if (-not (Test-Path -LiteralPath $codingServer)) { throw "Missing coding MCP bridge: $codingServer" }

& $codexCli mcp remove exocortex-fast-delegate 2>$null
& $codexCli mcp add exocortex-fast-delegate -- $pythonExe $server
if ($LASTEXITCODE -ne 0) { throw "Codex MCP registration failed." }
& $codexCli mcp get exocortex-fast-delegate

& $codexCli mcp remove exocortex-coding-delegate 2>$null
& $codexCli mcp add exocortex-coding-delegate -- $pythonExe $codingServer
if ($LASTEXITCODE -ne 0) { throw "Codex coding MCP registration failed." }
& $codexCli mcp get exocortex-coding-delegate

Write-Host "Restart Codex or open a new task to discover delegate_fast."
