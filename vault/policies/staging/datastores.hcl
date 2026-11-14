# staging PostgreSQL and Redis: the superuser password, the application role password (set by initdb) and the
# Redis password, plus the object storage admin keys and the S3 app key pair (SeaweedFS identities).
path "secret/data/staging/postgres" { capabilities = ["read"] }
path "secret/data/staging/db-app"   { capabilities = ["read"] }
path "secret/data/staging/redis"    { capabilities = ["read"] }
path "secret/data/staging/object-storage" { capabilities = ["read"] }
path "secret/data/staging/s3"             { capabilities = ["read"] }
