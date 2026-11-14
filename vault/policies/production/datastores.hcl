# production PostgreSQL and Redis: the superuser password, the application role password (set by initdb) and the
# Redis password, plus the object storage admin keys and the S3 app key pair (SeaweedFS identities).
path "secret/data/production/postgres" { capabilities = ["read"] }
path "secret/data/production/db-app"   { capabilities = ["read"] }
path "secret/data/production/redis"    { capabilities = ["read"] }
path "secret/data/production/object-storage" { capabilities = ["read"] }
path "secret/data/production/s3"             { capabilities = ["read"] }
# scripts/lib.sh vault_kv logs in with this role for one read, then revokes that token at once (the role has no
# default policy, which would otherwise grant this). Revoking itself is all a token can do here.
path "auth/token/revoke-self" { capabilities = ["update"] }
