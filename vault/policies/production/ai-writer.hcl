# production AI provider keys, writer side: vault-agent-ai-writer, whose api_proxy only backend-api reaches (network
# ai-writer). The ops console writes a new key as a new KV v2 version (the response carries its number); it can
# never read a key back, list, delete or destroy one, or touch metadata (configure.sh sets max_versions).
path "secret/data/production/ai/*" { capabilities = ["create", "update"] }
