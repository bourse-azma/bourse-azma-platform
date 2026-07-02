#!/usr/bin/env bash
# Sequential Docker builds to keep peak build memory under 2 GB.
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

echo "Sequential build (MAVEN=${MAVEN_HEAP}MB, NODE=${NODE_HEAP}MB per service)"

for service in "${SERVICES[@]}"; do
  echo "==> Building $service"
  "${COMPOSE[@]}" build \
    --build-arg "MAVEN_BUILD_HEAP_MB=${MAVEN_HEAP}" \
    --build-arg "NODE_BUILD_HEAP_MB=${NODE_HEAP}" \
    "$service"
done

echo "All images built sequentially."
