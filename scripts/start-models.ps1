$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$ollama = Join-Path $projectRoot '.local\ollama\ollama.exe'
$env:OLLAMA_MODELS = Join-Path $env:LOCALAPPDATA 'Exocortex\ollama\models'

if (!(Test-Path $ollama)) {
    throw "Ollama is not installed at $ollama. See README.md."
}

try {
    $version = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2
    Write-Host "Ollama is already running (version $($version.version))."
    exit 0
} catch {
    New-Item -ItemType Directory -Force $env:OLLAMA_MODELS | Out-Null
    Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden
}

for ($attempt = 1; $attempt -le 30; $attempt++) {
    Start-Sleep -Seconds 1
    try {
        $version = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 2
        Write-Host "Ollama started (version $($version.version))."
        exit 0
    } catch {}
}

throw 'Ollama did not become ready within 30 seconds.'
