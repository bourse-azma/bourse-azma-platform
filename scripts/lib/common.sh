#!/usr/bin/env bash

: "${PLATFORM_ROOT:=$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)}"
WORKSPACE_DIR="$(cd "$PLATFORM_ROOT/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$PLATFORM_ROOT/compose/docker-compose.yml}"

normalize_digits() {
  local input="$1"
  input="$(printf '%s' "$input" | tr '۰۱۲۳۴۵۶۷۸۹' '0123456789')"
  input="$(printf '%s' "$input" | tr '٠١٢٣٤٥٦٧٨٩' '0123456789')"
  printf '%s' "$input" | tr -d '[:space:]'
}

SERVICE_ORDER=(
  tsetmc-api
  bourse-azma-db
  redis
  bourse-azma-api
  codal-api
  bourse-azma-ui
)

REPOS=(
  tsetmc-api
  bourse-azma-api
  codal-api
  bourse-azma-ui
  bourse-azma-platform
)

if [[ -t 1 ]]; then
  C_RESET="$(printf '\033[0m')"
  C_BOLD="$(printf '\033[1m')"
  C_DIM="$(printf '\033[2m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
  C_CYAN="$(printf '\033[36m')"
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

info()  { echo "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()    { echo "${C_GREEN}[OK]${C_RESET}    $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*"; }
err()   { echo "${C_RED}[ERROR]${C_RESET} $*"; }
title() { echo "${C_BOLD}${C_CYAN}$*${C_RESET}"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  start              Start all services (docker compose up --build -d)
  stop               Stop all services (docker compose down)
  restart            Restart services (all or selected)
  status             Show service status
  logs               View service logs
  update             Git pull all workspace repositories
  deploy             Update repos and restart services
  menu               Interactive menu (default when no command is given)

Options:
  -s, --service NAME   Target service (repeatable; restart/logs)
  --no-build           Skip image rebuild on start/restart
  --tail N             Number of log lines to show (default: 200)
  -f, --follow         Follow log output
  -h, --help           Show this help

Examples:
  $(basename "$0") start
  $(basename "$0") restart --service bourse-azma-api
  $(basename "$0") logs --service tsetmc-api --follow
  $(basename "$0") update
  $(basename "$0") deploy

Workspace: $WORKSPACE_DIR
Compose:   $COMPOSE_FILE
EOF
}
