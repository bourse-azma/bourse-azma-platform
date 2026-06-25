#!/usr/bin/env bash

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

compose_file_ready() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    err "Compose file not found: $COMPOSE_FILE"
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

service_exists() {
  local name="$1"
  grep -Fxq "$name" <<< "$(list_defined_services)"
}

run_compose_action() {
  if ! docker_ready || ! compose_file_ready; then
    return 1
  fi

  if compose_cmd "$@"; then
    ok "Action completed successfully."
    return 0
  fi

  err "Action failed: docker compose $*"
  return 1
}

platform_start() {
  cleanup_workspace_appledouble

  local build_flag=(--build)
  [[ "${NO_BUILD:-0}" == "1" ]] && build_flag=()

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

  run_compose_action up "${build_flag[@]}" -d
}

platform_stop() {
  if ! compose_file_ready; then
    return 1
  fi

  local running
  running="$(count_running_services)"

  if [[ "$running" -eq 0 ]]; then
    warn "No running services to stop."
    return 0
  fi

  info "Stopping services..."
  run_compose_action down
}

platform_restart() {
  cleanup_workspace_appledouble

  local build_flag=(--build)
  [[ "${NO_BUILD:-0}" == "1" ]] && build_flag=()

  if ! docker_ready || ! compose_file_ready; then
    return 1
  fi

  if [[ "${#SELECTED_SERVICES[@]}" -eq 0 ]]; then
    info "Restarting all services..."
    run_compose_action up "${build_flag[@]}" -d
    return $?
  fi

  local service
  for service in "${SELECTED_SERVICES[@]}"; do
    if ! service_exists "$service"; then
      err "Unknown service: $service"
      return 1
    fi
  done

  info "Restarting: ${SELECTED_SERVICES[*]}"
  run_compose_action up "${build_flag[@]}" -d "${SELECTED_SERVICES[@]}"
}

platform_status() {
  title "Service status:"
  run_compose_action ps
}

platform_logs() {
  local tail_lines="${LOG_TAIL:-200}"
  local follow_args=()

  if [[ "${LOG_FOLLOW:-0}" == "1" ]]; then
    follow_args=(-f)
  fi

  if ! docker_ready || ! compose_file_ready; then
    return 1
  fi

  local running
  running="$(count_running_services)"
  if [[ "$running" -eq 0 ]]; then
    warn "No running services. Start services first to view logs."
    return 0
  fi

  if [[ "${#SELECTED_SERVICES[@]}" -eq 0 ]]; then
    err "Specify a service with --service NAME"
    return 1
  fi

  if [[ "${#SELECTED_SERVICES[@]}" -gt 1 ]]; then
    err "Logs support only one service at a time."
    return 1
  fi

  local service="${SELECTED_SERVICES[0]}"
  if ! service_exists "$service"; then
    err "Unknown service: $service"
    return 1
  fi

  info "Showing logs for $service (last $tail_lines lines)."
  compose_cmd logs --tail "$tail_lines" "${follow_args[@]}" "$service"
  local status=$?
  if [[ $status -eq 0 || $status -eq 130 ]]; then
    return 0
  fi

  err "Failed to read logs for $service"
  return 1
}

print_services_menu() {
  local title_text="$1"
  local include_all="${2:-1}"
  local services index=1

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
}

normalize_service_selection() {
  local input="$1"
  normalize_digits "$input"
}

build_selected_services() {
  local selection="$1"
  local services selected=()

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
  local services selected=()

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
