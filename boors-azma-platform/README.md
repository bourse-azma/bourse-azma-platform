# boors-azma-platform

Central platform workspace for cross-project assets in the Boors Azma ecosystem.

This directory is intended to host:
- deployment scripts and runtime manifests
- shared documentation
- common code/assets used by multiple services (for example shared Java modules in the future)

## Current Structure

- `deploy/`: deployment artifacts (currently Docker Compose)
- `docs/`: operational and technical documentation
- `shared/`: shared code and reusable resources across services

## Current Compose Stack

File: `deploy/docker-compose.yml`

Included services:
- `tsetmc-api` on `9000:9000`
- `fipiran-api` on `9001:9001`
- `codal-api` on `9002:9002`
- `boors-azma-ui` on `8080:8080`


## Usage

```bash
cd boors-azma-platform/deploy
docker compose up --build -d
```

Stop:

```bash
docker compose down
```

## UI Env File (for Docker Compose)

Create this file:
- `boors-azma-ui/.env`

Use these values (matched to the `deploy/docker-compose.yml` stack):

```env
VITE_MARKET_OVERVIEW_API_BASE_URL=/api/tsetmc/overview
VITE_MARKET_OVERVIEW_REFRESH_MS=10000
VITE_CODAL_NOTICES_API_BASE_URL=/api/codal/codal/notices
VITE_CODAL_NOTICES_REFRESH_MS=30000
VITE_MARKET_OVERVIEW_PROXY_TARGET=http://localhost:9000
VITE_CODAL_PROXY_TARGET=http://localhost:9002
```
