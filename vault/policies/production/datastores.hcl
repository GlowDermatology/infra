# production PostgreSQL and Redis: the superuser password, the application role password (set by initdb) and the
# Redis password, plus the object storage admin keys and the S3 app key pair (SeaweedFS identities).
path "secret/data/production/postgres" { capabilities = ["read"] }
path "secret/data/production/db-app"   { capabilities = ["read"] }
path "secret/data/production/redis"    { capabilities = ["read"] }
path "secret/data/production/object-storage" { capabilities = ["read"] }
path "secret/data/production/s3"             { capabilities = ["read"] }
