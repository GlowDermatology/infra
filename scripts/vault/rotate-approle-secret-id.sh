#!/usr/bin/env bash
# Issue a new AppRole secret_id for one agent, switch the agent to it, then revoke the old one.
#
#   scripts/vault/rotate-approle-secret-id.sh <env> <backend|frontend|datastores>     (run as root)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
role="${2:-}"
declare -A uid=([backend]=10001 [frontend]=1000 [datastores]=999)
[ -n "${uid[$role]:-}" ] || die "role must be backend, frontend or datastores"
[ "$(id -u)" -eq 0 ] || die "run as root"
ask_token
dir="$RUNTIME_DIR/vault/approle/$role"
old_accessor="$(cat "$dir/secret_id_accessor" 2>/dev/null || true)"
json="$(vault_cli write -f -format=json "auth/approle/role/$ENV-$role/secret-id")"
printf '%s' "$json" | sed -n 's/.*"secret_id": "\([^"]*\)".*/\1/p' | tr -d '\n' >"$dir/secret_id.new"
printf '%s' "$json" | sed -n 's/.*"secret_id_accessor": "\([^"]*\)".*/\1/p' | tr -d '\n' >"$dir/secret_id_accessor.new"
unset json
for f in secret_id secret_id_accessor; do
	chown "${uid[$role]}:${uid[$role]}" "$dir/$f.new"
	chmod 0400 "$dir/$f.new"
	mv -f "$dir/$f.new" "$dir/$f"
done
restart_agents "vault-agent-$role"
sleep 10
[ -n "$old_accessor" ] && vault_cli write "auth/approle/role/$ENV-$role/secret-id-accessor/destroy" \
	secret_id_accessor="$old_accessor" >/dev/null
log "$role: secret_id rotated, the old one is revoked"
