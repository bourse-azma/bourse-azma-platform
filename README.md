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
./platform.sh remote-deploy   # bootstrap once, then build/deploy on the server
```

### Remote deployment model

`remote-deploy` has two automatic phases:

- On a fresh server it runs a one-time bootstrap: OS updates, Docker, UFW,
  fail2ban, swap, persistent secrets, Let's Encrypt and registry/build images.
- On later runs it skips all host provisioning. It uploads only a compact
  source archive (git metadata, Maven targets, `node_modules` and `dist` are
  excluded), builds all images on the server using Docker layer cache, and
  recreates the Compose stack.

Build images are pulled from `docker.arvancloud.ir`, then
`docker.abrha.net`, with the configured Docker daemon mirror as the fallback.
No locally built Docker image is transferred over SCP.

To deliberately repeat bootstrap after changing host provisioning:

```bash
REMOTE_FORCE_BOOTSTRAP=1 ./platform.sh remote-deploy
```

Interactive menu option `7` opens remote operations:

- **Deploy / Release** uploads source, builds on the server, and deploys the stack.
- **Edit configuration** edits the persistent production configuration for the
  UI, Bourse Azma API, Codal API, or TSETMC API. Backend changes recreate only
  the selected container. UI changes rebuild only the UI image (Vite variables
  are compile-time settings) and then recreate its container. Each operation
  waits for the affected service to become healthy.

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

The JWT signing secret is now generated randomly and securely **in code** at application startup
(see `JwtTokenService`).

No `APP_SECURITY_JWT_SECRET` (or `app.security.jwt.secret`) configuration is required or used.
A fresh strong key (512-bit) is created on every start using `SecureRandom`. This means
active access tokens are invalidated on restart (acceptable given the token lifetime).

Cookie security (`Secure` flag) is hardcoded to `true` and no longer read from configuration.

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
