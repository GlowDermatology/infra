# Secrets management

## Where each kind of value lives

| Kind | Where | Example |
|---|---|---|
| Application secrets | Vault on the environment's own server | `SECRET_KEY`, provider passwords |
| Infrastructure credentials | Vault (same server) | database and Redis passwords |
| App settings (overrides of the code defaults) | Vault, in the same path as the app's secrets | worker counts, provider modes, log level |
| Stack values | `environments/<env>/stack.env` (this repo) | domain, memory limits |
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
secret/<env>/s3         Django + object storage  media storage provider settings and the app key (keys = env var names)
secret/<env>/object-storage  object storage only   OBJECT_STORAGE_ADMIN_ACCESS_KEY_ID, OBJECT_STORAGE_ADMIN_SECRET_ACCESS_KEY
```

Each value is stored once. The agent templates compose what each consumer needs, for example Django's
`REDIS_URL` is built from `secret/<env>/redis`. Policies (`vault/policies/<env>/`) grant `read` on exactly
those paths; the CI test `scripts/ci/test-vault.sh` proves every other read is denied, including every
read of the other environment.

| AppRole | Policy reads | Runs as | Renders |
|---|---|---|---|
| `<env>-backend` | django, shared, db-app, redis, s3 | 10001 | `django.json`, `fcm.json`, `apple.p8` |
| `<env>-frontend` | frontend, shared | 1000 | `frontend.json` |
| `<env>-datastores` | postgres, db-app, redis, object-storage, s3 | 999 | `postgres_*_password`, `redis.conf`, `redis_password`, `object_storage_s3.json`, `object_storage_admin_{access,secret}_key` |

One agent serves all Django processes (api, worker, beat, migrate) because every Django process loads the
full settings, Celery app included: a separate Celery identity would hold the same secrets.

### Media storage (S3)

`secret/<env>/s3` holds the provider settings (`S3_ENDPOINT_URL`, `S3_BUCKET_NAME`, `S3_REGION_NAME`,
`S3_ADDRESSING_STYLE`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, optional `S3_VERIFY`, `PUBLIC_MEDIA_BASE_URL`);
every key becomes an environment variable in `django.json`, like `secret/<env>/django`. The seeded values point
at the stack's own SeaweedFS (`http://object-storage:8333`, bucket `glowderma-media`); its `s3.json` identities file is
rendered by the datastores agent from `s3` (the `app` pair) and `object-storage` (the `admin` pair).

- Change provider or bucket: `vault kv patch secret/<env>/s3 ...`, then `scripts/restart.sh <env> backend` (no PR)
  while on an external provider. Leaving the stack's own storage also needs `OBJECT_STORAGE_ENABLED=false` in
  `stack.env` (a PR): `restart.sh`, the deploy and the backup refuse the mix (docs/deployment.md).
  For an external provider also set `PUBLIC_MEDIA_BASE_URL` there.
- The frontend's `GLOWDERMA_MEDIA_HOSTS` is build-time: a new image host still needs a frontend rebuild.
- Never put `USE_S3` or `S3_LOCATION` in `secret/<env>/s3`: they are topology keys (`stack.env`) and the backend
  refuses to start when the secrets file carries them.
- Existing environments: rerun `scripts/vault/generate-app-secrets.sh <env>` before deploying this release (it only
  creates the missing `s3` and `object-storage` paths).

### App settings live here too (overrides only)

`secret/<env>/django` and `secret/<env>/frontend` hold the apps' secrets **and** their public settings: both
become environment variables the same way. The rule is overrides only: a key goes in Vault when this
environment needs a value different from the default in code (`config/settings/*` in the backend,
`src/lib/env.server.ts` in the frontend); delete it to return to the default. Change keys in the Vault UI, then
Actions → **Restart** (see below). Keep in mind:

- Provider modes: everything is `fake` until its go-live checklist is done (backend `docs/integrations/*.md`);
  then set `<PROVIDER>_MODE=live` and the provider's credentials here.
- `DJANGO_ADMIN_ENABLED=true` (ops console) also needs `OPS_ALLOWED_IPS` in the server's `local.env`: see
  [ops-console-access.md](ops-console-access.md).
- `SECURE_HSTS_PRELOAD=true` is a deliberate, near-irreversible opt-in.
- A misspelled key is ignored silently, and a malformed value (`GUNICORN_WORKERS=abc`) stops the app at
  start: check the Restart run goes green.
- Frontend keys read at build time (`NEXT_PUBLIC_*`, `GLOWDERMA_MEDIA_HOSTS`, `GLOWDERMA_ALLOWED_ORIGINS`) are
  frontend repo GitHub variables, not Vault. `GLOWDERMA_DATA_SOURCE=api` is set by `compose/app.yaml`.

The env files `environments/<env>/backend.env` and `frontend.env` were moved here once with
`scripts/vault/import-env.sh <env>` (adds only keys Vault does not have yet).

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
| add/change Django or Next keys in the Vault UI (SSH tunnel, see `vault/config/vault.hcl`) | then GitHub Actions → **Restart** → `<env>` + `backend`/`frontend`/`all` (or `scripts/restart.sh <env> <target>` on the server) |
| add/change one Django or Next secret | `scripts/vault/put-secret.sh <env> django <KEY>` (hidden prompt, then `restart.sh`) |
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
