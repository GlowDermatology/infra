# Vault Agent for the AI key reader (compose/app.yaml service vault-agent-ai-reader).
# No template, no sink, no cache: an API proxy that adds its own token (AppRole <env>-ai-reader, policy
# policies/<env>/ai-reader.hcl: read on secret/data/<env>/ai/* only) to every request. It listens on the
# private network ai-reader, shared with backend-worker only, so Celery reads a key version without ever
# holding a Vault token or AppRole credentials (backend VAULT_PROXY_URL).
pid_file = "/tmp/agent.pid"

vault {
  address = "https://vault:8200"
  ca_cert = "/vault/tls/ca.crt" # TLS is always verified against our own CA
  retry {
    num_retries = -1 # keep retrying while Vault is sealed or restarting
  }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/vault/approle/role_id"
      secret_id_file_path                 = "/vault/approle/secret_id"
      remove_secret_id_file_after_reading = false # the file is on a read-only mount
    }
  }
}

api_proxy {
  use_auto_auth_token = "force" # a token sent by the client is replaced, never forwarded
}

# Plain HTTP on purpose: the network is internal and holds only this agent and its consumer. TLS to Vault stays verified.
# Bound to the agent's fixed address on ai-reader only (compose/app.yaml), never 0.0.0.0: the vault network must not reach it.
listener "tcp" {
  address     = "172.30.5.10:8100"
  tls_disable = true
}
