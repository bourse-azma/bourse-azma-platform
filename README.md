# bourse-azma-platform

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

- `bourse-azma-db` (PostgreSQL)
- `tsetmc-api` on `9000:9000`
- `fipiran-api` on `9001:9001`
- `codal-api` on `9002:9002`
- `bourse-azma-api` on `9003:9003`
- `bourse-azma-ui` on `8080:8080`

## Platform Script

Main entry point: `platform.sh` — start/stop services, view logs, and update all workspace repos via git.

```bash
cd bourse-azma-platform

# Interactive menu
./platform.sh

# CLI commands
./platform.sh start
./platform.sh stop
./platform.sh restart
./platform.sh update
./platform.sh status
./platform.sh logs --service tsetmc-api --follow
./platform.sh deploy          # update + restart (CLI shortcut)
```

## Manual Compose Usage

```bash
cd bourse-azma-platform/deploy
docker compose up --build -d
```

Stop:

```bash
docker compose down
```

## Security Note (JWT Secret)

In `deploy/docker-compose.yml`, the value of `APP_SECURITY_JWT_SECRET` is only a sample value for local development.

For better security, change it before running in any shared/staging/production environment.

Suggested strong example (replace with your own):

```env
APP_SECURITY_JWT_SECRET=Qp7mN2vL9xRt4Ks8wZc1Ha6uJd3Fy0BnEe5Tg4Ui7Yo2
```

## UI Env File (for Docker Compose)

Create this file:

- `bourse-azma-ui/.env`

Use these values (matched to the `deploy/docker-compose.yml` stack):

```env
VITE_MARKET_OVERVIEW_API_BASE_URL=/api/tsetmc/overview
VITE_MARKET_OVERVIEW_REFRESH_MS=10000
VITE_CODAL_NOTICES_API_BASE_URL=/api/codal/codal/notices
VITE_CODAL_NOTICES_REFRESH_MS=30000
VITE_AUTH_API_BASE_URL=/api/auth
VITE_MARKET_OVERVIEW_PROXY_TARGET=http://localhost:9000
VITE_CODAL_PROXY_TARGET=http://localhost:9002
VITE_AUTH_PROXY_TARGET=http://localhost:9003
```
