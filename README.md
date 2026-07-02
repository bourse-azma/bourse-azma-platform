# bourse-azma-platform

Central platform workspace for cross-project assets in the Boors Azma ecosystem.

This directory is intended to host:

- deployment scripts and runtime manifests
- shared documentation
- common code/assets used by multiple services (for example shared Java modules in the future)

## Current Structure

- `compose/`: Docker Compose stack for local and shared environments
- `scripts/`: platform shell helpers used by `platform.sh`
- `platform.sh`: main entry point for start/stop, logs, git update, and deploy

## Current Compose Stack

File: `compose/docker-compose.yml`

Included services:

- `bourse-azma-db` (PostgreSQL)
- `redis`
- `tsetmc-api` on `9000:9000`
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
cd bourse-azma-platform

# 1. Auto-configure resources for your host (writes compose/.env)
./scripts/configure-resources.sh --force

# 2. Build images sequentially (peak build memory stays under 2 GB)
./scripts/build-sequential.sh

# 3. Start the stack
cd compose && docker compose up -d
```

Or use the platform script (runs configure + sequential build automatically):

```bash
./platform.sh start
```

For **1 vCPU / 1 GB RAM** deployments, see [`OPTIMIZATION_SUMMARY.md`](OPTIMIZATION_SUMMARY.md).

Stop:

```bash
docker compose down
```

## Security Note (JWT Secret)

In `compose/docker-compose.yml`, the value of `APP_SECURITY_JWT_SECRET` is only a sample value for local development.

For better security, change it before running in any shared/staging/production environment.

Suggested strong example (replace with your own):

```env
APP_SECURITY_JWT_SECRET=Qp7mN2vL9xRt4Ks8wZc1Ha6uJd3Fy0BnEe5Tg4Ui7Yo2
```

## UI Env File (for Docker Compose)

Create this file:

- `bourse-azma-ui/.env`

Copy from `bourse-azma-ui/.env.example` and adjust values for your environment. The compose stack mounts this file into
`tsetmc-api` and `codal-api`.

For local Vite development outside Docker, keep the proxy targets pointed at the running backend ports (`9000`, `9002`,
`9003`).

## API CORS Configuration

CORS settings for `bourse-azma-api` live in `bourse-azma-api/src/main/resources/application.properties` under
`app.cors.*`. Docker images read the same file from the built JAR, so no extra platform compose change is required for
local stack ports (`5173` for Vite, `8080` for the UI container).

To override CORS in a deployed environment without rebuilding, set Spring environment variables such as
`APP_CORS_ALLOWED_ORIGINS`.
