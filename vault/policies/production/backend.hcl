# production Django processes (api, worker, beat, migrate): their own secrets, the internal secret shared with Next,
# the application DB password, the Redis password and the media storage settings (s3). Never the Postgres superuser, never another environment.
path "secret/data/production/django" { capabilities = ["read"] }
path "secret/data/production/shared" { capabilities = ["read"] }
path "secret/data/production/db-app" { capabilities = ["read"] }
path "secret/data/production/redis"  { capabilities = ["read"] }
path "secret/data/production/s3"     { capabilities = ["read"] }
