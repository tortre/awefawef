#!/usr/bin/env bash
# Automated Nitter deployment for Ubuntu on AWS
# Target domain: nitter.obsera.xyz
# Runs as root to avoid permission issues

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

apt-get update
apt-get install -y curl git unzip software-properties-common apt-transport-https ca-certificates gnupg

# Install Docker
if ! command -v docker &>/dev/null; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl enable docker
systemctl start docker

# Install docker-compose via binary for compatibility
if ! command -v docker-compose &>/dev/null; then
  COMPOSE_VERSION="$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K[^"]+')"
  curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

docker-compose version

# Create nitter user (optional, since we're running as root)
if ! id -u nitter >/dev/null 2>&1; then
  useradd -m -s /bin/bash nitter
fi

usermod -aG docker nitter

# Clone Nitter repository
if [[ ! -d /opt/nitter ]]; then
  git clone https://github.com/zedeus/nitter.git /opt/nitter
  chown -R 998:998 /opt/nitter  # Set ownership for container user
fi

cd /opt/nitter

# Create docker-compose.yml
if [[ ! -f docker-compose.yml ]]; then
  if [[ -f docker-compose.yml.example ]]; then
    cp docker-compose.yml.example docker-compose.yml
  else
    cat >docker-compose.yml <<'EOF'
version: "3.8"

services:
  nitter:
    image: zedeus/nitter:latest
    container_name: nitter
    restart: unless-stopped
    user: "998:998"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - NITTER_CONF=/src/nitter.conf
    volumes:
      - ./nitter.conf:/src/nitter.conf:ro
      - ./sessions.jsonl:/src/sessions.jsonl:ro
    depends_on:
      - redis
    healthcheck:
      test: ["CMD-SHELL", "wget -nv --tries=1 --spider http://127.0.0.1:8080/Jack/status/20 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 2

  redis:
    image: redis:7-alpine
    container_name: nitter-redis
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1000", "--loglevel", "warning"]
    volumes:
      - ./redis-data:/data

volumes:
  redis-data:
    driver: local
EOF
  fi
fi

# Create nitter.conf
if [[ ! -f nitter.conf ]]; then
  if [[ -f nitter.example.conf ]]; then
    cp nitter.example.conf nitter.conf
  else
    echo "nitter.conf template not found. Please supply a configuration file." >&2
    exit 1
  fi
fi

mkdir -p redis-data

# Adjust nitter configuration
if [[ -f nitter.conf ]]; then
  sed -i "s/^hostname = .*/hostname = \"nitter.obsera.xyz\"/" nitter.conf
  sed -i "s/^title = .*/title = \"obsera nitter\"/" nitter.conf
  sed -i "s/^hmacKey = .*/hmacKey = \"$(openssl rand -hex 32)\"/" nitter.conf
  # Add session file path for container
  sed -i '1isessionFile = "/src/sessions.jsonl"' nitter.conf
fi

# Create sessions file with proper ownership
cat >sessions.jsonl <<'EOF'
{"id":"account1","auth_token":"0636948293d8d90decf3aaaf1c4d98ca76a36b93","ct0":"0012b19eec580078e06034391872a07d6221501692487e088e8b15c7b5fb94699147167cfc28e8121db3553e52dc2531220797a6ceacf745e937a4e6c137a9d7f7e677f49a27e98e7276af3e8f0966b0","twid":"u=1851769418378022914","guest_id":"v1:176143861428020365","guest_id_ads":"v1:176143861428020365","guest_id_marketing":"v1:176143861428020365","auth_multi":"1939048798015094784:746eabd7d4577f766c773e718d3d0819c6ce55cc","at":"","kdt":"F9goSzrmktJESODNmmMRtxcCIMbfmF9WaokV9dZY"}
EOF
chown 998:998 sessions.jsonl

# Install Caddy
if ! command -v caddy &>/dev/null; then
  apt-get install -y debian-keyring debian-archive-keyring
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

# Configure Caddyfile
cat >/etc/caddy/Caddyfile <<'EOF'
nitter.obsera.xyz {
  encode zstd gzip
  reverse_proxy localhost:8080
  log {
    output file /var/log/caddy/nitter-access.log
  }
}
EOF

systemctl enable caddy
systemctl reload caddy

# Configure UFW
if command -v ufw &>/dev/null; then
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  yes | ufw enable
fi

# Start Nitter
docker-compose pull
docker-compose up -d

echo "Deployment complete. Nitter should be running at https://nitter.obsera.xyz"
echo "Check status with: docker-compose ps"
echo "View logs with: docker-compose logs -f"
echo "Check if running: curl -I http://localhost:8080"
