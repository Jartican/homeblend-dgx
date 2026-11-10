#!/usr/bin/env bash
set +e

echo '=== COMPOSE (SECRET LINES REDACTED) ==='
sed -E '/(PASSWORD|TOKEN|SECRET|AUTHKEY|API_KEY)/I s/([:=]).*/\1 REDACTED/' \
  "$HOME/dgx-spark-llm/docker-compose.yml"

echo '=== OPEN WEBUI ==='
docker inspect open-webui --format 'Image={{.Config.Image}}'
docker inspect open-webui --format 'Restart={{.HostConfig.RestartPolicy.Name}}'
docker inspect open-webui --format 'Network={{.HostConfig.NetworkMode}}'
docker inspect open-webui --format 'Ports={{json .HostConfig.PortBindings}}'
docker inspect open-webui --format 'Mounts={{json .Mounts}}'

echo '=== TAILSCALE SERVE ==='
tailscale serve status || true

echo '=== OLLAMA UNIT (SECRET VALUES REDACTED) ==='
systemctl cat ollama.service \
  | grep -E '^(\[|ExecStart|Environment|User|Group|Restart)' \
  | sed -E 's/(AUTH|TOKEN|KEY|SECRET|PASSWORD)=[^"[:space:]]+/\1=REDACTED/g'
