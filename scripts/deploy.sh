#!/usr/bin/env bash
# Deploy the release described by this checkout of the infra repo.
#
#   scripts/deploy.sh <staging|production>                      normal deploy (what the workflows run)
#   scripts/deploy.sh <env> --restart <service>...              recreate services in place (after a secret rotation)
#
# What a deploy does, in order (any failure stops with a non-zero exit and diagnostics):
#   1. guards: right server, both images published, Vault material present, Compose file valid
#   2. Vault: started if not running (never recreated), must be unsealed; media settings in Vault checked
#   3. pull every image by digest
#   4. if the backend image changes: pre-deploy database dump, stop the writers, run migrations (one process)
#      With OBJECT_STORAGE_ENABLED=true the object storage starts here and its bucket is created.
#   5. `up -d` the whole stack and wait until every service is healthy
#   6. reload Caddy (zero downtime), smoke test, media_storage_check (USE_S3=true), record what is deployed, prune old images
#
# Needs Docker Compose >= 2.20 on the server (`depends_on ... required: false` for the optional object storage).
# Never destructive: no `down`, no `-v`, no volume or network removal. Rolling back = deploying an older
# image.env (promote workflow or `git revert`), plus a database restore if a migration has to be undone.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

use_env "${1:-}"
shift

if [ "${1:-}" = "--restart" ]; then
	shift
	[ "$#" -gt 0 ] || die "--restart needs at least one service name"
	log "Recreating $* ($ENV)"
	app_compose up -d --no-deps --force-recreate --wait --wait-timeout 300 "$@"
	exit 0
fi
[ "$#" -eq 0 ] || die "unknown arguments: $*"

log "Deploying $ENV from infra commit $(git -C "$INFRA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# 1. guards -------------------------------------------------------------------------------------------------
missing=""
for app in backend frontend; do
	[ -n "$(image_value "$app" DIGEST)" ] || missing="$missing $app"
done
if [ -n "$missing" ]; then
	note "No image published yet for:$missing. Nothing to deploy until both pipelines have run once."
	exit 0
fi
for app in backend frontend; do
	note "$app: $(image_value "$app" TAG) @ $(image_value "$app" DIGEST)"
done
for file in vault/tls/ca.crt vault/tls/vault.crt vault/tls/vault.key \
	vault/approle/backend/secret_id vault/approle/frontend/secret_id vault/approle/datastores/secret_id; do
	dir="$(dirname "$RUNTIME_DIR/$file")"
	[ -d "$dir" ] || die "$dir is missing: finish docs/first-server-runbook.md first"
	# The AppRole directories are 0500 and owned by the agent's UID: the deploy user cannot look inside. Their
	# files are then checked by the agents' healthchecks (step 4 waits for every agent to render).
	[ -x "$dir" ] || continue
	[ -s "$RUNTIME_DIR/$file" ] || die "$RUNTIME_DIR/$file is missing: finish docs/first-server-runbook.md first"
done
app_compose config --quiet || die "compose/app.yaml does not resolve for $ENV"

# 2. Vault (independent lifecycle: started when stopped, never recreated) ----------------------------------
if [ -z "$(vault_compose ps --status running -q vault 2>/dev/null)" ]; then
	log "Vault is not running: starting it"
	vault_compose up -d --no-recreate --wait --wait-timeout 120 vault
fi
set +e
vault_compose exec -T vault vault status >/dev/null 2>&1
vault_status=$?
set -e
case $vault_status in
0) note "Vault: unsealed" ;;
2) die "Vault is SEALED. Unseal it first: scripts/vault/unseal.sh $ENV (then re-run this deploy)" ;;
*) die "Vault does not answer: scripts/healthcheck.sh $ENV; docker logs glowderma-$ENV-vault-vault-1" ;;
esac

# Media settings: secret/<env>/s3 (and object-storage) present, an external provider fully configured.
media_preflight

# 3. pull ---------------------------------------------------------------------------------------------------
log "Pulling images"
app_compose pull --quiet --ignore-buildable
app_compose --profile tools pull --quiet backend-migrate
if [ "$(stack_value OBJECT_STORAGE_ENABLED)" = true ]; then
	app_compose --profile object-storage-tools pull --quiet object-storage-init
fi

# 4. database migrations (only when the backend changes) ----------------------------------------------------
mkdir -p "$RUNTIME_DIR/deployed"
backend_digest="$(image_value backend DIGEST)"
previous_backend="$(cat "$RUNTIME_DIR/deployed/backend.digest" 2>/dev/null || true)"

log "Starting secrets and datastores"
app_compose up -d --wait --wait-timeout 300 \
	vault-agent-backend vault-agent-frontend vault-agent-datastores postgres redis

if [ "$(stack_value OBJECT_STORAGE_ENABLED)" = true ]; then
	log "Starting the object storage and creating the media bucket"
	app_compose up -d --wait --wait-timeout 300 object-storage
	app_compose --profile object-storage-tools run --rm --no-deps object-storage-init ||
		die "object storage bucket setup failed (keys in secret/$ENV/object-storage; docker logs of the object-storage service)"
fi

if [ "$backend_digest" != "$previous_backend" ]; then
	if [ -n "$previous_backend" ]; then
		log "Backend changes: pre-deploy database dump"
		"$INFRA_DIR/scripts/backup.sh" "$ENV" pre-deploy
		log "Stopping the writers (api, worker, beat) for the migrations"
		app_compose stop backend-api backend-worker backend-beat
	fi
	log "Running migrations"
	app_compose --profile tools run --rm --no-deps backend-migrate ||
		die "migrations failed. The writers are stopped; the previous release is NOT running.
       Fix forward (new image), or restore the pre-deploy dump: scripts/restore-postgres.sh $ENV <dump>"
else
	note "Backend unchanged: no migrations"
fi

# 5. start everything ---------------------------------------------------------------------------------------
log "Starting the release"
if ! app_compose up -d --remove-orphans --wait --wait-timeout 600; then
	app_compose ps -a
	for service in backend-api backend-worker frontend edge; do
		echo "--- last log lines of $service"
		app_compose logs --no-color --tail 40 "$service" 2>&1 || true
	done
	die "the release did not become healthy"
fi

# 6. finish -------------------------------------------------------------------------------------------------
app_compose exec -T edge caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
"$INFRA_DIR/scripts/healthcheck.sh" "$ENV"

# Media in S3: Django must really use the bucket before this release counts as deployed.
if [ "$(stack_value USE_S3)" = true ]; then
	log "Checking the media storage"
	if ! check_out="$(app_compose exec -T backend-api python manage.py media_storage_check 2>&1)"; then
		echo "$check_out" >&2
		die "media_storage_check failed: Django cannot use the bucket (secret/$ENV/s3). Roll back: docs/deployment.md"
	fi
	note "$check_out"
fi

printf '%s\n' "$backend_digest" >"$RUNTIME_DIR/deployed/backend.digest"
image_value frontend DIGEST >"$RUNTIME_DIR/deployed/frontend.digest"
printf '%s infra=%s backend=%s frontend=%s\n' "$(date -u +%FT%TZ)" \
	"$(git -C "$INFRA_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
	"$(image_value backend TAG)" "$(image_value frontend TAG)" >>"$RUNTIME_DIR/deployed/history.log"

# Unused images older than a week (a rollback pulls its image again by digest).
docker image prune -af --filter "until=168h" >/dev/null || true
log "Deployed $ENV: backend $(image_value backend TAG), frontend $(image_value frontend TAG)"
