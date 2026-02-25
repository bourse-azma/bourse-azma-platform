#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"

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
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
fi

info() { echo "${C_BLUE}[INFO]${C_RESET} $*"; }
ok() { echo "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[WARN]${C_RESET} $*"; }
err() { echo "${C_RED}[ERROR]${C_RESET} $*"; }
title() { echo "${C_BOLD}${C_CYAN}$*${C_RESET}"; }

if [[ ! -f "$COMPOSE_FILE" ]]; then
  err "Compose file not found: $COMPOSE_FILE"
  exit 1
fi

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available."
    return 127
  fi
}

docker_ready() {
  if ! command -v docker >/dev/null 2>&1; then
    err "'docker' is not installed or not in PATH."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not reachable. Start Docker and try again."
    return 1
  fi
}

count_defined_services() {
  local count
  count="$(compose_cmd config --services 2>/dev/null | awk 'NF{c++} END{print c+0}')"
  echo "${count:-0}"
}

count_running_services() {
  local count
  count="$(compose_cmd ps --status running --services 2>/dev/null | awk 'NF{c++} END{print c+0}')"
  echo "${count:-0}"
}

run_compose_action() {
  if ! docker_ready; then
    return 1
  fi

  if compose_cmd "$@"; then
    ok "Action completed successfully."
    return 0
  fi

  err "Action failed: docker compose $*"
  return 1
}

pause_after_success() {
  read -r -p "$(printf "${C_DIM}Press Enter to return to menu...${C_RESET} ")" _
}

handle_failure() {
  local action_name="$1"
  local answer normalized
  while true; do
    read -r -p "$(printf "${C_YELLOW}Action failed.${C_RESET} Retry [r], menu [m], exit [q]: ")" answer
    normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
      r)
        "$action_name"
        local retry_status=$?
        if [[ $retry_status -eq 0 ]]; then
          pause_after_success
          return 0
        fi
        ;;
      m|"")
        return 0
        ;;
      q)
        echo
        info "Exiting."
        exit 0
        ;;
      *)
        warn "Invalid choice. Use r, m, or q."
        ;;
    esac
  done
}

run_menu_action() {
  local action_name="$1"
  "$action_name"
  local status=$?
  if [[ $status -ne 0 ]]; then
    handle_failure "$action_name"
    return 0
  fi
  pause_after_success
}

print_menu() {
  cat <<MENU

${C_BOLD}${C_CYAN}===== Platform Deploy Menu =====${C_RESET}
1) Start services
2) Stop services
3) See status
4) See logs
5) Exit
MENU
}

start_services() {
  local running total
  running="$(count_running_services)"
  total="$(count_defined_services)"

  if [[ "$total" -gt 0 && "$running" -eq "$total" ]]; then
    warn "All services are already running ($running/$total)."
    return 0
  fi

  if [[ "$running" -gt 0 ]]; then
    info "Some services are already running ($running/$total). Starting missing services..."
  else
    info "Starting services..."
  fi

  run_compose_action up --build -d
}

stop_services() {
  local running
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    warn "No running services to stop."
    return 0
  fi

  info "Stopping services..."
  run_compose_action down
}

show_status() {
  title "Service status:"
  run_compose_action ps
}

show_logs() {
  local running
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    warn "No running services. Start services first to view logs."
    return 0
  fi

  info "Showing logs (last 200 lines, follow mode). Press Ctrl+C to return to menu."
  run_compose_action logs --tail 200 -f
}

while true; do
  print_menu
  if ! read -r -p "Choose an option [1-5]: " choice; then
    echo
    info "Exiting."
    exit 0
  fi

  case "$choice" in
    1)
      run_menu_action start_services
      ;;
    2)
      run_menu_action stop_services
      ;;
    3)
      run_menu_action show_status
      ;;
    4)
      run_menu_action show_logs
      ;;
    5)
      info "Exiting."
      exit 0
      ;;
    *)
      warn "Invalid option. Please choose 1, 2, 3, 4, or 5."
      ;;
  esac
done
