# Vault Agent for the "datastores" consumers (compose/app.yaml service vault-agent-datastores).
# Logs in with its own AppRole, reads only what policies/<env>/datastores.hcl allows, renders files into the
# memory-only volume it shares (read-only) with its consumer. No token sink: the token never leaves this process.
# Two volumes: /run/secrets (postgres, redis) and /run/object-storage-secrets (the object storage's s3.json and admin
# keys), so the network-facing object storage never mounts the database passwords.
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
  source               = "/vault/agent/templates/postgres_superuser_password.ctmpl"
  destination          = "/run/secrets/postgres_superuser_password"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/postgres_app_password.ctmpl"
  destination          = "/run/secrets/postgres_app_password"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/redis.conf.ctmpl"
  destination          = "/run/secrets/redis.conf"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/redis_password.ctmpl"
  destination          = "/run/secrets/redis_password"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/object_storage_s3.json.ctmpl"
  destination          = "/run/object-storage-secrets/object_storage_s3.json"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/object_storage_admin_access_key.ctmpl"
  destination          = "/run/object-storage-secrets/object_storage_admin_access_key"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}

template {
  source               = "/vault/agent/templates/object_storage_admin_secret_key.ctmpl"
  destination          = "/run/object-storage-secrets/object_storage_admin_secret_key"
  perms                = "0400"
  backup               = false
  error_on_missing_key = true
}
