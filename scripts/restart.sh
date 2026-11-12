#!/usr/bin/env bash
# Reload an app's settings and secrets from Vault: re-render its Vault Agent file, recreate the app, check health.
# Run it after changing secret/<env>/django or secret/<env>/frontend (Vault UI, `vault kv patch`, put-secret.sh).
# The Restart workflow runs it through the deploy gate; on the server it is also safe to run by hand.
#
#   scripts/restart.sh <staging|production> <backend|frontend|all>
#
# Order matters. The rendered file lives in a tmpfs volume that survives an agent restart, so the old file is
# removed first; the agent is healthy again only once it has rendered a fresh one from Vault, and only then are
# the apps recreated (they read the file at start). Refuses while Vault is sealed, before touching anything.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

use_env "${1:-}"
target="${2:-}"
case "$target" in
backend) agents=(vault-agent-backend) services=(backend-api backend-worker backend-beat) ;;
frontend) agents=(vault-agent-frontend) services=(frontend) ;;
all)
	agents=(vault-agent-backend vault-agent-frontend)
	services=(backend-api backend-worker backend-beat frontend)
	;;
*) die "usage: restart.sh <env> <backend|frontend|all>" ;;
esac

set +e
vault_compose exec -T vault vault status >/dev/null 2>&1
vault_status=$?
set -e
case $vault_status in
0) note "Vault: unsealed" ;;
2) die "Vault is SEALED: nothing restarted. Unseal it first: scripts/vault/unseal.sh $ENV" ;;
*) die "Vault does not answer: nothing restarted. scripts/healthcheck.sh $ENV" ;;
esac

log "Re-rendering ${agents[*]} ($ENV)"
for agent in "${agents[@]}"; do
	case "$agent" in
	vault-agent-backend) file=/run/secrets/django.json ;;
	vault-agent-frontend) file=/run/secrets/frontend.json ;;
	esac
	app_compose exec -T "$agent" rm -f "$file"
done
app_compose restart "${agents[@]}" >/dev/null
app_compose up -d --no-deps --wait --wait-timeout 180 "${agents[@]}" ||
	die "${agents[*]} rendered nothing within 3 minutes (a key missing, AppRole refused?): docker logs glowderma-$ENV-${agents[0]}-1"

"$INFRA_DIR/scripts/deploy.sh" "$ENV" --restart "${services[@]}"
"$INFRA_DIR/scripts/healthcheck.sh" "$ENV"
log "Restarted ${services[*]} ($ENV) with the current Vault values"
