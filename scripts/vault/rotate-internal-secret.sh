#!/usr/bin/env bash
# Rotate INTERNAL_API_SECRET (Django) = GLOWDERMA_INTERNAL_SECRET (Next). One value, one path, both consumers
# restarted together. Expect a few seconds of failed admin-panel calls while the two restart.
#
#   scripts/vault/rotate-internal-secret.sh <env>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
ask_token
printf '{"INTERNAL_API_SECRET":"%s"}' "$(rand_hex 32)" | vault_cli kv put -mount=secret "$ENV/shared" - >/dev/null
restart_agents vault-agent-backend vault-agent-frontend
sleep 5
"$INFRA_DIR/scripts/deploy.sh" "$ENV" --restart backend-api backend-worker backend-beat frontend
log "internal API secret rotated"
