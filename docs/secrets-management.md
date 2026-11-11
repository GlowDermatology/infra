# Secrets management

## Where each kind of value lives

| Kind | Where | Example |
|---|---|---|
| Application secrets | Vault on the environment's own server | `SECRET_KEY`, provider passwords |
| Infrastructure credentials | Vault (same server) | database and Redis passwords |
| Public settings | `environments/<env>/*.env` (this repo) | worker counts, provider modes, domain |
| Private, not secret | `/opt/glowderma/runtime/local.env` on the server | office IP allow-list, backup remote |
| Build-time frontend values | frontend repo environment variables (`staging` / `production`) | `NEXT_PUBLIC_SITE_URL` |
| Deploy access | infra repo GitHub environment secrets | `VPS_SSH_KEY` (deploy gate only), `VPS_BOOTSTRAP_SSH_KEY` (root, bootstrap only) |

GitHub never holds an application secret, a Vault token or an unseal key. A GitHub runner can deploy an image
but cannot read a single production secret.

## Vault layout (KV v2 at `secret/`)

```
secret/<env>/django     Django only            every key = an environment variable name
secret/<env>/frontend   Next.js only           every key = an environment variable name
secret/<env>/shared     Django + Next.js       INTERNAL_API_SECRET (Next receives it as GLOWDERMA_INTERNAL_SECRET)
secret/<env>/db-app     Django + Postgres      password  (role glowderma_app)
secret/<env>/redis      Django + Redis         password
secret/<env>/postgres   Postgres only          password  (superuser, never reaches Django)
```

Each value is stored once. The agent templates compose what each consumer needs, for example Django's
`REDIS_URL` is built from `secret/<env>/redis`. Policies (`vault/policies/<env>/`) grant `read` on exactly
those paths; the CI test `scripts/ci/test-vault.sh` proves every other read is denied, including every
read of the other environment.

| AppRole | Policy reads | Runs as | Renders |
|---|---|---|---|
| `<env>-backend` | django, shared, db-app, redis | 10001 | `django.json`, `fcm.json`, `apple.p8` |
| `<env>-frontend` | frontend, shared | 1000 | `frontend.json` |
| `<env>-datastores` | postgres, db-app, redis | 999 | `postgres_*_password`, `redis.conf`, `redis_password` |

One agent serves all Django processes (api, worker, beat, migrate) because every Django process loads the
full settings, Celery app included: a separate Celery identity would hold the same secrets.

### Files the agents render

Memory-only volumes (`tmpfs`) owned by the consumer's UID, mode 0700; files 0400; read-only in the consumer.
No token sink: the Vault token exists only inside the agent process. No previous-version backup files.
Optional key files: store the base64 of the Firebase service-account JSON as `FCM_CREDENTIALS_JSON_B64` and of
the Apple `.p8` key as `APPLE_PRIVATE_KEY_B64` in `secret/<env>/django`, and set
`FCM_CREDENTIALS_FILE=/run/secrets/fcm.json` / `APPLE_PRIVATE_KEY_FILE=/run/secrets/apple.p8` there too.

### How Django reads them

`config/secrets.py` (backend repo) runs before any setting is read. It loads the JSON file named by
`DJANGO_SECRETS_FILE`, validates it (an object of strings), refuses keys that belong to the Compose topology
(`POSTGRES_HOST`, `ALLOWED_HOSTS`, …), and puts the values into the process environment. Error messages name
the key, never the value. Production settings then fail fast on any missing or placeholder secret. The
container entrypoint waits for the file to exist before starting Django.

## Changing a secret

| Change | Command (on the server) |
|---|---|
| add/change one Django or Next secret | `scripts/vault/put-secret.sh <env> django <KEY>` (hidden prompt, restarts the consumers) |
| rotate the database app password | `scripts/vault/rotate-db-password.sh <env>` |
| rotate the internal API secret | `scripts/vault/rotate-internal-secret.sh <env>` |
| rotate an agent's AppRole secret_id | `scripts/vault/rotate-approle-secret-id.sh <env> <role>` (root) |
| rotate Redis or the superuser password | write the new value, then `scripts/deploy.sh <env> --restart redis backend-api backend-worker backend-beat` (Redis) or `ALTER ROLE glowderma PASSWORD` via `scripts/manage.sh <env> psql` (superuser) |

**Why a restart:** the agent re-renders a changed file within 5 minutes (`static_secret_render_interval`), but
Django, Next.js, Redis and open database connections read their secrets at start. Every rotation script
therefore restarts the agent (immediate render) and recreates the consumers. Expect a few seconds of errors
on the restarted service, not on the whole site.

## Failure behaviour

| Situation | What happens |
|---|---|
| Vault sealed (after a reboot) | agents keep retrying; running containers keep their rendered files; containers that start (after a reboot: all of them) **wait** for their files: postgres/redis/frontend/backend print "waiting for Vault secrets". `scripts/vault/unseal.sh <env>` and everything comes up by itself within a minute. `deploy.sh` refuses to deploy while sealed. |
| Vault down or unreachable | same as sealed; running services are unaffected until they restart. |
| AppRole login refused (secret_id revoked, policy missing) | the agent logs the error and retries with backoff; its healthcheck stays unhealthy; `healthcheck.sh` points at Vault. |
| A required secret key missing | the agent does not render the file (`error_on_missing_key`); the consumer keeps waiting; the agent log names the key. |
| A secret has a placeholder value | Django refuses to start (production settings validation) with a message naming the key. |

## Moving to dynamic database credentials later

Today Postgres credentials are static values in KV. The Database secrets engine can replace `secret/<env>/db-app`
without changing the layout: the backend template would read `database/creds/<env>-app` instead, and the
deploy would recreate the Django processes when the lease is renewed. Not done yet on purpose: the connection
pool (psycopg pool in each process) needs a lease-aware reconnect first.
