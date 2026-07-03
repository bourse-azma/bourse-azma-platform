#!/usr/bin/env bash
#
# Remote deploy: provisions a fresh Ubuntu server (Docker + Arvan mirror +
# Let's Encrypt) once, then builds all images locally, ships them to the
# server with docker save/load, and starts the stack with the production
# compose file (compose/docker-compose.remote.yml).
#
# All steps are idempotent: re-running only rebuilds/reships images and
# restarts the stack. Server provisioning (mirror, docker install,
# postgres/redis pull, TLS certificate) is skipped automatically once done.

REMOTE_DOMAIN="${REMOTE_DOMAIN:-bourseazma.ir}"
REMOTE_APP_DIR="${REMOTE_APP_DIR:-~/bourse-azma-deploy}"
REMOTE_DOCKER_MARKER="\$HOME/.bourse-azma-docker-provisioned"
ARVAN_MIRROR_URL="https://docker.arvancloud.ir"

REMOTE_IMAGES=(
  "tsetmc-api|$WORKSPACE_DIR/tsetmc-api|Dockerfile"
  "codal-api|$WORKSPACE_DIR/codal-api|Dockerfile"
  "bourse-azma-api|$WORKSPACE_DIR|bourse-azma-api/Dockerfile"
  "bourse-azma-ui|$WORKSPACE_DIR/bourse-azma-ui|Dockerfile|NGINX_CONF=nginx.remote.conf"
)

remote_ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=60
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=6
)

rd_ensure_sshpass() {
  if command -v sshpass >/dev/null 2>&1; then
    return 0
  fi

  warn "'sshpass' is not installed; attempting to install it..."
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew install hudochenkov/sshpass/sshpass || brew install sshpass
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y sshpass
  fi

  if ! command -v sshpass >/dev/null 2>&1; then
    err "Could not install 'sshpass' automatically. Please install it and re-run."
    return 1
  fi
}

rd_ssh() {
  SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh "${remote_ssh_opts[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"
}

rd_scp() {
  SSHPASS="$REMOTE_PASSWORD" sshpass -e scp "${remote_ssh_opts[@]}" "$@"
}

rd_prompt_credentials() {
  if [[ -z "${REMOTE_HOST:-}" ]]; then
    read -r -p "Server IP: " REMOTE_HOST
  fi
  if [[ -z "${REMOTE_USER:-}" ]]; then
    read -r -p "SSH user: " REMOTE_USER
  fi
  if [[ -z "${REMOTE_PASSWORD:-}" ]]; then
    read -r -s -p "SSH password: " REMOTE_PASSWORD
    echo
  fi

  if [[ -z "$REMOTE_HOST" || -z "$REMOTE_USER" || -z "$REMOTE_PASSWORD" ]]; then
    err "Server IP, user and password are all required."
    return 1
  fi
}

rd_check_connectivity() {
  info "Checking SSH connectivity to $REMOTE_USER@$REMOTE_HOST..."
  if ! rd_ssh "echo connected" >/dev/null 2>&1; then
    err "Could not connect to $REMOTE_USER@$REMOTE_HOST. Check IP/user/password and SSH access."
    return 1
  fi
  ok "Connected to $REMOTE_HOST."
}

rd_install_cert_renewal_hook() {
  info "Registering certbot renewal hook to refresh certs and restart UI..."
  rd_ssh "sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy && \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'mkdir -p /opt/bourse-azma-certs' \
      'cp -L /etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem /opt/bourse-azma-certs/' \
      'cp -L /etc/letsencrypt/live/$REMOTE_DOMAIN/privkey.pem /opt/bourse-azma-certs/' \
      'chmod 644 /opt/bourse-azma-certs/*' \
      'cd $REMOTE_APP_DIR/bourse-azma-platform/compose && docker compose restart bourse-azma-ui' | \
    sudo tee /etc/letsencrypt/renewal-hooks/deploy/restart-bourse-ui.sh >/dev/null && \
    sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-bourse-ui.sh"
}

# Copy TLS certs to a path readable by nginx-unprivileged (uid 101) inside the container.
rd_sync_tls_certs() {
  info "Syncing TLS certificates to /opt/bourse-azma-certs..."
  rd_ssh "sudo mkdir -p /opt/bourse-azma-certs && \
    sudo cp -L /etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem /opt/bourse-azma-certs/ && \
    sudo cp -L /etc/letsencrypt/live/$REMOTE_DOMAIN/privkey.pem /opt/bourse-azma-certs/ && \
    sudo chmod 644 /opt/bourse-azma-certs/*" \
    || { err "Failed to sync TLS certificates."; return 1; }
  ok "TLS certificates synced."
}

