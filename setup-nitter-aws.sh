#!/usr/bin/env bash
# Automated Nitter deployment for Ubuntu on AWS
# Target domain: nitter.obsera.xyz

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

# Create nitter user
if ! id -u nitter >/dev/null 2>&1; then
  useradd -m -s /bin/bash nitter
fi

usermod -aG docker nitter

# Clone Nitter repository
if [[ ! -d /opt/nitter ]]; then
  git clone https://github.com/zedeus/nitter.git /opt/nitter
  chown -R nitter:nitter /opt/nitter
fi

cd /opt/nitter
if [[ ! -f docker-compose.yml ]]; then
  if [[ -f docker-compose.yml.example ]]; then
    sudo -u nitter cp docker-compose.yml.example docker-compose.yml
  else
    cat >/opt/nitter/docker-compose.yml <<'EOF'
version: "3.8"

services:
  nitter:
    image: ghcr.io/zedeus/nitter:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      - NITTER_CONF=/etc/nitter/nitter.conf
    volumes:
      - ./nitter.conf:/etc/nitter/nitter.conf:ro
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1000", "--loglevel", "warning"]
    volumes:
      - ./redis-data:/data
EOF
    chown nitter:nitter /opt/nitter/docker-compose.yml
  fi
fi

if [[ ! -f nitter.conf ]]; then
  if [[ -f nitter.example.conf ]]; then
    sudo -u nitter cp nitter.example.conf nitter.conf
  else
    echo "nitter.conf template not found. Please supply a configuration file." >&2
    exit 1
  fi
fi

sudo -u nitter mkdir -p redis-data

# Adjust nitter configuration
if [[ -f nitter.conf ]]; then
  sudo -u nitter sed -i "s/^hostname = .*/hostname = \"nitter.obsera.xyz\"/" nitter.conf
  sudo -u nitter sed -i "s/^title = .*/title = \"obsera nitter\"/" nitter.conf
  sudo -u nitter sed -i "s/^hmacKey = .*/hmacKey = \"$(openssl rand -hex 32)\"/" nitter.conf
fi

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
sudo -u nitter docker-compose pull
sudo -u nitter docker-compose up -d

echo "Deployment complete. Ensure DNS for nitter.obsera.xyz points to this server's IP."
