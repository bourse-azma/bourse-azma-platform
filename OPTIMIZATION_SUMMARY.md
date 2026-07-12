# Low-Resource Optimization Summary

Optimizations for running the full Bourse Azma stack on **1 vCPU / 1 GB RAM** hosts, with **build/startup peak memory
capped under 2 GB** and **idle RSS target of 300–500 MB**.

## Measured Results (ultra profile, validated)

| Metric                            | Result                                                         |
|-----------------------------------|----------------------------------------------------------------|
| Idle RSS (all 6 containers)       | **~489–560 MiB**                                               |
| Container memory limits (total)   | **728 MiB**                                                    |
| Sequential build peak             | **< 2 GB** (one Maven/Node build at a time, 384/256 MB heaps)  |
| Startup peak (staggered JVM boot) | **< 700 MiB** (one Java service at a time)                     |
| Load test (50 req, c=5 on UI)     | **0 failures**, ~5,300 req/s                                   |
| Full low-profile startup          | **~23 s** to all services healthy (measured on Docker Desktop) |
| No-change second start            | **~1.7 s** (unchanged image builds are skipped)                |

---

## Resource Profiles

Four adaptive profiles in `compose/profiles/` are applied by `scripts/configure-resources.sh` (auto-detects **RAM + CPU
cores
**):

| Profile         | Auto-selection rule                            | Limit total | Idle target        | Use case              |
|-----------------|------------------------------------------------|-------------|--------------------|-----------------------|
| **ultra**       | ≤ 1.2 GB RAM                                   | ~728 MB     | 400–560 MB         | 1 vCPU / 1 GB VPS     |
| **low**         | ≤ 2.5 GB RAM, **or** ≤ 2 cores with ≤ 4 GB RAM | 1,168 MB    | 650–850 MB         | 2-core / 2 GB hosts   |
| **standard**    | Mid-sized hosts below a performance threshold  | ~1.1 GB     | 600–900 MB         | Medium dev/prod hosts |
| **performance** | ≥ 8 GB RAM and ≥ 4 CPU cores                   | 2,752 MB    | workload-dependent | High-throughput hosts |

The performance profile expands JVM heaps, connection pools, PostgreSQL/Redis caches and CPU burst limits. It is
selected only when the host has both enough memory and enough CPU; smaller machines retain strict hard limits.

`platform.sh start` and `platform.sh restart` run `configure-resources.sh --auto`, which applies the recommended profile
when `.env` is missing, stale, or too aggressive for the host (e.g. ultra on a 16 GB machine). To pin a profile
manually, add `# Manual profile lock` to `compose/.env`.

### Quick start

```bash
cd bourse-azma-platform

# Auto-detect host RAM and write compose/.env
./scripts/configure-resources.sh --force

# Build one service at a time (keeps build memory < 2 GB)
./scripts/build-sequential.sh

# Start stack
cd compose && docker compose up -d
```

Force a profile:

```bash
RESOURCE_PROFILE=ultra ./scripts/configure-resources.sh --force
```

Simulate a 1 GB host on a large machine:

```bash
HOST_MEMORY_MB=1024 ./scripts/configure-resources.sh --force
```

---

## Architecture Decisions

### Why three Spring Boot services?

The stack requires separate `tsetmc-api`, `codal-api`, and `bourse-azma-api` containers. **300–500 MB idle with three
JVMs is only achievable with aggressive tuning**, not by magic. Key techniques:

1. **Fixed small heaps** (`-Xmx64m` / `-Xmx120m`) instead of percentage-based sizing
2. **G1 + full tiered JIT** on 2 GB+ hosts; SerialGC/C1 is reserved for the emergency 1 GB profile
3. **Eager Spring initialization** on 2 GB+ profiles — startup work is paid once, not on user requests
4. **Parallel independent startup** — UI, PostgreSQL and Redis start together; proxy APIs start together after Redis
5. **Smart sequential Docker builds** — changed images build one at a time; unchanged images are skipped

### Adaptive scaling under load

- Containers grow toward their **hard `mem_limit`** as caches warm up (observed: proxy APIs ~99% of limit under idle
  polling)
