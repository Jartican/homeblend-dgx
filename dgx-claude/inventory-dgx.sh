#!/usr/bin/env bash
set +e

echo '=== OS ==='
. /etc/os-release
echo "$PRETTY_NAME"

echo '=== POSTGRES BINARIES AND CLUSTERS ==='
command -v psql
psql --version
command -v pg_config
pg_config --version
command -v pg_lsclusters
pg_lsclusters

echo '=== POSTGRES PACKAGES ==='
dpkg-query -W -f='${Package} ${Version}\n' 'postgresql*' 'pgvector*' 2>/dev/null | sort

echo '=== RELEVANT SYSTEM SERVICES ==='
systemctl list-unit-files --type=service --no-pager | grep -Ei 'postgres|ollama|docker|tailscale'

echo '=== RELEVANT LISTENERS ==='
ss -ltn | grep -E ':(5432|11434|12000|4000)[[:space:]]'

echo '=== DOCKER CONTAINERS ==='
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'

echo '=== RELEVANT USER SERVICES ==='
systemctl --user list-unit-files --type=service --no-pager | grep -Ei 'litellm|exocortex|postgres|ollama|webui'

echo '=== PGVECTOR CONTROL FILES ==='
for directory in /usr/share/postgresql/*/extension; do
  [[ -d "$directory" ]] && ls "$directory/vector.control" 2>/dev/null
done

echo '=== EXOCORTEX-RELATED DIRECTORIES ==='
find "$HOME" -maxdepth 3 -type d \
  \( -iname '*exocortex*' -o -iname '*postgres*' -o -iname '*pgvector*' \) \
  -print 2>/dev/null | head -100

echo '=== TAILSCALE (NO KEYS) ==='
tailscale version | head -1
tailscale ip -4
tailscale status --self
