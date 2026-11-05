#!/usr/bin/env bash
# Helpers for scripts/vault/*.sh. Every Vault command runs INSIDE the Vault container (TLS verified against our
# CA, address 127.0.0.1): the API is never published, and no Vault CLI is needed on the host.
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# vault_cli <vault args...>: the vault CLI in the server container. VAULT_TOKEN is passed by name only, so its
# value never shows in the host's process list.
vault_cli() {
	# Tests only (scripts/vault/test-scripts.sh): a local vault binary against a dev server.
	if [ -n "${VAULT_LOCAL_BIN:-}" ]; then
		"$VAULT_LOCAL_BIN" "$@"
		return
	fi
	if [ -n "${VAULT_TOKEN:-}" ]; then
		vault_compose exec -T -e VAULT_TOKEN vault vault "$@"
	else
		vault_compose exec -T vault vault "$@"
	fi
}

# ask_token: prompts for an admin token (the root token right after init, later a token you create for the
# task). Never stored anywhere.
ask_token() {
	if [ -z "${VAULT_TOKEN:-}" ]; then
		read -rsp "Vault admin token: " VAULT_TOKEN
		echo
	fi
	[ -n "$VAULT_TOKEN" ] || die "a Vault token is required"
	export VAULT_TOKEN
}

# kv_exists <path below secret/>: exit 0 when the secret exists.
kv_exists() { vault_cli kv metadata get -mount=secret "$1" >/dev/null 2>&1; }

# Random values (printed only into pipes, never on a command line).
rand_hex() { openssl rand -hex "$1"; }
rand_b64url() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'; }

# restart_agents <service...>: agents re-render on start; their consumers keep the shared memory volume.
restart_agents() { app_compose restart "$@" >/dev/null; }
