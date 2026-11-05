# staging Django processes (api, worker, beat, migrate): their own secrets, the internal secret shared with Next,
# the application DB password and the Redis password. Never the Postgres superuser, never another environment.
path "secret/data/staging/django" { capabilities = ["read"] }
path "secret/data/staging/shared" { capabilities = ["read"] }
path "secret/data/staging/db-app" { capabilities = ["read"] }
path "secret/data/staging/redis"  { capabilities = ["read"] }
