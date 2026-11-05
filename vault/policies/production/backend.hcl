# production Django processes (api, worker, beat, migrate): their own secrets, the internal secret shared with Next,
# the application DB password and the Redis password. Never the Postgres superuser, never another environment.
path "secret/data/production/django" { capabilities = ["read"] }
path "secret/data/production/shared" { capabilities = ["read"] }
path "secret/data/production/db-app" { capabilities = ["read"] }
path "secret/data/production/redis"  { capabilities = ["read"] }
