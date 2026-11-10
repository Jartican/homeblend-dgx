#!/usr/bin/env bash
set -Eeuo pipefail

CHECK_ONLY=0
[[ "${1:-}" == --check ]] && CHECK_ONLY=1

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0${CHECK_ONLY:+ --check}" >&2
  exit 1
fi

target_user="${EXOCORTEX_USER:-${SUDO_USER:-}}"
if [[ -z "$target_user" || "$target_user" == root ]]; then
  echo 'Set EXOCORTEX_USER to the non-root account that will run Exocortex.' >&2
  exit 1
fi
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
[[ -n "$target_home" && -d "$target_home" ]] || {
  echo "Cannot resolve a home directory for $target_user" >&2
  exit 1
}

. /etc/os-release
architecture="$(dpkg --print-architecture)"
[[ "$architecture" == arm64 ]] || {
  echo "Expected DGX Spark ARM64; found $architecture" >&2
  exit 1
}
[[ "$ID" == ubuntu && "${VERSION_ID%%.*}" == 24 ]] || {
  echo "Expected DGX OS / Ubuntu 24.04; found $PRETTY_NAME" >&2
  exit 1
}

memory_kib="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
free_kib="$(df -Pk "$target_home" | awk 'NR==2 {print $4}')"
(( memory_kib >= 100000000 )) || {
  echo 'At least 100 GB RAM is required for the documented 27B setup.' >&2
  exit 1
}
(( free_kib >= 50000000 )) || {
  echo 'At least 50 GB free disk space is required before model/image downloads.' >&2
  exit 1
}

if (( CHECK_ONLY )); then
  echo "OS: $PRETTY_NAME ($architecture)"
  echo "User: $target_user ($target_home)"
  echo "RAM: $((memory_kib / 1024 / 1024)) GiB"
  echo "Free disk: $((free_kib / 1024 / 1024)) GiB"
  for command in curl docker nvidia-ctk ollama tailscale ufw git jq openssl python3; do
    if command -v "$command" >/dev/null 2>&1; then
      echo "OK: $command -> $(command -v "$command")"
    else
      echo "MISSING: $command"
    fi
  done
  systemctl is-active docker ollama 2>/dev/null || true
  systemctl is-active tailscaled 2>/dev/null || \
    systemctl is-active snap.tailscale.tailscaled.service 2>/dev/null || true
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates curl openssl git git-lfs jq rsync unzip \
  build-essential pkg-config python3 python3-venv python3-pip \
  postgresql-client-16 libpq-dev cryptsetup ufw

if ! command -v docker >/dev/null; then
  if apt-cache show docker-ce >/dev/null 2>&1; then
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi

if ! command -v nvidia-ctk >/dev/null; then
  apt-get install -y nvidia-container-toolkit nv-docker-options
fi
nvidia-ctk runtime configure --runtime=docker
systemctl enable --now docker
systemctl restart docker
docker info >/dev/null

getent group docker >/dev/null || groupadd docker
usermod -aG docker "$target_user"

if ! command -v ollama >/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/exocortex.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled 2>/dev/null || \
  systemctl enable --now snap.tailscale.tailscaled.service 2>/dev/null

loginctl enable-linger "$target_user"

if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
  tailscale_args=(up --auth-key="$TAILSCALE_AUTH_KEY")
  [[ -n "${TAILSCALE_HOSTNAME:-}" ]] && tailscale_args+=(--hostname="$TAILSCALE_HOSTNAME")
  tailscale "${tailscale_args[@]}"
elif ! tailscale status >/dev/null 2>&1; then
  echo 'Tailscale needs authentication after this script: sudo tailscale up'
fi

if [[ "${ENABLE_EXOCORTEX_UFW:-0}" == 1 ]]; then
  install -d -m 0700 /var/backups/exocortex
  ufw status numbered >"/var/backups/exocortex/ufw-before-$(date -u +%Y%m%dT%H%M%SZ).txt" || true
  ufw allow OpenSSH
  ufw allow in on tailscale0
  ufw allow in on docker0 to any port 11434 proto tcp
  ufw deny 11434/tcp
  ufw deny 5432/tcp
  ufw deny 12000/tcp
  ufw --force enable
else
  echo 'Preserving existing firewall configuration (ENABLE_EXOCORTEX_UFW is not 1).'
fi

install -d -o "$target_user" -g "$target_user" -m 0700 \
  "$target_home/.config/exocortex" "$target_home/backups/postgres"

echo
echo 'Privileged prerequisites are ready.'
echo "IMPORTANT: $target_user must start a new login session before running bootstrap-dgx.sh"
echo 'This refreshes Docker group membership.'
