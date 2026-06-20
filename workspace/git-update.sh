#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPOS=(
  tsetmc-api
  bourse-azma-api
  codal-api
  fipiran-api
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

SUCCESS=0
SKIPPED=0
FAILED=0
FAILED_REPOS=()

echo
title "===== bourse-azma update ====="
info "Workspace: $WORKSPACE_DIR"
echo

for repo in "${REPOS[@]}"; do
  repo_path="$WORKSPACE_DIR/$repo"

  if [[ ! -d "$repo_path" ]]; then
    warn "$repo — directory not found, skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ ! -d "$repo_path/.git" ]]; then
    warn "$repo — not a git repository, skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "${C_BOLD}→ $repo${C_RESET}"

  branch="$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  info "Branch: $branch"

  if git -C "$repo_path" pull --ff-only 2>&1 | sed "s/^/  ${C_DIM}/;s/$/${C_RESET}/"; then
    ok "$repo updated."
    SUCCESS=$((SUCCESS + 1))
  else
    err "$repo pull failed."
    FAILED=$((FAILED + 1))
    FAILED_REPOS+=("$repo")
  fi

  echo
done

title "===== Summary ====="
echo "${C_GREEN}Updated :${C_RESET} $SUCCESS"
echo "${C_YELLOW}Skipped :${C_RESET} $SKIPPED"
echo "${C_RED}Failed  :${C_RESET} $FAILED"

if [[ "${#FAILED_REPOS[@]}" -gt 0 ]]; then
  echo
  err "Failed repos: ${FAILED_REPOS[*]}"
  exit 1
fi

echo
ok "All repositories are up to date."
