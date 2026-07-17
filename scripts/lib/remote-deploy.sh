#!/usr/bin/env bash
# Hardened, idempotent remote deployment for a fresh Ubuntu host.

REMOTE_DOMAIN="${REMOTE_DOMAIN:-bourseazma.ir}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-}"
REMOTE_PORT="${REMOTE_PORT:-}"
REMOTE_HEALTH_TIMEOUT="${REMOTE_HEALTH_TIMEOUT:-360}"
REMOTE_ADMIN_USERNAME="${REMOTE_ADMIN_USERNAME:-erfan}"
REMOTE_FORCE_BOOTSTRAP="${REMOTE_FORCE_BOOTSTRAP:-0}"
REMOTE_BOOTSTRAP_VERSION="2"
ARVAN_DOCKER_MIRROR="${ARVAN_DOCKER_MIRROR:-https://docker.arvancloud.ir}"
ARVAN_UBUNTU_MIRROR="${ARVAN_UBUNTU_MIRROR:-https://mirror.arvancloud.ir/ubuntu}"

REMOTE_IMAGES=(
  "tsetmc-api|$WORKSPACE_DIR/tsetmc-api|Dockerfile"
  "codal-api|$WORKSPACE_DIR/codal-api|Dockerfile"
  "bourse-azma-api|$WORKSPACE_DIR|bourse-azma-api/Dockerfile"
  "bourse-azma-ui|$WORKSPACE_DIR/bourse-azma-ui|Dockerfile|NGINX_CONF=nginx.remote.conf"
)

remote_ssh_opts=(
  -o StrictHostKeyChecking=accept-new
  -o LogLevel=ERROR
  -o PreferredAuthentications=password,keyboard-interactive
  -o PubkeyAuthentication=no
  -o ControlMaster=auto
  -o ControlPersist=600
  # Per-user socket path avoids "Permission denied" when a root-owned
  # ControlPath was left behind in /tmp from an earlier session.
  -o ControlPath="${XDG_RUNTIME_DIR:-/tmp}/bourse-azma-ssh-%u-%C"
  -o ConnectTimeout=30
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=6
)

rd_ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  warn "'sshpass' is required for password-based deployment; attempting installation."
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install hudochenkov/sshpass/sshpass || brew install sshpass
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y sshpass
  fi
  command -v sshpass >/dev/null 2>&1 || {
    err "Could not install sshpass. Install it or configure the deployment host manually."
    return 1
  }
}

rd_ssh() {
  SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh -p "$REMOTE_PORT" "${remote_ssh_opts[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"
}

rd_ssh_tty() {
  SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh -tt -p "$REMOTE_PORT" "${remote_ssh_opts[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"
}

rd_scp() {
  SSHPASS="$REMOTE_PASSWORD" sshpass -e scp -P "$REMOTE_PORT" "${remote_ssh_opts[@]}" "$@"
}

