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

# app_compose <compose args...>: the application project of $ENV, with every env file in the right order.
# Exports MEDIA_BACKEND and adds the object-storage profile when OBJECT_STORAGE_ENABLED=true.
app_compose() {
	MEDIA_BACKEND="$(media_backend)"
	export MEDIA_BACKEND
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
# of the datastores agent (no dependencies started; Vault must be unsealed). The token stays inside the container;
# only what `vault kv` prints (a requested field) comes out, errors are discarded.
vault_kv() {
	app_compose run --rm --no-deps -T --entrypoint sh vault-agent-datastores -c '
		set -eu
		export VAULT_ADDR=https://vault:8200 VAULT_CACERT=/vault/tls/ca.crt
		VAULT_TOKEN="$(vault write -field=token auth/approle/login \
			role_id=@/vault/approle/role_id secret_id=@/vault/approle/secret_id)"
		export VAULT_TOKEN
		exec vault kv "$@"' sh "$@" 2>/dev/null
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

# media_preflight: refuses a deploy whose media settings cannot work. Messages name keys, never values.
#   OBJECT_STORAGE_ENABLED or USE_S3 true  -> secret/<env>/s3 must exist (and secret/<env>/object-storage with the
#                                             object storage)
#   USE_S3 true, object storage off        -> an external provider: its endpoint must not be the stack's own
#                                             (host `object-storage`) and PUBLIC_MEDIA_BASE_URL must be set
media_preflight() {
	local storage use_s3 fix endpoint public
	storage="$(stack_value OBJECT_STORAGE_ENABLED)"
	use_s3="$(stack_value USE_S3)"
	[ "$storage" = true ] || [ "$use_s3" = true ] || return 0
	fix="run scripts/vault/generate-app-secrets.sh $ENV first"
	vault_kv metadata get -mount=secret "$ENV/s3" >/dev/null || die "secret/$ENV/s3 is missing: $fix"
	if [ "$storage" = true ]; then
		vault_kv metadata get -mount=secret "$ENV/object-storage" >/dev/null ||
			die "secret/$ENV/object-storage is missing: $fix"
	fi
	if [ "$use_s3" = true ] && [ "$storage" != true ]; then
		endpoint="$(vault_kv get -mount=secret -field=S3_ENDPOINT_URL "$ENV/s3" || true)"
		public="$(vault_kv get -mount=secret -field=PUBLIC_MEDIA_BASE_URL "$ENV/s3" || true)"
		[ "$(url_host "$endpoint")" != object-storage ] ||
			die "USE_S3 points at the stack's object storage but OBJECT_STORAGE_ENABLED=false"
		[ -n "$public" ] || die "an external provider needs PUBLIC_MEDIA_BASE_URL in secret/$ENV/s3"
	fi
}
