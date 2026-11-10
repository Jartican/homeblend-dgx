$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$ollama = Join-Path $projectRoot '.local\ollama\ollama.exe'
$env:OLLAMA_MODELS = Join-Path $env:LOCALAPPDATA 'Exocortex\ollama\models'

& $ollama list
Write-Host "`nLoaded models:"
& $ollama ps
