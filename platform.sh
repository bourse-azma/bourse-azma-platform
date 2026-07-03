#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$SCRIPT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/compose.sh
source "$SCRIPT_DIR/scripts/lib/compose.sh"
# shellcheck source=scripts/lib/git.sh
source "$SCRIPT_DIR/scripts/lib/git.sh"
# shellcheck source=scripts/lib/remote-deploy.sh
source "$SCRIPT_DIR/scripts/lib/remote-deploy.sh"

SELECTED_SERVICES=()
NO_BUILD=0
LOG_TAIL=200
LOG_FOLLOW=0

parse_args() {
  COMMAND=""
  SELECTED_SERVICES=()
  NO_BUILD=0
  LOG_TAIL=200
  LOG_FOLLOW=0

  if [[ $# -eq 0 ]]; then
    COMMAND="menu"
    return 0
  fi

  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    start|stop|restart|status|logs|update|deploy|remote-deploy|menu)
      COMMAND="$1"
      shift
      ;;
    *)
      err "Unknown command: $1"
      echo
      usage
      exit 1
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--service)
        [[ $# -ge 2 ]] || { err "--service requires a value"; exit 1; }
        SELECTED_SERVICES+=("$2")
        shift 2
        ;;
      --no-build)
        NO_BUILD=1
        shift
        ;;
      --tail)
        [[ $# -ge 2 ]] || { err "--tail requires a value"; exit 1; }
        LOG_TAIL="$2"
        shift 2
        ;;
      -f|--follow)
        LOG_FOLLOW=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        echo
        usage
        exit 1
        ;;
    esac
  done
}

run_command() {
  case "$COMMAND" in
    start)
      platform_start
      ;;
    stop)
      platform_stop
      ;;
    restart)
      platform_restart
      ;;
    status)
      platform_status
      ;;
    logs)
      platform_logs
      ;;
    update)
      platform_update
      ;;
    deploy)
      platform_deploy
      ;;
    remote-deploy)
      platform_remote_deploy
      ;;
    menu)
      platform_menu
      ;;
    *)
      err "No command specified."
      usage
      return 1
      ;;
  esac
}

pause_after_success() {
  read -r -p "$(printf "${C_DIM}Press Enter to return to menu...${C_RESET} ")" _
}

handle_failure() {
  local action_name="$1"
  local answer normalized
  while true; do
    read -r -p "$(printf "${C_YELLOW}Action failed.${C_RESET} Retry [r], menu [m], exit [q]: ")" answer
    normalized="$(normalize_digits "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')")"
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

menu_start_services() {
  NO_BUILD=0
  SELECTED_SERVICES=()
  platform_start
}

menu_stop_services() {
  SELECTED_SERVICES=()
  platform_stop
}

menu_restart_all() {
  NO_BUILD=0
  SELECTED_SERVICES=()
  platform_restart
}

menu_show_logs() {
  local choice normalized selected_service

  LOG_FOLLOW=1
  LOG_TAIL=200
  SELECTED_SERVICES=()

  if ! docker_ready || ! compose_file_ready; then
    return 1
  fi

  local running
  running="$(count_running_services)"
  if [[ "$running" -eq 0 ]]; then
    warn "No running services. Start services first to view logs."
    return 0
  fi

  if ! print_services_menu "Select service to view logs:" 0; then
    return 1
  fi

  read -r -p "Choose service to view logs: " choice || return 1
  normalized="$(normalize_digits "$(normalize_service_selection "$choice")")"

  selected_service="$(build_single_selected_service "$normalized")"
  if [[ $? -ne 0 ]]; then
    err "Invalid selection. Choose one service number."
    return 1
  fi

  SELECTED_SERVICES=("$selected_service")
  info "Showing logs for $selected_service. Press Ctrl+C to return to menu."
  platform_logs
}

print_menu() {
  cat <<MENU

${C_BOLD}${C_CYAN}===== Bourse Azma Platform =====${C_RESET}
1) Start services
2) Stop services
3) Restart all services
4) Git update
5) Status
6) Logs
7) Remote deploy
8) Exit
MENU
}

platform_menu() {
  while true; do
    print_menu
    if ! read -r -p "Choose an option [1-8]: " choice; then
      echo
      info "Exiting."
      exit 0
    fi

    choice="$(normalize_digits "$choice")"

    case "$choice" in
      1) run_menu_action menu_start_services ;;
      2) run_menu_action menu_stop_services ;;
      3) run_menu_action menu_restart_all ;;
      4) run_menu_action platform_update ;;
      5) run_menu_action platform_status ;;
      6) run_menu_action menu_show_logs ;;
      7) run_menu_action platform_remote_deploy ;;
      8)
        info "Exiting."
        exit 0
        ;;
      *)
        warn "Invalid option. Please choose 1-8."
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  run_command
}

main "$@"
