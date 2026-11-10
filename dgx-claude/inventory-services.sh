#!/usr/bin/env bash
set -Eeuo pipefail

echo '=== POSTGRES CONTAINER CONFIG (SECRETS REDACTED) ==='
docker inspect spark-postgres --format 'Image={{.Config.Image}}'
docker inspect spark-postgres --format 'Restart={{.HostConfig.RestartPolicy.Name}}'
docker inspect spark-postgres --format 'Network={{.HostConfig.NetworkMode}}'
docker inspect spark-postgres --format 'Ports={{json .HostConfig.PortBindings}}'
docker inspect spark-postgres --format 'Mounts={{json .Mounts}}'
docker inspect spark-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(POSTGRES_USER|POSTGRES_DB|PGDATA)=' || true

postgres_user="$(docker inspect spark-postgres --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
postgres_user="${postgres_user:-postgres}"

echo '=== DATABASES ==='
docker exec spark-postgres psql -U "$postgres_user" -d postgres -Atc \
  "select datname from pg_database where not datistemplate order by datname;"

echo '=== INSTALLED EXTENSIONS PER DATABASE ==='
while IFS= read -r database; do
  echo "[$database]"
  docker exec spark-postgres psql -U "$postgres_user" -d "$database" -Atc \
    "select extname || ' ' || extversion from pg_extension order by extname;"
done < <(docker exec spark-postgres psql -U "$postgres_user" -d postgres -Atc \
  "select datname from pg_database where not datistemplate order by datname;")

echo '=== POSTGRES DATA DIRECTORY ==='
du -sh "$HOME/postgres_data" 2>/dev/null || true
stat -c 'owner=%U group=%G mode=%a path=%n' "$HOME/postgres_data" 2>/dev/null || true

echo '=== COMPOSE AND SETUP FILES ==='
find "$HOME" -maxdepth 4 -type f \
  \( -iname 'compose*.yml' -o -iname 'compose*.yaml' -o -iname 'docker-compose*.yml' \
     -o -iname 'docker-compose*.yaml' -o -iname '*postgres*.sh' -o -iname '*pgvector*.sh' \) \
  -print 2>/dev/null | head -100

echo '=== OPEN WEBUI CONFIG (SECRETS OMITTED) ==='
docker inspect open-webui --format 'Image={{.Config.Image}}'
docker inspect open-webui --format 'Restart={{.HostConfig.RestartPolicy.Name}}'
docker inspect open-webui --format 'Network={{.HostConfig.NetworkMode}}'
docker inspect open-webui --format 'Ports={{json .HostConfig.PortBindings}}'
docker inspect open-webui --format 'Mounts={{json .Mounts}}'

echo '=== TAILSCALE SERVE ==='
tailscale serve status || true

echo '=== OLLAMA SERVICE OVERRIDES ==='
systemctl cat ollama.service | sed -E \
  's/(AUTH|TOKEN|KEY|SECRET|PASSWORD)=[^"[:space:]]+/\1=REDACTED/g'
