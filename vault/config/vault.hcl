# Vault server (compose/vault.yaml). One single-node Raft cluster per environment/server.
# Web UI on, but reachable only through an SSH tunnel: no published port, internal network, not behind Caddy.
#   ssh -N -L 8200:172.30.3.10:8200 root@<server>   then   https://localhost:8200/ui
ui            = true
disable_mlock = true # recommended with integrated storage; the container has no IPC_LOCK capability

storage "raft" {
  # /vault/file exists in the image and belongs to the vault user, so the named volume inherits that owner.
  path    = "/vault/file"
  node_id = "vault-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/vault/tls/vault.crt"
  tls_key_file    = "/vault/tls/vault.key"
  tls_min_version = "tls13"
}

api_addr     = "https://vault:8200"
cluster_addr = "https://vault:8201"

# The audit device itself (file at /vault/logs/audit.log) is enabled by scripts/vault/configure.sh:
# audit devices live in Vault's storage, not in this file.
