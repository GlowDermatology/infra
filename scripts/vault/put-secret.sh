#!/usr/bin/env bash
# Add or change ONE key of a secret, typing the value at a hidden prompt (it never reaches a command line or
# the shell history). Then makes the consumers pick it up.
#
#   scripts/vault/put-secret.sh <env> <django|frontend> <KEY>
#   example: scripts/vault/put-secret.sh production django ESKIZ_PASSWORD
#
# Shared and infrastructure credentials have their own rotation scripts (rotate-*.sh).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
path="${2:-}"
key="${3:-}"
case "$path" in django | frontend) ;; *) die "usage: put-secret.sh <env> <django|frontend> <KEY>" ;; esac
[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "KEY must look like an environment variable name (got '$key')"
ask_token
read -rsp "Value for $key: " value
echo
[ -n "$value" ] || die "empty value"
printf '%s' "$value" | vault_cli kv patch -mount=secret "$ENV/$path" "$key=-" >/dev/null
unset value
if [ "$path" = django ]; then
	restart_agents vault-agent-backend
	"$INFRA_DIR/scripts/deploy.sh" "$ENV" --restart backend-api backend-worker backend-beat
else
	restart_agents vault-agent-frontend
	"$INFRA_DIR/scripts/deploy.sh" "$ENV" --restart frontend
fi
log "secret/$ENV/$path $key updated and loaded"