# One-time: Arvan mirror, Docker + compose plugin, postgres/redis pull.
rd_provision_docker_base() {
  if rd_ssh "test -f $REMOTE_DOCKER_MARKER" >/dev/null 2>&1; then
    ok "Docker base already provisioned (mirror/docker/postgres/redis), skipping."
    return 0
  fi

  info "First-time Docker setup: this may take a few minutes..."

  info "Configuring ArvanCloud Docker registry mirror..."
  rd_ssh "sudo mkdir -p /etc/docker && \
    printf '{\n  \"registry-mirrors\": [\"$ARVAN_MIRROR_URL\"]\n}\n' | sudo tee /etc/docker/daemon.json >/dev/null" \
    || { err "Failed to configure Docker mirror."; return 1; }

  info "Installing Docker + docker compose plugin..."
  rd_ssh "command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sudo sh" \
    || { err "Docker installation failed."; return 1; }
  rd_ssh "sudo usermod -aG docker \$(whoami) || true"
  rd_ssh "sudo systemctl enable docker && sudo systemctl restart docker" \
    || { err "Failed to restart Docker after mirror configuration."; return 1; }

  info "Pulling postgres:14-alpine and redis:7-alpine (versions used by this platform)..."
  rd_ssh "sudo docker pull postgres:14-alpine && sudo docker pull redis:7-alpine" \
    || { err "Failed to pull base images."; return 1; }

  rd_ssh "touch $REMOTE_DOCKER_MARKER"
  ok "Docker base provisioning complete."
}

# One-time (or retry if missing): certbot + Let's Encrypt certificate.
rd_provision_tls() {
  info "Installing certbot (if needed)..."
  rd_ssh "command -v certbot >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y certbot)" \
    || { err "Failed to install certbot."; return 1; }

  if rd_ssh "test -f /etc/letsencrypt/live/$REMOTE_DOMAIN/fullchain.pem" >/dev/null 2>&1; then
    ok "TLS certificate already present for $REMOTE_DOMAIN, skipping certbot."
    rd_sync_tls_certs || return 1
    rd_install_cert_renewal_hook
    return 0
  fi

  info "Opening firewall ports 80/443 (if ufw is active)..."
  rd_ssh "sudo ufw allow 80/tcp >/dev/null 2>&1; sudo ufw allow 443/tcp >/dev/null 2>&1; true"

  info "Requesting Let's Encrypt certificate for $REMOTE_DOMAIN..."
  info "DNS A record for $REMOTE_DOMAIN must point to $REMOTE_HOST (port 80 must be free)."
  if rd_ssh "sudo certbot certonly --standalone --non-interactive --agree-tos -m admin@$REMOTE_DOMAIN -d $REMOTE_DOMAIN"; then
    ok "TLS certificate obtained for $REMOTE_DOMAIN."
    rd_sync_tls_certs || return 1
    rd_install_cert_renewal_hook
    return 0
  fi

  err "Could not obtain TLS certificate automatically."
  err "Make sure the DNS A record for $REMOTE_DOMAIN points to $REMOTE_HOST, then re-run remote-deploy."
  return 1
}

rd_provision_server() {
  rd_provision_docker_base || return 1
  rd_provision_tls || return 1
}

rd_remote_platform() {
  local remote_arch
  remote_arch="$(rd_ssh "uname -m" 2>/dev/null | tr -d '[:space:]')"
  case "$remote_arch" in
    aarch64|arm64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}

