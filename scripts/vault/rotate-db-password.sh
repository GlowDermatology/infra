#!/usr/bin/env bash
# Rotate the password of the glowderma_app database role.
#   1. new random password in secret/<env>/db-app
#   2. the agents re-render it for Postgres and Django
#   3. ALTER ROLE inside Postgres (existing connections keep working)
#   4. recreate the Django processes so they connect with the new password
#
#   scripts/vault/rotate-db-password.sh <env>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
ask_token
printf '{"password":"%s"}' "$(rand_hex 24)" | vault_cli kv put -mount=secret "$ENV/db-app" - >/dev/null
restart_agents vault-agent-datastores vault-agent-backend
sleep 5
app_compose exec -T postgres /docker-entrypoint-initdb.d/10-app-role.sh
"$INFRA_DIR/scripts/deploy.sh" "$ENV" --restart backend-api backend-worker backend-beat
log "glowderma_app password rotated"
