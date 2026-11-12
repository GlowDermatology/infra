# Architecture

## One server, one environment

Staging and production are two separate servers (later: two separate clusters). They share nothing at runtime:
no network, no database, no Vault. The only shared thing is this repository's templates (`compose/`, `caddy/`,
`vault/`, `scripts/`), which is what makes a new server reproducible.

```
                         Internet (IPv4 + IPv6)
                                  │  80/tcp, 443/tcp, 443/udp (HTTP/3)
┌─────────────────────────────────┼───────────────────────────────────── server (Ubuntu 24.04/26.04) ─┐
│  project glowderma-<env>        ▼                                                                    │
│                         ┌──────────────┐  network "front" (dual stack, fixed addresses)             │
│                         │ edge (Caddy) │ 172.30.0.10 / fd00:6764:0:1::10                             │
│                         └──┬────────┬──┘                                                             │
│            everything else │        │ /api/v1/*                                                      │
│                ┌───────────▼─┐    ┌─▼─────────────┐                                                  │
│                │ frontend    │───►│ backend-api   │ 172.30.0.30   gunicorn (Django)                   │
│                │ Next.js .20 │    └─┬─────────────┘                                                  │
│                └──────▲──────┘      │  network "back" (internal: no route out)                       │
│                       │      ┌──────┴───────┬──────────────┬─────────────┐                           │
│                       │      │ backend-     │ backend-beat │ postgres 18 │ redis 8                   │
│                       │      │ worker ──────┼─► egress     │             │                           │
│   memory-only secret files (tmpfs volumes, read-only in the consumer)                                │
│        ▲ vault-agent-frontend   ▲ vault-agent-backend   ▲ vault-agent-datastores                     │
└────────┼────────────────────────┼───────────────────────┼────────────────────────────────────────────┘
         └────────────────────────┴───────────────────────┴── network glowderma-<env>-vault (internal)
                                                              project glowderma-<env>-vault: Vault (Raft, TLS)
```

## Request flow (same origin)

| Path on `https://<SITE_DOMAIN>` | Goes to | Notes |
|---|---|---|
| `/api/v1/*` | Django (`backend-api`) | customer API, health, provider webhooks, POS |
| `/api/v1/admin/*`, `/api/v1/schema/*`, `/api/v1/docs/*`, `/api/v1/dev/*`, `/django-admin*` | 404 at the edge | staff surfaces: only the Next server calls them, over the private network |
| `/media/*` | files on disk | uploaded images, served by Caddy |
| everything else | Next.js | storefront, `/admin` panel, Next's own `/api/shop/*` and `/api/revalidate` |
| `https://www.<SITE_DOMAIN>` | 308 to the apex | |
| `https://<OPS_DOMAIN>/django-admin/` | Django ops console | only from `OPS_ALLOWED_IPS` (Tailscale device IPs, [ops-console-access.md](ops-console-access.md)), 404 for everyone else |

The browser never talks to Django for the admin panel: Next is a backend-for-frontend that calls
`http://172.30.0.30:8000` with the internal secret. Django accepts `/api/v1/admin/*` only from Next's fixed
address **and** with that secret. Every internal hop uses a fixed IPv4 literal so a DNS answer can never turn
it into an IPv6 connection that the address gates do not recognise. `scripts/validate.sh` checks that the
addresses in `compose/app.yaml` and the Django/gunicorn gates agree.

## Processes

| Service | Image | Runs as | Purpose |
|---|---|---|---|
| `edge` | caddy 2.11.8 | 1000 | TLS (ACME), HTTP/1.1/2/3, routing, redaction |
| `frontend` | `ghcr.io/glowdermatology/frontend:frontend-<sha>-<env>` | 1000 | Next.js standalone server |
| `backend-api` | `ghcr.io/glowdermatology/backend:backend-<sha>` | 10001 | gunicorn, `GUNICORN_WORKERS` × `GUNICORN_THREADS` |
| `backend-worker` | same | 10001 | Celery worker, `CELERY_CONCURRENCY` |
| `backend-beat` | same | 10001 | Celery beat (exactly one) |
| `backend-migrate` | same | 10001 | one-shot `migrate`, run only by `deploy.sh` |
| `postgres` | postgres 18.6 | 999 | data; superuser for admin, `glowderma_app` for Django |
| `redis` | redis 8.10 | 999 | DB 0 cache, DB 1 Celery broker (AOF, noeviction) |
| `vault-agent-*` | vault 2.2.1 | consumer's UID | render secrets for one consumer group |
| `vault` (own project) | vault 2.2.1 | 100 | secrets, Raft storage, TLS, audit log |

All containers: read-only root filesystem, every capability dropped, `no-new-privileges`, explicit non-root
user, memory and PID limits, health checks, json-file logs capped at 100 MB per container.

## Persistent state

| What | Where | Backed up by |
|---|---|---|
| PostgreSQL | named volume `glowderma-<env>_pgdata` | `backup.sh` (nightly + before each backend release) |
| Redis | named volume `glowderma-<env>_redisdata` | not backed up: cache + in-flight tasks only |
| uploaded media | `/opt/glowderma/runtime/media` | `backup.sh` nightly |
| Vault data | named volume `glowderma-<env>-vault_vault-data` | `backup.sh` nightly (Raft snapshot) |
| TLS certificates | `/opt/glowderma/runtime/caddy/data` | re-issued automatically if lost |
| Vault TLS, AppRole files | `/opt/glowderma/runtime/vault` | regenerated by scripts (DR runbook) |
| what is deployed | `/opt/glowderma/runtime/deployed/` | git history is the source of truth |

## Secret flow

```
operator (on the server) ──vault kv put──► Vault ──AppRole login──► vault-agent-<group> ──renders──► /run/secrets/* (tmpfs)
                                                                                                      │ read-only mount
                                                       Django: config/secrets.py loads django.json ◄──┤
                                                       Next:   entrypoint.mjs loads frontend.json  ◄──┤
                                                       Postgres: *_PASSWORD_FILE, Redis: redis.conf ◄─┘
```

Details: [secrets-management.md](secrets-management.md).
