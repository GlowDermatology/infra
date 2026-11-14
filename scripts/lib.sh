#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it; never run it.
#
# The one rule: a server knows which environment it is (/etc/glowderma/environment, written by
# bootstrap-server.sh). Every script takes the environment as its first argument and refuses to run when the
# two differ, so a staging command can never touch production by accident.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-/opt/glowderma/runtime}"
export RUNTIME_DIR

die() {
	echo "ERROR: $*" >&2
	exit 1
}
log() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# use_env <env>: validates the argument and the server's own environment, then sets ENV.
use_env() {
	local env="${1:-}"
	case "$env" in
	staging | production) ;;
	*) die "first argument must be the environment: staging or production (got '${env}')" ;;
	esac
	local server_env=""
	[ -r /etc/glowderma/environment ] && server_env="$(tr -d '[:space:]' </etc/glowderma/environment)"
	if [ "${GLOWDERMA_SKIP_ENV_GUARD:-}" != "1" ] && [ "$server_env" != "$env" ]; then
		die "this server is '${server_env:-not bootstrapped}' (/etc/glowderma/environment); refusing to act on '$env'"
	fi
	ENV="$env"
	ENV_DIR="$INFRA_DIR/environments/$ENV"
	export ENV ENV_DIR
}

# media_backend: where Caddy serves /media from. `object-storage` only when the stack runs SeaweedFS AND Django
# stores media in S3; otherwise `disk` (an external S3 provider is public through its own URL).
media_backend() {
	if [ "$(stack_value OBJECT_STORAGE_ENABLED)" = true ] && [ "$(stack_value USE_S3)" = true ]; then
		echo object-storage
	else
		echo disk
	fi
}

# agent_config_hash: a short hash of every file under vault/agent/ (configs and templates). compose/app.yaml puts it
# in a label of the Vault Agent services: the directory is bind-mounted, so without it a changed template would
# never reach an agent that is already running (`up` sees no change and does not recreate it).
agent_config_hash() {
	(cd "$INFRA_DIR" && find vault/agent -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) |
		sha256sum | cut -c1-16
}

# app_compose <compose args...>: the application project of $ENV, with every env file in the right order.
# Exports MEDIA_BACKEND and VAULT_AGENT_CONFIG_HASH, and adds the object-storage profile when
# OBJECT_STORAGE_ENABLED=true.
app_compose() {
	MEDIA_BACKEND="$(media_backend)"
	VAULT_AGENT_CONFIG_HASH="$(agent_config_hash)"
	export MEDIA_BACKEND VAULT_AGENT_CONFIG_HASH
	local args=(-p "glowderma-$ENV" -f "$INFRA_DIR/compose/app.yaml"
		--env-file "$ENV_DIR/stack.env"
		--env-file "$ENV_DIR/backend/image.env"
		--env-file "$ENV_DIR/frontend/image.env")
	# Host-local, private-but-not-secret values (OPS_ALLOWED_IPS, backup settings). Optional.
	[ -f "$RUNTIME_DIR/local.env" ] && args+=(--env-file "$RUNTIME_DIR/local.env")
	[ "$(stack_value OBJECT_STORAGE_ENABLED)" = true ] && args+=(--profile object-storage)
	docker compose "${args[@]}" "$@"
}

# vault_compose <compose args...>: the Vault project of $ENV (separate lifecycle).
vault_compose() {
	docker compose -p "glowderma-$ENV-vault" -f "$INFRA_DIR/compose/vault.yaml" \
		--env-file "$ENV_DIR/stack.env" "$@"
}

# image_value <backend|frontend> <TAG|DIGEST|SOURCE_SHA|...>: one value from environments/<env>/<app>/image.env.
image_value() {
	local app="$1" key="$2" upper
	upper="$(echo "$app" | tr '[:lower:]' '[:upper:]')"
	sed -n "s/^${upper}_${key}=//p" "$ENV_DIR/$app/image.env" | tail -n 1
}

# stack_value <KEY>: one value from environments/<env>/stack.env.
stack_value() { sed -n "s/^$1=//p" "$ENV_DIR/stack.env" | tail -n 1; }

# local_value <KEY>: one value from runtime/local.env (empty when absent).
local_value() {
	[ -f "$RUNTIME_DIR/local.env" ] || return 0
	sed -n "s/^$1=//p" "$RUNTIME_DIR/local.env" | tail -n 1 | sed -e 's/^"//' -e 's/"$//'
}

# vault_kv <vault kv args...>: `vault kv ...` as the datastores AppRole (it may read secret/<env>/s3 and
# secret/<env>/object-storage). The deploy user cannot read the AppRole files, so this runs in a one-off container
# of the datastores agent (no dependencies started; Vault must be unsealed). The token stays inside the container
# and is revoked right after the read (never printed); only what `vault kv` prints (a requested field) comes out;
# vault's errors (no secret values) stay on stderr.
vault_kv() {
	app_compose run --rm --no-deps -T --entrypoint sh vault-agent-datastores -c '
		set -eu
		export VAULT_ADDR=https://vault:8200 VAULT_CACERT=/vault/tls/ca.crt
		VAULT_TOKEN="$(vault write -field=token auth/approle/login \
			role_id=@/vault/approle/role_id secret_id=@/vault/approle/secret_id)"
		export VAULT_TOKEN
		rc=0
		vault kv "$@" || rc=$?
		vault token revoke -self >/dev/null 2>&1 ||
			echo "vault_kv: revoking the one-off token failed (it expires with its TTL)" >&2
		exit "$rc"' sh "$@"
}

