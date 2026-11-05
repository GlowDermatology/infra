# Vault Agent for the "backend" consumers (compose/app.yaml service vault-agent-backend).
# Logs in with its own AppRole, reads only what policies/<env>/backend.hcl allows, renders files into the
# memory-only volume it shares (read-only) with its consumer. No token sink: the token never leaves this process.
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

template_config {
  exit_on_retry_failure         = false # a Vault outage must not kill the sidecar
  static_secret_render_interval = "5m"  # how fast a `vault kv patch` reaches the files
}

template {
  source               = "/vault/agent/templates/django.json.ctmpl"
  destination          = "/run/secrets/django.json"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

# Optional key files (live FCM / Sign in with Apple). Empty when the base64 field is not stored.
template {
  source      = "/vault/agent/templates/fcm.json.ctmpl"
  destination = "/run/secrets/fcm.json"
  perms       = "0400"
  backup      = false
}

template {
  source      = "/vault/agent/templates/apple.p8.ctmpl"
  destination = "/run/secrets/apple.p8"
  perms       = "0400"
  backup      = false
}
