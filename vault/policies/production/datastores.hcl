# production PostgreSQL and Redis: the superuser password, the application role password (set by initdb) and the
# Redis password.
path "secret/data/production/postgres" { capabilities = ["read"] }
path "secret/data/production/db-app"   { capabilities = ["read"] }
path "secret/data/production/redis"    { capabilities = ["read"] }