# url_host <url>: the lower-case host of a URL (no scheme, credentials, port, path or trailing dot).
url_host() {
	local rest="${1#*://}"
	rest="${rest%%[/?#]*}"
	rest="${rest##*@}"
	rest="${rest%%:*}"
	rest="${rest%.}"
	printf '%s' "$rest" | tr '[:upper:]' '[:lower:]'
}

# secret_must_exist <path below secret/<env>/> <field that always exists>: dies unless the secret is readable by the
# datastores role. Reads the field through the data path (the only one its policy grants), never printing it.
# Vault exits 2 for every API error (404 and 403 alike), so only its "No value found" message means "missing";
# anything else (compose, image pull, login denied, sealed Vault) is reported as a failed read.
secret_must_exist() {
	local rc=0 err
	err="$(vault_kv get -mount=secret -field="$2" "$ENV/$1" 2>&1 >/dev/null)" || rc=$?
	[ "$rc" -ne 0 ] || return 0
	case "$err" in
	*"No value found"*) die "secret/$ENV/$1 is missing: run scripts/vault/generate-app-secrets.sh $ENV first" ;;
	esac
	echo "$err" >&2
	die "reading secret/$ENV/$1 from Vault failed (exit $rc)"
}

# s3_endpoint_host: the host of S3_ENDPOINT_URL in secret/<env>/s3 (empty when the key is not set). Call it after
# secret_must_exist s3: the secret is then readable, so a failing field read means the optional key is absent. The
# value is only compared, never printed.
s3_endpoint_host() {
	url_host "$(vault_kv get -mount=secret -field=S3_ENDPOINT_URL "$ENV/s3" 2>/dev/null || true)"
}

# own_storage_endpoint_check: with MEDIA_BACKEND=object-storage, /media and the nightly mirror use the stack's own
# bucket, so Django must use it too: dies unless S3_ENDPOINT_URL in secret/<env>/s3 has the host `object-storage`.
# Call it after secret_must_exist s3 (as s3_endpoint_host).
own_storage_endpoint_check() {
	[ "$(s3_endpoint_host)" = object-storage ] ||
		die "OBJECT_STORAGE_ENABLED=true and USE_S3=true, but S3_ENDPOINT_URL in secret/$ENV/s3 is not the stack's object
       storage (host object-storage): /media and the backups would follow the stack's bucket while Django writes
       elsewhere. To use another provider, set OBJECT_STORAGE_ENABLED=false in stack.env (docs/deployment.md)."
}

# check_media_storage <what to do on failure>: with USE_S3=true, Django must really use the bucket
# (manage.py media_storage_check in the running backend-api). Dies with its output otherwise.
check_media_storage() {
	[ "$(stack_value USE_S3)" = true ] || return 0
	log "Checking the media storage"
	local out
	if ! out="$(app_compose exec -T backend-api python manage.py media_storage_check 2>&1)"; then
		echo "$out" >&2
		die "media_storage_check failed: Django cannot use the bucket (secret/$ENV/s3). $1"
	fi
	note "$out"
}

# media_preflight: refuses a deploy (or a backend restart) whose media settings cannot work. Messages name keys,
# never values.
#   always                             -> secret/<env>/s3 must exist: django.json renders it in every mode
#   OBJECT_STORAGE_ENABLED true        -> secret/<env>/object-storage must exist too
#   USE_S3 true, object storage on     -> S3_ENDPOINT_URL must be the stack's own (host `object-storage`)
#   USE_S3 true, object storage off    -> an external provider: its endpoint must not be the stack's own and
#                                         PUBLIC_MEDIA_BASE_URL must be set
media_preflight() {
	local storage use_s3 public
	storage="$(stack_value OBJECT_STORAGE_ENABLED)"
	use_s3="$(stack_value USE_S3)"
	secret_must_exist s3 S3_BUCKET_NAME
	[ "$storage" != true ] || secret_must_exist object-storage OBJECT_STORAGE_ADMIN_ACCESS_KEY_ID
	[ "$use_s3" = true ] || return 0
	if [ "$storage" = true ]; then
		own_storage_endpoint_check
		return 0
	fi
	public="$(vault_kv get -mount=secret -field=PUBLIC_MEDIA_BASE_URL "$ENV/s3" 2>/dev/null || true)"
	[ "$(s3_endpoint_host)" != object-storage ] ||
		die "USE_S3 points at the stack's object storage but OBJECT_STORAGE_ENABLED=false"
	[ -n "$public" ] || die "an external provider needs PUBLIC_MEDIA_BASE_URL in secret/$ENV/s3"
}
