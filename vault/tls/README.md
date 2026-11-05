# Vault TLS

Nothing secret lives here. The certificates are generated **on the server** by `scripts/vault/gen-tls.sh` into
`/opt/glowderma/runtime/vault/tls/`:

| File | Mode | Owner | Read by |
|---|---|---|---|
| `ca.crt` | 0644 | root | Vault server and every agent (`ca_cert`): TLS is always verified |
| `vault.crt` | 0644 | root | Vault server |
| `vault.key` | 0400 | 100 (vault) | Vault server only |
| `ca.key` | 0400 | root | nobody at runtime; keep a copy in the offline DR kit, needed only to reissue `vault.crt` |

The server certificate covers `vault`, `localhost` and `127.0.0.1` and is valid for 5 years. Renew with
`scripts/vault/gen-tls.sh --renew` and restart the Vault project. Never commit any of these files.
