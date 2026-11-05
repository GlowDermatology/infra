# staging PostgreSQL and Redis: the superuser password, the application role password (set by initdb) and the
# Redis password.
path "secret/data/staging/postgres" { capabilities = ["read"] }
path "secret/data/staging/db-app"   { capabilities = ["read"] }
path "secret/data/staging/redis"    { capabilities = ["read"] }
