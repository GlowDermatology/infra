# production Next.js server: its own secrets and the internal secret it sends to Django.
path "secret/data/production/frontend" { capabilities = ["read"] }
path "secret/data/production/shared"   { capabilities = ["read"] }
