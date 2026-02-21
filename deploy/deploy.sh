#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: compose file not found: $COMPOSE_FILE"
  exit 1
fi

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    echo "Error: neither 'docker compose' nor 'docker-compose' is available."
    return 127
  fi
}

docker_ready() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: 'docker' is not installed or not in PATH."
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon is not reachable. Start Docker and try again."
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
    return 0
  fi

  echo "Action failed: docker compose $*"
  return 1
}

print_menu() {
  cat <<'MENU'

===== Platform Deploy Menu =====
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
    echo "All services are already running ($running/$total)."
    return 0
  fi

  if [[ "$running" -gt 0 ]]; then
    echo "Some services are already running ($running/$total). Starting missing services..."
  else
    echo "Starting services..."
  fi

  run_compose_action up --build -d
}

stop_services() {
  local running
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    echo "No running services to stop."
    return 0
  fi

  echo "Stopping services..."
  run_compose_action down
}

show_status() {
  echo "Service status:"
  run_compose_action ps
}

show_logs() {
  local running
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    echo "No running services. Start services first to view logs."
    return 0
  fi

  echo "Showing logs (last 200 lines, follow mode). Press Ctrl+C to return to menu."
  run_compose_action logs --tail 200 -f
}

while true; do
  print_menu
  if ! read -r -p "Choose an option [1-5]: " choice; then
    echo
    echo "Exiting."
    exit 0
  fi

  case "$choice" in
    1)
      start_services
      ;;
    2)
      stop_services
      ;;
    3)
      show_status
      ;;
    4)
      show_logs
      ;;
    5)
      echo "Exiting."
      exit 0
      ;;
    *)
      echo "Invalid option. Please choose 1, 2, 3, 4, or 5."
      ;;
  esac
done
