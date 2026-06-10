#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"
SERVICE_ORDER=(
  tsetmc-api
  boors-azma-db
  boors-azma-api
  codal-api
  fipiran-api
  boors-azma-ui
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

list_defined_services() {
  local compose_services ordered=() service known

  compose_services="$(compose_cmd config --services 2>/dev/null)"

  for service in "${SERVICE_ORDER[@]}"; do
    if grep -Fxq "$service" <<< "$compose_services"; then
      ordered+=("$service")
    fi
  done

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue

    local is_known=0
    for known in "${SERVICE_ORDER[@]}"; do
      if [[ "$service" == "$known" ]]; then
        is_known=1
        break
      fi
    done

    if [[ "$is_known" -eq 0 ]]; then
      ordered+=("$service")
    fi
  done <<< "$compose_services"

  printf '%s\n' "${ordered[@]}"
}

print_services_menu() {
  local title_text="$1"
  local include_all="${2:-1}"
  local services service index=1

  services="$(list_defined_services)"
  if [[ -z "$services" ]]; then
    warn "No services defined in compose file."
    return 1
  fi

  echo
  title "$title_text"
  if [[ "$include_all" == "1" ]]; then
    echo "0) All services"
  fi
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    printf '%s) %s\n' "$index" "$service"
    index=$((index + 1))
  done <<< "$services"
  echo
  if [[ "$include_all" == "1" ]]; then
    echo "Enter numbers like 0, 1, 1,3 or 1,2,3"
  else
    echo "Enter one service number like 1 or 2"
  fi
}

normalize_service_selection() {
  local input="$1"
  printf '%s' "$input" | tr -d '[:space:]'
}

build_selected_services() {
  local selection="$1"
  local services service selected=()

  services="$(list_defined_services)"
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    selected+=("$service")
  done <<< "$services"

  if [[ "$selection" == "0" ]]; then
    printf '%s\n' "${selected[@]}"
    return 0
  fi

  local IFS=','
  read -r -a parts <<< "$selection"

  local part
  for part in "${parts[@]}"; do
    if [[ ! "$part" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    if [[ "$part" -lt 1 || "$part" -gt "${#selected[@]}" ]]; then
      return 1
    fi
    printf '%s\n' "${selected[$((part - 1))]}"
  done
}

build_single_selected_service() {
  local selection="$1"
  local services service selected=()

  services="$(list_defined_services)"
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    selected+=("$service")
  done <<< "$services"

  if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "$selection" -lt 1 || "$selection" -gt "${#selected[@]}" ]]; then
    return 1
  fi

  printf '%s\n' "${selected[$((selection - 1))]}"
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
3) Restart services
4) See status
5) See logs
6) Exit
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

restart_services() {
  local choice normalized selected_services=()

  if ! docker_ready; then
    return 1
  fi

  if ! print_services_menu "Select services to restart:"; then
    return 1
  fi

  read -r -p "Choose services to restart [0]: " choice || return 1
  normalized="$(normalize_service_selection "${choice:-0}")"
  [[ -n "$normalized" ]] || normalized="0"

  local selected_output
  selected_output="$(build_selected_services "$normalized")"
  if [[ $? -ne 0 ]]; then
    err "Invalid selection. Use 0 for all services or a comma-separated list like 1,3."
    return 1
  fi

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    selected_services+=("$service")
  done <<< "$selected_output"

  if [[ "${#selected_services[@]}" -eq 0 ]]; then
    err "No valid services selected."
    return 1
  fi

  if [[ "$normalized" == "0" ]]; then
    info "Restarting all services..."
  else
    info "Restarting selected services: ${selected_services[*]}"
  fi

  run_compose_action up --build -d "${selected_services[@]}"
}

show_status() {
  title "Service status:"
  run_compose_action ps
}

show_logs() {
  local running choice normalized selected_service
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    warn "No running services. Start services first to view logs."
    return 0
  fi

  if ! docker_ready; then
    return 1
  fi

  if ! print_services_menu "Select service to view logs:" 0; then
    return 1
  fi

  read -r -p "Choose service to view logs: " choice || return 1
  normalized="$(normalize_service_selection "$choice")"

  selected_service="$(build_single_selected_service "$normalized")"
  if [[ $? -ne 0 ]]; then
    err "Invalid selection. Choose one service number."
    return 1
  fi

  info "Showing logs for $selected_service (last 200 lines, follow mode). Press Ctrl+C to return to menu."

  compose_cmd logs --tail 200 -f "$selected_service"
  local status=$?
  if [[ $status -eq 0 || $status -eq 130 ]]; then
    return 0
  fi

  err "Action failed: docker compose logs --tail 200 -f $selected_service"
  return 1
}

while true; do
  print_menu
  if ! read -r -p "Choose an option [1-6]: " choice; then
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
      run_menu_action restart_services
      ;;
    4)
      run_menu_action show_status
      ;;
    5)
      run_menu_action show_logs
      ;;
    6)
      info "Exiting."
      exit 0
      ;;
    *)
      warn "Invalid option. Please choose 1, 2, 3, 4, 5, or 6."
      ;;
  esac
done
