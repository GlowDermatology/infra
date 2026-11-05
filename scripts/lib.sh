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

# app_compose <compose args...>: the application project of $ENV, with every env file in the right order.
app_compose() {
	local args=(-p "glowderma-$ENV" -f "$INFRA_DIR/compose/app.yaml"
		--env-file "$ENV_DIR/stack.env"
		--env-file "$ENV_DIR/backend/image.env"
		--env-file "$ENV_DIR/frontend/image.env")
	# Host-local, private-but-not-secret values (OPS_ALLOWED_IPS, backup settings). Optional.
	[ -f "$RUNTIME_DIR/local.env" ] && args+=(--env-file "$RUNTIME_DIR/local.env")
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
