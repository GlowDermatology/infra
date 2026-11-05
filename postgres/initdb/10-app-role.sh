#!/bin/sh
# Creates (or updates) the application's database role glowderma_app: owner of the database, NOT a superuser.
#
# Run automatically by the postgres image once, on an empty volume (/docker-entrypoint-initdb.d), and by
# scripts/vault/rotate-db-password.sh after the password changes in Vault. Idempotent. Details: app-role.psql.
# The password comes from the file the Vault agent renders (POSTGRES_APP_PASSWORD_FILE); it never appears in
# the environment, the process list or the logs.
set -eu
file="${POSTGRES_APP_PASSWORD_FILE:?POSTGRES_APP_PASSWORD_FILE is not set (compose/app.yaml)}"
[ -s "$file" ] || { echo "10-app-role.sh: $file is empty (Vault agent not ready?)" >&2; exit 1; }
password="$(cat "$file")"
psql -v ON_ERROR_STOP=1 -q --no-psqlrc \
	--username "${POSTGRES_USER:-glowderma}" --dbname "${POSTGRES_DB:-glowderma}" \
	--set app_password="$password" \
	--file "$(dirname "$0")/app-role.psql"
echo "glowderma_app: role, password and ownership in place"
