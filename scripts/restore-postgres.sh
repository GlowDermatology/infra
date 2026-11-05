#!/usr/bin/env bash
# Restore the database of one environment from a dump made by backup.sh. DESTRUCTIVE: it replaces every table.
#
#   scripts/restore-postgres.sh <env> <file.dump | file.dump.age>
#
# Asks you to type the environment name, makes a safety dump of the current database first, stops the writers,
# restores in one transaction, then starts the writers again. .age files are decrypted with the identity in
# AGE_IDENTITY_FILE (bring it from the password manager; never leave it on the server).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
dump="${2:-}"
[ -f "$dump" ] || die "usage: scripts/restore-postgres.sh <env> <dump file>"

if [ "${dump%.age}" != "$dump" ]; then
	[ -r "${AGE_IDENTITY_FILE:-}" ] || die "encrypted dump: set AGE_IDENTITY_FILE to the age private key file"
	plain="$(mktemp)"
	trap 'rm -f -- "$plain"' EXIT
	age -d -i "$AGE_IDENTITY_FILE" -o "$plain" "$dump"
	dump="$plain"
fi
app_compose exec -T postgres pg_restore --list >/dev/null <"$dump" || die "$dump is not a readable pg_dump archive"

echo "This REPLACES the $ENV database with $2."
read -r -p "Type the environment name ($ENV) to continue: " answer
[ "$answer" = "$ENV" ] || die "aborted"

log "Safety dump of the current database"
"$INFRA_DIR/scripts/backup.sh" "$ENV" pre-deploy
log "Stopping the writers"
app_compose stop backend-api backend-worker backend-beat
log "Restoring"
app_compose exec -T postgres pg_restore -U glowderma -d glowderma --clean --if-exists --single-transaction \
	--no-owner --role=glowderma_app <"$dump"
log "Starting the writers"
app_compose up -d --wait --wait-timeout 300 backend-api backend-worker backend-beat
"$INFRA_DIR/scripts/healthcheck.sh" "$ENV"
