#!/usr/bin/env bash
# Build only changed images, sequentially, to keep peak memory under 2 GB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/../compose" && pwd)"

cd "$COMPOSE_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "docker compose is required" >&2
  exit 1
fi

if [[ -f .env ]]; then
  MAVEN_HEAP="$(grep -E '^MAVEN_BUILD_HEAP_MB=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'"' || true)"
  NODE_HEAP="$(grep -E '^NODE_BUILD_HEAP_MB=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'"' || true)"
fi
MAVEN_HEAP="${MAVEN_HEAP:-384}"
NODE_HEAP="${NODE_HEAP:-256}"

SERVICES=(tsetmc-api codal-api bourse-azma-api bourse-azma-ui)
STATE_DIR="$COMPOSE_DIR/.build-state"
mkdir -p "$STATE_DIR"

source_dir_for() {
  case "$1" in
    tsetmc-api|codal-api|bourse-azma-ui) echo "$COMPOSE_DIR/../../$1" ;;
    bourse-azma-api) echo "$COMPOSE_DIR/../../bourse-azma-api" ;;
  esac
}

source_fingerprint() {
  local source_dir="$1"
  local service="$2"
  (
    cd "$source_dir"
    find . -type f \
      ! -path './.git/*' \
      ! -path './target/*' \
      ! -path './node_modules/*' \
      ! -path './dist/*' \
      ! -name '.DS_Store' \
      ! -name '._*' \
      -print0 \
      | xargs -0 shasum -a 256 \
      | LC_ALL=C sort \
      | shasum -a 256 \
      | awk '{print $1}'
    if [[ "$service" == "bourse-azma-api" ]]; then
      shasum -a 256 "$COMPOSE_DIR/../../market.csv" | awk '{print $1}'
    fi
  ) | shasum -a 256 | awk '{print $1}'
}

echo "Smart sequential build (MAVEN=${MAVEN_HEAP}MB, NODE=${NODE_HEAP}MB per service)"

for service in "${SERVICES[@]}"; do
  source_dir="$(source_dir_for "$service")"
  fingerprint="$(source_fingerprint "$source_dir" "$service")"
  state_file="$STATE_DIR/$service.sha256"

  if docker image inspect "$service" >/dev/null 2>&1 \
    && [[ -f "$state_file" ]] \
    && [[ "$(cat "$state_file")" == "$fingerprint" ]]; then
    echo "==> Skipping $service (source unchanged)"
    continue
  fi

  echo "==> Building $service"
  "${COMPOSE[@]}" build \
    --build-arg "MAVEN_BUILD_HEAP_MB=${MAVEN_HEAP}" \
    --build-arg "NODE_BUILD_HEAP_MB=${NODE_HEAP}" \
    "$service"
  printf '%s\n' "$fingerprint" > "$state_file"
done

echo "Images are up to date."
