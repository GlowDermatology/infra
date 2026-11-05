#!/usr/bin/env bash
# Configure the Vault of one environment (run as root: it writes the AppRole files owned by the agents' UIDs).
# Idempotent: re-run after changing vault/policies/<env>/. Existing AppRole credentials are kept.
#
#   scripts/vault/configure.sh <env>
#
# Sets up: KV v2 at secret/, the file audit device, the policies, AppRole auth with one role per agent
# (backend, frontend, datastores), their role_id/secret_id files, and a snapshot-only token for backups.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
[ "$(id -u)" -eq 0 ] || die "run as root"
ask_token

log "KV v2 secrets engine at secret/"
vault_cli secrets list -format=json | grep -q '"secret/"' || vault_cli secrets enable -path=secret -version=2 kv

log "Audit device (file, /vault/logs/audit.log in the vault-logs volume)"
vault_cli audit list -format=json 2>/dev/null | grep -q '"file/"' ||
	vault_cli audit enable file file_path="${AUDIT_FILE_PATH:-/vault/logs/audit.log}"

log "Policies from vault/policies/$ENV/"
for policy in backend frontend datastores; do
	vault_cli policy write "$ENV-$policy" - <"$INFRA_DIR/vault/policies/$ENV/$policy.hcl" >/dev/null
done
printf 'path "sys/storage/raft/snapshot" { capabilities = ["read"] }\n' |
	vault_cli policy write "$ENV-snapshot" - >/dev/null

log "AppRole auth and one role per agent"
vault_cli auth list -format=json | grep -q '"approle/"' || vault_cli auth enable approle
declare -A uid=([backend]=10001 [frontend]=1000 [datastores]=999)
for role in backend frontend datastores; do
	vault_cli write "auth/approle/role/$ENV-$role" token_policies="$ENV-$role" \
		token_ttl=1h token_max_ttl=24h secret_id_ttl=0 secret_id_num_uses=0 token_no_default_policy=true >/dev/null
	dir="$RUNTIME_DIR/vault/approle/$role"
	install -d -m 0500 -o "${uid[$role]}" -g "${uid[$role]}" "$dir"
	if [ ! -s "$dir/secret_id" ]; then
		vault_cli read -field=role_id "auth/approle/role/$ENV-$role/role-id" >"$dir/role_id"
		vault_cli write -f -format=json "auth/approle/role/$ENV-$role/secret-id" >"$dir/.new.json"
		sed -n 's/.*"secret_id": "\([^"]*\)".*/\1/p' "$dir/.new.json" | tr -d '\n' >"$dir/secret_id"
		sed -n 's/.*"secret_id_accessor": "\([^"]*\)".*/\1/p' "$dir/.new.json" | tr -d '\n' >"$dir/secret_id_accessor"
		rm -f "$dir/.new.json"
		chown "${uid[$role]}:${uid[$role]}" "$dir"/role_id "$dir"/secret_id "$dir"/secret_id_accessor
		chmod 0400 "$dir"/role_id "$dir"/secret_id "$dir"/secret_id_accessor
		note "$role: new AppRole credentials written to $dir"
	else
		note "$role: credentials already present (scripts/vault/rotate-approle-secret-id.sh to rotate)"
	fi
done

log "Snapshot token for the nightly backup"
token_file="$RUNTIME_DIR/vault/snapshot-token"
if [ ! -s "$token_file" ]; then
	install -m 0400 -o "${DEPLOY_USER:-deploy}" -g "${DEPLOY_USER:-deploy}" /dev/null "$token_file"
	vault_cli token create -policy="$ENV-snapshot" -no-default-policy -orphan -period=768h -field=token >"$token_file"
	note "written to $token_file (renewed by every nightly backup)"
fi
log "Configured. Next: scripts/vault/generate-app-secrets.sh $ENV"