rd_prompt_credentials() {
  [[ -n "${REMOTE_HOST:-}" ]] || read -r -p "Server IP or hostname: " REMOTE_HOST
  [[ -n "${REMOTE_USER:-}" ]] || read -r -p "SSH user: " REMOTE_USER
  if [[ -z "${REMOTE_PORT:-}" ]]; then
    read -r -p "SSH port [22]: " REMOTE_PORT
    REMOTE_PORT="${REMOTE_PORT:-22}"
  fi
  if [[ -z "${REMOTE_PASSWORD:-}" ]]; then
    read -r -s -p "SSH password: " REMOTE_PASSWORD
    echo
  fi

  [[ "$REMOTE_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || { err "Invalid remote host."; return 1; }
  [[ "$REMOTE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { err "Invalid remote user."; return 1; }
  [[ "$REMOTE_PORT" =~ ^[0-9]+$ && "$REMOTE_PORT" -ge 1 && "$REMOTE_PORT" -le 65535 ]] || {
    err "Invalid SSH port (must be 1-65535)."
    return 1
  }
  # Root's home is /root, not /home/root.
  if [[ -z "${REMOTE_APP_DIR:-}" ]]; then
    if [[ "$REMOTE_USER" == "root" ]]; then
      REMOTE_APP_DIR="/root/bourse-azma-deploy"
    else
      REMOTE_APP_DIR="/home/$REMOTE_USER/bourse-azma-deploy"
    fi
  fi
  [[ "$REMOTE_APP_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { err "REMOTE_APP_DIR must be an absolute safe path."; return 1; }
  [[ "$REMOTE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { err "Invalid remote domain."; return 1; }
}

rd_check_connectivity() {
  info "Checking SSH connectivity to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT..."
  rd_ssh "true" >/dev/null 2>&1 || {
    err "Could not connect to $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT."
    return 1
  }
  ok "Connected to $REMOTE_HOST:$REMOTE_PORT."
}

rd_provision_os() {
  info "Updating and hardening the Ubuntu host..."
  # Install Docker before dist-upgrade: long upgrades can drop the SSH session
  # after needrestart, and the old script then reported success without Docker.
  # Pass the real SSH port and deploy user so UFW/sshd hardening cannot lock us out.
  if ! rd_ssh "REMOTE_SSH_PORT='$REMOTE_PORT' REMOTE_DEPLOY_USER='$REMOTE_USER' APP_DIR='$REMOTE_APP_DIR' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
command -v curl >/dev/null 2>&1 || { sudo apt-get update -o Acquire::ForceIPv4=true; sudo apt-get install -y curl ca-certificates; }

# Desktop/AppStream metadata is not needed on a server and is often the last
# part of a mirror sync, so do not let it make an otherwise healthy mirror fail.
sudo tee /etc/apt/apt.conf.d/99-bourse-azma-server-indexes >/dev/null <<'EOF'
Acquire::Retries "2";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::ForceIPv4 "true";
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
EOF

# Avoid interactive needrestart prompts on non-TTY SSH deploys.
sudo tee /etc/needrestart/conf.d/99-bourse-azma.conf >/dev/null <<'EOF' 2>/dev/null || true
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF

source_file=/etc/apt/sources.list.d/ubuntu.sources
if [ -f "$source_file" ]; then
  sudo cp --update=none "$source_file" "$source_file.bourse-azma-backup" 2>/dev/null || \
    sudo cp -n "$source_file" "$source_file.bourse-azma-backup" 2>/dev/null || true
else
  source_file=/etc/apt/sources.list
  sudo cp --update=none "$source_file" "$source_file.bourse-azma-backup" 2>/dev/null || \
    sudo cp -n "$source_file" "$source_file.bourse-azma-backup" 2>/dev/null || true
fi

mirror_ready=false
if sudo apt-get update -y; then
  mirror_ready=true
else
  for mirror in \
    https://mirror.arvancloud.ir/ubuntu \
    https://mirror.iranserver.com/ubuntu \
    https://ubuntu.pishgaman.net/ubuntu \
    https://mirror.abrha.net/ubuntu; do
    curl -4 -fsI --connect-timeout 8 "$mirror/dists/$codename/Release" >/dev/null 2>&1 || continue
    if [[ "$source_file" == *.sources ]]; then
      sudo sed -i -E "s#^URIs: .*#URIs: $mirror/#" "$source_file"
    else
      sudo sed -i -E "s#https?://[^ ]+/ubuntu/?#$mirror/#g" "$source_file"
    fi
    sudo rm -rf /var/lib/apt/lists/*
    if sudo apt-get update -y; then
      mirror_ready=true
      break
    fi
  done
fi
"$mirror_ready" || { echo 'No configured Iranian Ubuntu mirror completed apt update.' >&2; exit 1; }

# 1) Install Docker and host tooling FIRST (before dist-upgrade).
echo "[bootstrap] Installing Docker and host packages..."
sudo apt-get install -y ca-certificates curl openssl ufw fail2ban unattended-upgrades docker.io docker-compose-v2

# 2) Configure and start Docker; fail hard if the binary is missing.
sudo install -d -m 0755 /etc/docker
printf '%s\n' '{' '  "registry-mirrors": ["https://docker.arvancloud.ir"],' '  "live-restore": true,' '  "log-driver": "json-file",' '  "log-opts": {"max-size": "10m", "max-file": "3"}' '}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl enable docker
sudo systemctl restart docker
# Wait until the daemon answers (socket can lag a few seconds after restart).
for i in 1 2 3 4 5 6 7 8 9 10; do
  if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! command -v docker >/dev/null 2>&1; then
  echo "docker binary missing after apt install of docker.io" >&2
  dpkg -l 'docker*' >&2 || true
  exit 1
fi
if ! sudo docker info >/dev/null 2>&1; then
  echo "docker daemon is not running after install" >&2
  sudo systemctl status docker --no-pager >&2 || true
  exit 1
fi
if [[ "$(id -un)" != "root" ]]; then
  sudo usermod -aG docker "$(id -un)" || true
fi
echo "[bootstrap] Docker $(docker --version) is ready."

# 3) OS upgrades after Docker is confirmed (session loss is recoverable).
echo "[bootstrap] Running dist-upgrade..."
sudo apt-get dist-upgrade -y
# Re-check Docker after upgrade (package replacements must not leave us without it).
if ! command -v docker >/dev/null 2>&1 || ! sudo docker info >/dev/null 2>&1; then
  sudo apt-get install -y docker.io docker-compose-v2
  sudo systemctl enable --now docker
  sudo docker info >/dev/null 2>&1 || { echo "Docker unavailable after dist-upgrade" >&2; exit 1; }
fi

# 4) Firewall: open the actual SSH port used for this deploy (not always 22).
ssh_port="${REMOTE_SSH_PORT:-22}"
sudo ufw default deny incoming
sudo ufw default allow outgoing
# Always keep 22 as well when a custom port is used, in case console recovery needs it.
if [[ "$ssh_port" != "22" ]]; then
  sudo ufw limit 22/tcp comment 'SSH fallback' || true
fi
sudo ufw limit "${ssh_port}/tcp" comment 'SSH rate limited'
sudo ufw allow 80/tcp comment 'HTTP redirect and ACME'
sudo ufw allow 443/tcp comment 'Bourse Azma UI'
sudo ufw --force enable

sudo install -d -m 0755 /etc/fail2ban/jail.d
printf '%s\n' '[sshd]' 'enabled = true' 'bantime = 1h' 'findtime = 10m' 'maxretry = 5' | sudo tee /etc/fail2ban/jail.d/bourse-azma.conf >/dev/null
sudo systemctl enable --now fail2ban

# 5) SSH hardening without locking out a root password deploy.
sudo install -d -m 0755 /etc/ssh/sshd_config.d
if [[ "${REMOTE_DEPLOY_USER:-}" == "root" ]]; then
  # Deploy is root+password: keep root login enabled or recovery becomes impossible.
  printf '%s\n' 'PermitRootLogin yes' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no' | sudo tee /etc/ssh/sshd_config.d/60-bourse-azma-hardening.conf >/dev/null
else
  printf '%s\n' 'PermitRootLogin no' 'MaxAuthTries 4' 'LoginGraceTime 30' 'X11Forwarding no' | sudo tee /etc/ssh/sshd_config.d/60-bourse-azma-hardening.conf >/dev/null
fi
sudo sshd -t
sudo systemctl reload ssh || true

sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
if ! swapon --show | grep -q .; then
  sudo fallocate -l 1G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || printf '%s\n' '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# Ensure deploy directory exists (bootstrap marker + app files).
sudo install -d -m 0755 "$APP_DIR"

# Final gate: never report success without a working Docker CLI + daemon.
command -v docker >/dev/null 2>&1
sudo docker info >/dev/null 2>&1
echo "[bootstrap] Host bootstrap finished successfully."
REMOTE_SCRIPT
  then
    err "Ubuntu provisioning failed; no application containers were started."
    return 1
  fi

  # Local-side verification (catches silent remote partial runs).
  if ! rd_ssh "command -v docker >/dev/null && sudo docker info >/dev/null"; then
    err "Provisioning finished but Docker is not usable on the remote host."
    return 1
  fi
  ok "Host packages, Docker, firewall, fail2ban, updates, SSH policy and swap are ready."
}

# Recover when bootstrap was marked complete (or partially ran) without Docker.
rd_ensure_docker() {
  if rd_ssh "command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1"; then
    return 0
  fi
  warn "Docker is missing or not running on the remote host; installing/repairing..."
  rd_ssh "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; sudo apt-get update -y && sudo apt-get install -y docker.io docker-compose-v2 && sudo install -d -m 0755 /etc/docker && printf '%s\n' '{' '  \"registry-mirrors\": [\"https://docker.arvancloud.ir\"],' '  \"live-restore\": true,' '  \"log-driver\": \"json-file\",' '  \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}' '}' | sudo tee /etc/docker/daemon.json >/dev/null && sudo systemctl enable --now docker && sudo docker info >/dev/null" || {
    err "Could not install or start Docker on the remote host."
    return 1
  }
  ok "Docker is available on the remote host."
}

rd_bootstrap_needed() {
  [[ "$REMOTE_FORCE_BOOTSTRAP" == "1" ]] && return 0
  if rd_ssh "test \"\$(cat '$REMOTE_APP_DIR/.bootstrap-complete' 2>/dev/null)\" = '$REMOTE_BOOTSTRAP_VERSION'"; then
    return 1
  fi
  # Migrate hosts prepared by an older version of this deploy script without
  # paying the bootstrap cost again. Runtime certs under /opt are enough.
  if rd_ssh "command -v docker >/dev/null && sudo test -s '/opt/bourse-azma-certs/fullchain.pem' && sudo ufw status | grep -q '^Status: active'"; then
    rd_mark_bootstrap_complete
    return 1
  fi
  if rd_ssh "command -v docker >/dev/null && sudo test -s '/etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem' && sudo ufw status | grep -q '^Status: active'"; then
    rd_install_runtime_certs || true
    rd_mark_bootstrap_complete
    return 1
  fi
  return 0
}

rd_mark_bootstrap_complete() {
  rd_ssh "printf '%s' '$REMOTE_BOOTSTRAP_VERSION' > '$REMOTE_APP_DIR/.bootstrap-complete'"
}

rd_pull_base_images() {
  info "Pulling base images through the configured registry mirror..."
  rd_ensure_docker || return 1
  rd_ssh "bash -s" <<'REMOTE_SCRIPT' || {
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found on PATH" >&2
  exit 1
fi
sudo docker info >/dev/null
pull_and_tag() {
  image="$1"
  if sudo docker image inspect "$image" >/dev/null 2>&1; then
    echo "already present: $image"
    return 0
  fi
  for registry in docker.arvancloud.ir docker.abrha.net; do
    echo "pulling $registry/library/$image ..."
    if sudo docker pull "$registry/library/$image"; then
      sudo docker tag "$registry/library/$image" "$image"
      return 0
    fi
  done
  # Fallback: daemon registry-mirrors (configured during bootstrap).
  echo "pulling $image via daemon registry-mirrors ..."
  if sudo docker pull "$image"; then
    return 0
  fi
  return 1
}
pull_and_tag postgres:14-alpine
pull_and_tag redis:7-alpine
REMOTE_SCRIPT
    err "Could not pull PostgreSQL/Redis images. Check the Iranian registry mirror and that Docker is installed."
    return 1
  }
}

# Pull every build/runtime base once from an Iranian registry and tag it with
# the canonical name used by the Dockerfiles. Subsequent builds are local to
# the server and reuse Docker's layer cache.
rd_pull_build_images() {
  info "Preparing build images on the server (registry mirrors + local tags)..."
  rd_ensure_docker || return 1
  rd_ssh "bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
command -v docker >/dev/null 2>&1 || { echo "docker command not found" >&2; exit 1; }
sudo docker info >/dev/null
pull_and_tag() {
  canonical="$1"
  path="$2"
  if sudo docker image inspect "$canonical" >/dev/null 2>&1; then
    echo "already present: $canonical"
    return 0
  fi
  for registry in docker.arvancloud.ir docker.abrha.net; do
    echo "pulling $registry/$path ..."
    if sudo docker pull "$registry/$path"; then
      sudo docker tag "$registry/$path" "$canonical"
      return 0
    fi
  done
  # Last resort uses the daemon's configured registry-mirror chain.
  echo "pulling $canonical via daemon registry-mirrors ..."
  sudo docker pull "$canonical"
}
pull_and_tag alpine:3.21 library/alpine:3.21
pull_and_tag maven:3.9.9-eclipse-temurin-21-alpine library/maven:3.9.9-eclipse-temurin-21-alpine
pull_and_tag node:22-alpine library/node:22-alpine
pull_and_tag nginxinc/nginx-unprivileged:1.27-alpine-slim nginxinc/nginx-unprivileged:1.27-alpine-slim
REMOTE_SCRIPT
}

rd_sync_source() {
  info "Uploading the compact source bundle (no Docker images, git data, targets or node_modules)..."
  local archive
  archive="$(mktemp -t bourse-azma-source-XXXXXX).tar.gz"
  tar -C "$WORKSPACE_DIR" -czf "$archive" \
    --exclude='.git' --exclude='.idea' --exclude='target' --exclude='node_modules' \
    --exclude='dist' --exclude='*.tar.gz' \
    market.csv tsetmc-api codal-api fipiran-api bourse-azma-api bourse-azma-ui || {
      rm -f "$archive"
      return 1
    }
  info "Source bundle size: $(du -h "$archive" | awk '{print $1}')"
  rd_scp "$archive" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/source.tar.gz" || {
    rm -f "$archive"
    return 1
  }
  rm -f "$archive"
  rd_ssh "APP_DIR='$REMOTE_APP_DIR' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
rm -rf "$APP_DIR/source"
mkdir -p "$APP_DIR/source"
tar -xzf "$APP_DIR/source.tar.gz" -C "$APP_DIR/source"
rm -f "$APP_DIR/source.tar.gz"

config_dir="$APP_DIR/bourse-azma-platform/compose/config"
mkdir -p "$config_dir"
touch "$config_dir/tsetmc-api.env" "$config_dir/codal-api.env" "$config_dir/bourse-azma-api.env"
chmod 0600 "$config_dir"/*.env

# UI configuration is part of each release because Vite embeds it at build
# time. Publish the uploaded local .env atomically before building the image.
# If a release has no local .env, retain the last production configuration so
# an accidental omission does not erase a working server configuration.
if [ -s "$APP_DIR/source/bourse-azma-ui/.env" ]; then
  install -m 0600 "$APP_DIR/source/bourse-azma-ui/.env" "$config_dir/bourse-azma-ui.env.new"
  mv "$config_dir/bourse-azma-ui.env.new" "$config_dir/bourse-azma-ui.env"
elif [ -s "$config_dir/bourse-azma-ui.env" ]; then
  cp "$config_dir/bourse-azma-ui.env" "$APP_DIR/source/bourse-azma-ui/.env"
else
  echo "UI configuration is missing locally and on the server." >&2
  exit 1
fi

# Iranian Maven mirror (Central is often unreachable from IR hosts).
# myket.ir serves the standard Maven Central layout.
cat > "$APP_DIR/source/maven-settings.xml" <<'EOF'
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.2.0 https://maven.apache.org/xsd/settings-1.2.0.xsd">
  <mirrors>
    <mirror>
      <id>myket-central</id>
      <name>Myket Maven Central mirror</name>
      <url>https://maven.myket.ir</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
for service in tsetmc-api codal-api fipiran-api; do
  cp "$APP_DIR/source/maven-settings.xml" "$APP_DIR/source/$service/settings.xml"
done
# bourse-azma-api builds with context = workspace root (COPY bourse-azma-api/...)
cp "$APP_DIR/source/maven-settings.xml" "$APP_DIR/source/settings.xml"
cp "$APP_DIR/source/maven-settings.xml" "$APP_DIR/source/bourse-azma-api/settings.xml"

# The source Dockerfiles keep BuildKit cache mounts for fast local builds.
# Produce server-only variants that work with the classic Linux builder and
# force Maven to use the Iranian mirror settings file.
for service in tsetmc-api codal-api fipiran-api bourse-azma-api bourse-azma-ui; do
  awk '
    $1 == "RUN" && $2 ~ /^--mount=type=cache,target=\/root\/\.(m2|npm)$/ {
      if (getline command) {
        sub(/^[[:space:]]+/, "", command)
        print "RUN " command
      }
      next
    }
    { print }
  ' "$APP_DIR/source/$service/Dockerfile" > "$APP_DIR/source/$service/Dockerfile.server.tmp"

  if [[ "$service" == "bourse-azma-ui" ]]; then
    mv "$APP_DIR/source/$service/Dockerfile.server.tmp" "$APP_DIR/source/$service/Dockerfile.server"
    continue
  fi

  # Inject settings.xml into the build stage and point every mvn invocation at it.
  awk '
    BEGIN { injected=0 }
    $1 == "WORKDIR" && injected == 0 {
      print
      print "COPY settings.xml /root/.m2/settings.xml"
      injected=1
      next
    }
    {
      line = $0
      if (line ~ /^RUN / && line ~ /mvn /) {
        gsub(/mvn /, "mvn -s /root/.m2/settings.xml ", line)
      }
      print line
    }
  ' "$APP_DIR/source/$service/Dockerfile.server.tmp" > "$APP_DIR/source/$service/Dockerfile.server"
  rm -f "$APP_DIR/source/$service/Dockerfile.server.tmp"
done
REMOTE_SCRIPT
}

rd_build_images_remote() {
  info "Building Java application images on the server (Maven via myket.ir mirror)..."
  rd_ssh "SRC='$REMOTE_APP_DIR/source' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
for image in tsetmc-api codal-api bourse-azma-api; do
  if sudo docker image inspect "$image:latest" >/dev/null 2>&1; then
    sudo docker tag "$image:latest" "$image:rollback"
  fi
done
# bourse-azma-api builds with context=workspace root; settings.xml lives there.
test -s "$SRC/settings.xml"
test -s "$SRC/tsetmc-api/settings.xml"
test -s "$SRC/codal-api/settings.xml"
sudo docker build -t tsetmc-api:latest -f "$SRC/tsetmc-api/Dockerfile.server" "$SRC/tsetmc-api"
sudo docker build -t codal-api:latest -f "$SRC/codal-api/Dockerfile.server" "$SRC/codal-api"
sudo docker build -t bourse-azma-api:latest -f "$SRC/bourse-azma-api/Dockerfile.server" "$SRC"
REMOTE_SCRIPT
}

# npm registry is often blocked on Iranian servers. Build the UI image locally
# (where npm works) for linux/amd64 and load it on the remote host.
rd_build_and_ship_ui() {
  info "Building bourse-azma-ui locally (npm is typically unreachable from IR servers)..."
  local platform archive
  platform="$(rd_remote_platform)"
  cleanup_workspace_appledouble
  docker build --platform "$platform" \
    --build-arg NGINX_CONF=nginx.remote.conf \
    -t bourse-azma-ui:latest \
    -f "$WORKSPACE_DIR/bourse-azma-ui/Dockerfile" \
    "$WORKSPACE_DIR/bourse-azma-ui" || return 1

  info "Uploading bourse-azma-ui image to the server..."
  rd_ssh "mkdir -p '$REMOTE_APP_DIR/images'" || return 1
  archive="$(mktemp -t bourse-azma-ui-XXXXXX).tar.gz"
  docker save bourse-azma-ui:latest | gzip -1 > "$archive" || { rm -f "$archive"; return 1; }
  info "UI image archive size: $(du -h "$archive" | awk '{print $1}')"
  rd_scp "$archive" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/images/bourse-azma-ui.tar.gz" || {
    rm -f "$archive"
    return 1
  }
  rm -f "$archive"
  rd_ssh "if sudo docker image inspect 'bourse-azma-ui:latest' >/dev/null 2>&1; then sudo docker tag 'bourse-azma-ui:latest' 'bourse-azma-ui:rollback'; fi; gunzip -c '$REMOTE_APP_DIR/images/bourse-azma-ui.tar.gz' | sudo docker load; rm -f '$REMOTE_APP_DIR/images/bourse-azma-ui.tar.gz'" || return 1
  ok "bourse-azma-ui image loaded on the server."
}

rd_provision_secrets() {
  info "Creating persistent deployment secrets when missing..."
  rd_ssh "APP_DIR='$REMOTE_APP_DIR' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
secret_dir="$APP_DIR/bourse-azma-platform/compose/secrets"
install -d -m 0700 "$secret_dir"
create_secret() {
  file="$1"
  value="$2"
  if [ ! -s "$secret_dir/$file" ]; then
    umask 077
    printf '%s' "$value" > "$secret_dir/$file"
  fi
}
create_secret postgres_username "bourse_$(openssl rand -hex 8)"
create_secret postgres_password "$(openssl rand -base64 48 | tr -d '\n=/+' | head -c 56)"
create_secret bootstrap_admin_password "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9@#%_' | head -c 24)"
sudo chown 10001:10001 "$secret_dir"/*
sudo chmod 0400 "$secret_dir"/*
REMOTE_SCRIPT
  ok "Secrets are stable across redeploys and are not stored in compose or image metadata."
}

rd_install_cert_renewal_hooks() {
  rd_ssh "APP_DIR='$REMOTE_APP_DIR' DOMAIN='$REMOTE_DOMAIN' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/deploy
printf '%s\n' '#!/bin/sh' 'docker stop bourse-azma-ui >/dev/null 2>&1 || true' | sudo tee /etc/letsencrypt/renewal-hooks/pre/stop-bourse-ui.sh >/dev/null
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/pre/stop-bourse-ui.sh
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-bourse-ui.sh >/dev/null <<EOF
#!/bin/sh
set -eu
install -d -m 0755 /opt/bourse-azma-certs
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem /opt/bourse-azma-certs/fullchain.pem
cp -L /etc/letsencrypt/live/$DOMAIN/privkey.pem /opt/bourse-azma-certs/privkey.pem
chmod 0644 /opt/bourse-azma-certs/fullchain.pem
chown root:101 /opt/bourse-azma-certs/privkey.pem
chmod 0640 /opt/bourse-azma-certs/privkey.pem
cd $APP_DIR/bourse-azma-platform/compose
docker compose up -d bourse-azma-ui
EOF
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-bourse-ui.sh
REMOTE_SCRIPT
}

rd_install_runtime_certs() {
  # Install PEM pair into the path the UI container mounts.
  # Prefer Let's Encrypt live certs; otherwise keep/generate self-signed.
  rd_ssh "DOMAIN='$REMOTE_DOMAIN' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
sudo install -d -m 0755 /opt/bourse-azma-certs
if sudo test -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && sudo test -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem"; then
  sudo cp -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /opt/bourse-azma-certs/fullchain.pem
  sudo cp -L "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /opt/bourse-azma-certs/privkey.pem
else
  # Self-signed so nginx can start when ACME is unreachable (common from IR networks).
  if ! sudo test -s /opt/bourse-azma-certs/fullchain.pem || ! sudo test -s /opt/bourse-azma-certs/privkey.pem; then
    sudo openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout /opt/bourse-azma-certs/privkey.pem \
      -out /opt/bourse-azma-certs/fullchain.pem \
      -subj "/CN=$DOMAIN" \
      -addext "subjectAltName=DNS:$DOMAIN,DNS:www.$DOMAIN" 2>/dev/null \
      || sudo openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
           -keyout /opt/bourse-azma-certs/privkey.pem \
           -out /opt/bourse-azma-certs/fullchain.pem \
           -subj "/CN=$DOMAIN"
  fi
fi
sudo chmod 0644 /opt/bourse-azma-certs/fullchain.pem
sudo chown root:101 /opt/bourse-azma-certs/privkey.pem 2>/dev/null || sudo chown root:root /opt/bourse-azma-certs/privkey.pem
sudo chmod 0640 /opt/bourse-azma-certs/privkey.pem
REMOTE_SCRIPT
}

# Backwards-compatible name used by renewal hooks and older call sites.
rd_sync_tls_certs() {
  rd_install_runtime_certs
}

rd_provision_tls() {
  info "Provisioning TLS for $REMOTE_DOMAIN (Let's Encrypt with self-signed fallback)..."
  rd_ssh "sudo apt-get install -y certbot openssl" || return 1

  local le_ok=0
  if rd_ssh "sudo test -s /etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem"; then
    le_ok=1
    ok "Existing Let's Encrypt certificate found for $REMOTE_DOMAIN."
  else
    info "Requesting Let's Encrypt certificate (HTTP-01). This can be slow or blocked on some Iranian hosts..."
    # Retries + longer HTTP timeout help flaky ACME connectivity.
    if rd_ssh "DOMAIN='$REMOTE_DOMAIN' bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo docker stop bourse-azma-ui >/dev/null 2>&1 || true
# Free port 80 if something else holds it.
sudo fuser -k 80/tcp >/dev/null 2>&1 || true
ok=1
for attempt in 1 2 3; do
  echo "[tls] certbot attempt $attempt/3..."
  if sudo certbot certonly --standalone --preferred-challenges http \
      --non-interactive --agree-tos --register-unsafely-without-email \
      -d "$DOMAIN" \
      --http-01-port 80 \
      --config-dir /etc/letsencrypt \
      --work-dir /var/lib/letsencrypt \
      --logs-dir /var/log/letsencrypt; then
    ok=0
    break
  fi
  sleep $((attempt * 8))
done
exit "$ok"
REMOTE_SCRIPT
    then
      le_ok=1
      ok "Let's Encrypt certificate issued for $REMOTE_DOMAIN."
    else
      rd_ssh "sudo docker start bourse-azma-ui >/dev/null 2>&1 || true" || true
      warn "Let's Encrypt failed (ACME timeout/block or DNS/port 80). Falling back to a self-signed certificate so deploy can continue."
      warn "Browsers will show a warning until a real cert is issued. Re-run with REMOTE_FORCE_BOOTSTRAP=1 when ACME is reachable."
    fi
  fi

  rd_install_runtime_certs || return 1
  if (( le_ok == 1 )); then
    rd_install_cert_renewal_hooks || true
  fi
  rd_ssh "sudo test -s /opt/bourse-azma-certs/fullchain.pem && sudo test -s /opt/bourse-azma-certs/privkey.pem" || {
    err "Runtime TLS files are missing under /opt/bourse-azma-certs."
    return 1
  }
}

rd_check_existing_tls() {
  # Runtime certs are what the UI container mounts; LE live path is optional.
  if rd_ssh "sudo test -s '/opt/bourse-azma-certs/fullchain.pem' && sudo test -s '/opt/bourse-azma-certs/privkey.pem'"; then
    return 0
  fi
  if rd_ssh "sudo test -s '/etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem'"; then
    rd_install_runtime_certs
    return 0
  fi
  err "TLS certificate is missing. Run once with REMOTE_FORCE_BOOTSTRAP=1."
  return 1
}

rd_remote_platform() {
  case "$(rd_ssh "uname -m" 2>/dev/null | tr -d '[:space:]')" in
    aarch64|arm64) echo linux/arm64 ;;
    *) echo linux/amd64 ;;
  esac
}

rd_build_images() {
  local platform entry name context dockerfile build_arg
  cleanup_workspace_appledouble
  platform="$(rd_remote_platform)"
  info "Building the optimized project Dockerfiles locally for $platform..."
  for entry in "${REMOTE_IMAGES[@]}"; do
    IFS='|' read -r name context dockerfile build_arg <<< "$entry"
    info "Building $name..."
    local args=(-t "$name:latest" -f "$context/$dockerfile")
    [[ -z "${build_arg:-}" ]] || args+=(--build-arg "$build_arg")
    docker build --platform "$platform" "${args[@]}" "$context" || return 1
  done
}

rd_ship_images() {
  local entry name archive checksum previous_checksum
  rd_ssh "mkdir -p '$REMOTE_APP_DIR/images'" || return 1
  for entry in "${REMOTE_IMAGES[@]}"; do
    IFS='|' read -r name _ _ _ <<< "$entry"
    archive="$(mktemp -t "${name}-XXXXXX").tar.gz"
    docker save "$name:latest" | gzip -1 > "$archive" || { rm -f "$archive"; return 1; }
    checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
    previous_checksum="$(rd_ssh "cat '$REMOTE_APP_DIR/images/$name.sha256' 2>/dev/null || true")"
    if [[ "$checksum" == "$previous_checksum" ]]; then
      ok "$name is unchanged; image upload skipped."
      rm -f "$archive"
      continue
    fi
    info "Uploading optimized $name image..."
    rd_scp "$archive" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/images/$name.tar.gz" || { rm -f "$archive"; return 1; }
    rm -f "$archive"
    rd_ssh "if sudo docker image inspect '$name:latest' >/dev/null 2>&1; then sudo docker tag '$name:latest' '$name:rollback'; fi; gunzip -c '$REMOTE_APP_DIR/images/$name.tar.gz' | sudo docker load; printf '%s' '$checksum' > '$REMOTE_APP_DIR/images/$name.sha256'; rm -f '$REMOTE_APP_DIR/images/$name.tar.gz'" || return 1
  done
}

rd_sync_deploy_files() {
  local profile_env="$PLATFORM_ROOT/compose/profiles/remote.env"
  info "Synchronizing production compose configuration atomically..."
  rd_ssh "mkdir -p '$REMOTE_APP_DIR/bourse-azma-platform/compose' '$REMOTE_APP_DIR/bourse-azma-ui'"
  rd_scp "$PLATFORM_ROOT/compose/docker-compose.remote.yml" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-platform/compose/docker-compose.yml.new" || return 1
  rd_scp "$profile_env" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-platform/compose/.env.new" || return 1
  if [[ -f "$WORKSPACE_DIR/bourse-azma-ui/.env" ]]; then
    rd_scp "$WORKSPACE_DIR/bourse-azma-ui/.env" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-ui/.env.new" || return 1
  else
    : > /dev/null
    rd_ssh "touch '$REMOTE_APP_DIR/bourse-azma-ui/.env.new'"
  fi
  rd_ssh "mv '$REMOTE_APP_DIR/bourse-azma-platform/compose/docker-compose.yml.new' '$REMOTE_APP_DIR/bourse-azma-platform/compose/docker-compose.yml'; mv '$REMOTE_APP_DIR/bourse-azma-platform/compose/.env.new' '$REMOTE_APP_DIR/bourse-azma-platform/compose/.env'; mv '$REMOTE_APP_DIR/bourse-azma-ui/.env.new' '$REMOTE_APP_DIR/bourse-azma-ui/.env'; chmod 0600 '$REMOTE_APP_DIR/bourse-azma-platform/compose/.env' '$REMOTE_APP_DIR/bourse-azma-ui/.env'"
}

rd_rollback() {
  warn "Rolling application images back to the previous deployed versions..."
  rd_ssh "cd '$REMOTE_APP_DIR/bourse-azma-platform/compose'; for image in tsetmc-api codal-api bourse-azma-api bourse-azma-ui; do if sudo docker image inspect \"\$image:rollback\" >/dev/null 2>&1; then sudo docker tag \"\$image:rollback\" \"\$image:latest\"; fi; done; sudo docker compose up -d --force-recreate" || true
}

rd_verify_remote_stack() {
  local deadline=$((SECONDS + REMOTE_HEALTH_TIMEOUT)) status
  info "Waiting for every container to become healthy..."
  while (( SECONDS < deadline )); do
    status="$(rd_ssh "cd '$REMOTE_APP_DIR/bourse-azma-platform/compose' && sudo docker compose ps --format json" 2>/dev/null || true)"
    if [[ "$(printf '%s\n' "$status" | grep -c '"Health":"healthy"' || true)" -ge 6 ]]; then
      break
    fi
    if printf '%s' "$status" | grep -Eq '"State":"(exited|dead)"|"Health":"unhealthy"'; then
      break
    fi
    sleep 5
  done

  status="$(rd_ssh "cd '$REMOTE_APP_DIR/bourse-azma-platform/compose' && sudo docker compose ps --format json" 2>/dev/null || true)"
  if [[ "$(printf '%s\n' "$status" | grep -c '"Health":"healthy"' || true)" -lt 6 ]]; then
    err "The stack did not become healthy."
    rd_ssh "cd '$REMOTE_APP_DIR/bourse-azma-platform/compose' && sudo docker compose ps && sudo docker compose logs --tail=120" || true
    return 1
  fi

  rd_ssh "curl -kfsS --resolve '$REMOTE_DOMAIN:443:127.0.0.1' 'https://$REMOTE_DOMAIN/healthz' | grep -qx ok" || return 1
  rd_ssh "sudo ss -lntH | awk '{print \$4}' | grep -Eq ':(5432|6379|9000|9002|9003)$' && exit 1 || exit 0" || {
    err "A backend port is unexpectedly listening on the host."
    return 1
  }
  ok "All six containers are healthy; HTTPS works; backend ports are private."
}

rd_start_remote_stack() {
  info "Validating and starting the remote stack..."
  rd_ssh "cd '$REMOTE_APP_DIR/bourse-azma-platform/compose' && sudo docker compose config --quiet && sudo docker compose up -d --remove-orphans" || return 1
  rd_verify_remote_stack
}

rd_show_admin_credentials() {
  local admin_password
  admin_password="$(rd_ssh "sudo cat '$REMOTE_APP_DIR/bourse-azma-platform/compose/secrets/bootstrap_admin_password'" 2>/dev/null)" || {
    warn "Deploy succeeded, but the admin password could not be read from the server."
    return 0
  }

  echo
  title "Admin credentials"
  info "Username: $REMOTE_ADMIN_USERNAME"
  info "Password: $admin_password"
}

rd_wait_for_service_health() {
  local service="$1"
  local deadline=$((SECONDS + REMOTE_HEALTH_TIMEOUT)) health
  while (( SECONDS < deadline )); do
    health="$(rd_ssh "sudo docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' '$service' 2>/dev/null || true")"
    [[ "$health" == "healthy" || "$health" == "running" ]] && return 0
    [[ "$health" == "unhealthy" || "$health" == "exited" || "$health" == "dead" ]] && break
    sleep 3
  done
  err "$service did not become healthy."
  rd_ssh "sudo docker logs --tail=100 '$service'" || true
  return 1
}

rd_edit_remote_config() {
  local config_name="$1"
  local service="$2"
  local config_file="$REMOTE_APP_DIR/bourse-azma-platform/compose/config/$config_name.env"
  local compose_dir="$REMOTE_APP_DIR/bourse-azma-platform/compose"
  local before after

  before="$(rd_ssh "sudo sha256sum '$config_file' 2>/dev/null | awk '{print \$1}' || true")"
  info "Opening $config_name production configuration on $REMOTE_HOST..."
  info "Save and exit the editor to apply it; exit without changes to cancel."
  rd_ssh_tty "mkdir -p '$compose_dir/config'; touch '$config_file'; chmod 0600 '$config_file'; ${EDITOR:-nano} '$config_file'" || return 1
  after="$(rd_ssh "sudo sha256sum '$config_file' 2>/dev/null | awk '{print \$1}' || true")"

  if [[ -n "$before" && "$before" == "$after" ]]; then
    warn "Configuration was not changed; no container was restarted."
    return 0
  fi

  if [[ "$config_name" == "bourse-azma-ui" ]]; then
    info "UI configuration changed; rebuilding only the UI image on the server..."
    rd_ssh "cp '$config_file' '$REMOTE_APP_DIR/source/bourse-azma-ui/.env'; sudo docker build --build-arg NGINX_CONF=nginx.remote.conf -t bourse-azma-ui:latest -f '$REMOTE_APP_DIR/source/bourse-azma-ui/Dockerfile.server' '$REMOTE_APP_DIR/source/bourse-azma-ui'" || return 1
  fi

  info "Recreating $service so it reads the updated configuration..."
  rd_ssh "cd '$compose_dir' && sudo docker compose up -d --no-deps --force-recreate '$service'" || return 1
  rd_wait_for_service_health "$service" || return 1
  ok "$config_name configuration applied; $service is healthy."
}

platform_remote_config() {
  local choice config_name service
  rd_ensure_sshpass || return 1
  rd_prompt_credentials || return 1
  rd_check_connectivity || return 1
  rd_ssh "test -f '$REMOTE_APP_DIR/.bootstrap-complete'" || {
    err "The server has not been deployed yet. Run Deploy / Release first."
    return 1
  }

  cat <<MENU

${C_BOLD}${C_CYAN}===== Edit Remote Configuration =====${C_RESET}
1) Bourse Azma UI
2) Bourse Azma API
3) Codal API
4) TSETMC API
5) Back
MENU
  read -r -p "Choose a configuration [1-5]: " choice || return 1
  choice="$(normalize_digits "$choice")"
  case "$choice" in
    1) config_name="bourse-azma-ui"; service="bourse-azma-ui" ;;
    2) config_name="bourse-azma-api"; service="bourse-azma-api" ;;
    3) config_name="codal-api"; service="codal-api" ;;
    4) config_name="tsetmc-api"; service="tsetmc-api" ;;
    5|"") return 0 ;;
    *) err "Invalid selection. Choose 1-5."; return 1 ;;
  esac
  rd_edit_remote_config "$config_name" "$service"
}

platform_remote_deploy() {
  rd_ensure_sshpass || return 1
  rd_prompt_credentials || return 1
  rd_check_connectivity || return 1
  rd_ssh "mkdir -p '$REMOTE_APP_DIR'" || return 1
  if rd_bootstrap_needed; then
    info "First deployment detected; running one-time server bootstrap."
    rd_provision_os || return 1
    rd_pull_base_images || return 1
    rd_provision_secrets || return 1
    rd_provision_tls || return 1
    rd_mark_bootstrap_complete || return 1
  else
    ok "Server bootstrap already completed; OS upgrades and security provisioning skipped."
    # Still repair Docker if a previous partial bootstrap left it missing.
    rd_ensure_docker || return 1
    rd_check_existing_tls || return 1
  fi
  # Prefer local image builds + ship. Iranian VPS hosts often cannot reach
  # Maven Central, npmjs, or Alpine CDN, so on-server docker build fails.
  # REMOTE_BUILD_MODE=remote forces the older server-side path (myket Maven + local UI).
  local build_mode="${REMOTE_BUILD_MODE:-local}"
  if [[ "$build_mode" == "remote" ]]; then
    rd_pull_build_images || return 1
    rd_sync_source || return 1
    rd_build_images_remote || return 1
    rd_build_and_ship_ui || return 1
  else
    info "Build mode: local (images are built here and uploaded to the server)."
    rd_sync_source || return 1
    rd_build_images || return 1
    rd_ship_images || return 1
  fi
  rd_sync_deploy_files || return 1
  if ! rd_start_remote_stack; then
    rd_rollback
    return 1
  fi

  echo
  ok "Remote deploy and verification complete."
  info "UI: https://$REMOTE_DOMAIN (host ports: SSH $REMOTE_PORT, 80, 443)."
  info "Database, Redis and API containers have no host port bindings."
  rd_show_admin_credentials
}
