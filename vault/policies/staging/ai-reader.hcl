# staging AI provider keys, reader side: vault-agent-ai-reader, whose api_proxy only backend-worker reaches (network
# ai-reader). The worker reads the active version (or a pending one to test it); it can never write.
path "secret/data/staging/ai/*" { capabilities = ["read"] }
