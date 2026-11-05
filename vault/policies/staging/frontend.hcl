# staging Next.js server: its own secrets and the internal secret it sends to Django.
path "secret/data/staging/frontend" { capabilities = ["read"] }
path "secret/data/staging/shared"   { capabilities = ["read"] }