rd_build_images() {
  local platform os entry name context dockerfile
  cleanup_workspace_appledouble
  os="$(uname -s)"
  platform="$(rd_remote_platform)"

  info "Building images locally for platform $platform..."

  if [[ "$os" == "Darwin" ]]; then
    docker buildx inspect bourse-azma-remote >/dev/null 2>&1 || \
      docker buildx create --name bourse-azma-remote --use >/dev/null
    docker buildx use bourse-azma-remote >/dev/null
  fi

  for entry in "${REMOTE_IMAGES[@]}"; do
    IFS='|' read -r name context dockerfile build_arg <<< "$entry"
    info "Building $name..."
    if [[ "$os" == "Darwin" ]]; then
      if [[ -n "${build_arg:-}" ]]; then
        docker buildx build \
          --platform "$platform" \
          --build-arg "$build_arg" \
          -t "$name:latest" \
          -f "$context/$dockerfile" \
          --load \
          "$context" || { err "Build failed: $name"; return 1; }
      else
        docker buildx build \
          --platform "$platform" \
          -t "$name:latest" \
          -f "$context/$dockerfile" \
          --load \
          "$context" || { err "Build failed: $name"; return 1; }
      fi
    else
      if [[ -n "${build_arg:-}" ]]; then
        docker build \
          --build-arg "$build_arg" \
          -t "$name:latest" \
          -f "$context/$dockerfile" \
          "$context" || { err "Build failed: $name"; return 1; }
      else
        docker build \
          -t "$name:latest" \
          -f "$context/$dockerfile" \
          "$context" || { err "Build failed: $name"; return 1; }
      fi
    fi
    ok "$name built."
  done
}

rd_ship_images() {
  local entry name tmpfile
  rd_ssh "mkdir -p $REMOTE_APP_DIR/images" || return 1

  for entry in "${REMOTE_IMAGES[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    tmpfile="$(mktemp -t "${name}-XXXXXX").tar.gz"

    info "Saving $name image..."
    docker save "$name:latest" | gzip > "$tmpfile" || { err "docker save failed for $name"; return 1; }

    info "Copying $name to $REMOTE_HOST..."
    rd_scp "$tmpfile" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/images/$name.tar.gz" \
      || { err "scp failed for $name"; rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"

    info "Loading $name image on remote server..."
    rd_ssh "gunzip -c $REMOTE_APP_DIR/images/$name.tar.gz | sudo docker load && rm -f $REMOTE_APP_DIR/images/$name.tar.gz" \
      || { err "docker load failed for $name"; return 1; }
    ok "$name deployed to remote server."
  done
}

rd_pick_compose_profile() {
  echo "remote"
}

rd_sync_deploy_files() {
  local profile profile_env
  profile="$(rd_pick_compose_profile)"
  profile_env="$PLATFORM_ROOT/compose/profiles/${profile}.env"
  info "Using resource profile '$profile' for remote server."

  info "Syncing compose and nginx configuration to remote server..."
  rd_ssh "mkdir -p $REMOTE_APP_DIR/bourse-azma-platform/compose $REMOTE_APP_DIR/bourse-azma-ui" || return 1

  rd_scp "$PLATFORM_ROOT/compose/docker-compose.remote.yml" \
    "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-platform/compose/docker-compose.yml" \
    || { err "Failed to copy compose file."; return 1; }

  if [[ -f "$profile_env" ]]; then
    rd_scp "$profile_env" \
      "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-platform/compose/.env" \
      || { err "Failed to copy compose .env."; return 1; }
  fi

  if [[ -f "$WORKSPACE_DIR/bourse-azma-ui/.env" ]]; then
    rd_scp "$WORKSPACE_DIR/bourse-azma-ui/.env" \
      "$REMOTE_USER@$REMOTE_HOST:$REMOTE_APP_DIR/bourse-azma-ui/.env" \
      || { err "Failed to copy .env file."; return 1; }
  else
    warn "bourse-azma-ui/.env not found locally; creating an empty one on remote."
    rd_ssh "touch $REMOTE_APP_DIR/bourse-azma-ui/.env"
  fi

  ok "Configuration synced."
}

rd_start_remote_stack() {
  info "Starting stack on remote server..."
  rd_ssh "cd $REMOTE_APP_DIR/bourse-azma-platform/compose && sudo docker compose up -d" \
    || { err "Failed to start remote stack."; return 1; }
  ok "Remote stack is up."
}

platform_remote_deploy() {
  rd_ensure_sshpass || return 1
  rd_prompt_credentials || return 1
  rd_check_connectivity || return 1
  rd_provision_server || return 1
  rd_build_images || return 1
  rd_ship_images || return 1
  rd_sync_deploy_files || return 1
  rd_sync_tls_certs || return 1
  rd_start_remote_stack || return 1

  echo
  ok "Remote deploy complete!"
  info "Frontend: https://$REMOTE_DOMAIN (host port 443 -> container 8080)"
  info "Backend services (db, redis, tsetmc-api, codal-api, bourse-azma-api) are only reachable from within the server's Docker network."
}
