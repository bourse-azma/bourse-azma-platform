#!/usr/bin/env bash

platform_update() {
  local success=0 skipped=0 failed=0
  local -a failed_repos=()

  echo
  title "===== Git update ====="
  info "Workspace: $WORKSPACE_DIR"
  echo

  local repo repo_path branch
  for repo in "${REPOS[@]}"; do
    repo_path="$WORKSPACE_DIR/$repo"

    if [[ ! -d "$repo_path" ]]; then
      warn "$repo — directory not found, skipping."
      skipped=$((skipped + 1))
      continue
    fi

    if [[ ! -d "$repo_path/.git" ]]; then
      warn "$repo — not a git repository, skipping."
      skipped=$((skipped + 1))
      continue
    fi

    echo "${C_BOLD}→ $repo${C_RESET}"

    branch="$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    info "Branch: $branch"

    if git -C "$repo_path" pull --ff-only 2>&1 | sed "s/^/  ${C_DIM}/;s/$/${C_RESET}/"; then
      ok "$repo updated."
      success=$((success + 1))
    else
      err "$repo pull failed."
      failed=$((failed + 1))
      failed_repos+=("$repo")
    fi

    echo
  done

  title "===== Update summary ====="
  echo "${C_GREEN}Updated :${C_RESET} $success"
  echo "${C_YELLOW}Skipped :${C_RESET} $skipped"
  echo "${C_RED}Failed  :${C_RESET} $failed"

  if [[ "${#failed_repos[@]}" -gt 0 ]]; then
    echo
    err "Failed repos: ${failed_repos[*]}"
    return 1
  fi

  echo
  ok "All repositories are up to date."
  return 0
}

platform_deploy() {
  if ! platform_update; then
    err "Deploy aborted: git update failed."
    return 1
  fi

  echo
  info "Rebuilding and restarting services..."
  NO_BUILD=0 platform_restart
}