- Limits prevent OOM on the host; Docker kills/restarts only the overflowing container
- Move through **`low`**, **`standard`**, and **`performance`** when sustained load needs more capacity
- Scaling is transparent to users: nginx + Redis cache absorb polling; GC pauses are short with SerialGC on small heaps

---

## ultra Profile Defaults

| Service         | Limit | JVM heap | Metaspace |
|-----------------|-------|----------|-----------|
| postgres        | 96m   | —        | —         |
| redis           | 32m   | —        | —         |
| tsetmc-api      | 144m  | 56m      | 72m       |
| codal-api       | 144m  | 56m      | 72m       |
| bourse-azma-api | 288m  | 112m     | 128m      |
| bourse-azma-ui  | 24m   | —        | —         |

All JVM flags are overridable in `compose/.env` (see `.env.example` and `profiles/*.env`).

---

## JVM Tuning (ultra)

```
-XX:+UseSerialGC
-XX:+UseContainerSupport
-Xms24m -Xmx56m          (proxy APIs)
-Xms48m -Xmx112m         (main API)
-Xss256k
-XX:MaxMetaspaceSize=72m|128m
-XX:TieredStopAtLevel=1  (C1 compiler only — saves ~30-50 MB per JVM)
-XX:+ExitOnOutOfMemoryError
```

Build-time caps in Dockerfiles:

- Maven: `MAVEN_OPTS=-Xmx384m -XX:+UseSerialGC`
- Node: `NODE_OPTIONS=--max-old-space-size=256`

---

## Spring Boot (prod profile)

- Default eager Spring initialization (no redundant override)
- Swagger/OpenAPI disabled
- Tomcat: 25 threads max, 80 connections
- HikariCP: pool 4, min idle 1
- Redis Lettuce: pool 3–4, min idle 0
- WARN root logging, JMX disabled
- Graceful shutdown (20 s)

---

## React / Frontend

- Vite manual chunks: `vendor`, `charts`, `icons`
- Lazy routes: Landing, Auth, TradingDashboard
- nginx: minimal proxy buffers
- Charts bundle (~391 KB gzip ~89 KB) loaded only when dashboard opens

---

## Docker Compose Features

- `mem_limit` + `cpus` on every service (enforced on standalone Compose)
- `deploy.resources` for Swarm compatibility
- `stop_grace_period: 30s` on Java services
- tini as PID 1, jlink minimal JRE, netcat health checks
- Minimal `depends_on` health gates; independent services start in parallel

---

## Troubleshooting

### Metaspace OOM on `bourse-azma-api`

Increase in `compose/.env`:

```env
BOURSE_AZMA_API_MEM_LIMIT=304m
BOURSE_AZMA_API_JAVA_OPTS="-Xmx112m ... -XX:MaxMetaspaceSize=128m ..."
```

### Pin ultra on a large dev machine

`platform.sh` auto-upgrades ultra → standard on 16 GB+ hosts. To keep ultra locally:

```env
# Manual profile lock
RESOURCE_PROFILE_MANUAL=1
RESOURCE_PROFILE=ultra
```

Then: `./platform.sh restart --no-build`

### Proxy API restarts at 99% memory

Bump `TSETMC_API_MEM_LIMIT` / `CODAL_API_MEM_LIMIT` by 16–32m, or switch to `low` profile.

### Build OOM on developer machine

Ensure sequential build:

```bash
./scripts/build-sequential.sh
```

Lower build heaps:

```env
MAVEN_BUILD_HEAP_MB=320
NODE_BUILD_HEAP_MB=192
```

---

## Files Changed

| Area     | Paths                                                                       |
|----------|-----------------------------------------------------------------------------|
| Profiles | `compose/profiles/{ultra,low,standard,performance}.env`                     |
| Scripts  | `scripts/configure-resources.sh`, `scripts/build-sequential.sh`             |
| Compose  | `compose/docker-compose.yml`, `compose/.env.example`                        |
| APIs     | `*/application.properties`, `*/application-prod.properties`, `*/Dockerfile` |
| UI       | `vite.config.ts`, `App.tsx`, `Dockerfile`, `nginx.conf`                     |
| Platform | `scripts/lib/compose.sh`, `README.md`                                       |
