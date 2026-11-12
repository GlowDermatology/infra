#!/usr/bin/env bash
# ONE-TIME migration: copy the app settings of environments/<env>/backend.env and frontend.env into Vault, where
# app settings now live (secret/<env>/django and secret/<env>/frontend, next to the secrets). Run it on the
# server, then reload: scripts/restart.sh <env> all (or Actions → Restart). The files come from this checkout,
# or from git history once the commit deleting them is deployed (until the import, the apps run on defaults).
#
#   scripts/vault/import-env.sh <staging|production>
#
# Only keys Vault does not have yet are added (a value already set in Vault wins, as it does at runtime); empty
# values are skipped (unset = the code default). Values are printed: they are public settings, never secrets.
# GLOWDERMA_DATA_SOURCE is skipped: compose/app.yaml sets it for every environment.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"

# env_file_text <backend|frontend>: the file from this checkout, or else from the last commit that had it.
env_file_text() {
	local rel="environments/$ENV/$1.env" rev
	if [ -f "$INFRA_DIR/$rel" ]; then
		cat "$INFRA_DIR/$rel"
		return
	fi
	rev="$(git -c safe.directory="$INFRA_DIR" -C "$INFRA_DIR" log -1 --format=%H -- "$rel")"
	[ -n "$rev" ] || die "$rel exists neither in this checkout nor in its history"
	note "($rel read from git: the version before commit ${rev:0:7})" >&2
	git -c safe.directory="$INFRA_DIR" -C "$INFRA_DIR" show "$rev^:$rel"
}

import() {
	local text path="$2" key value pairs=()
	text="$(env_file_text "$1")"
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		[[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[2]}"
		if [ -z "$value" ] || [ "$key" = GLOWDERMA_DATA_SOURCE ]; then
			note "skip  $key"
		elif vault_cli kv get -mount=secret -field="$key" "$ENV/$path" >/dev/null 2>&1; then
			note "keep  $key (already in Vault)"
		else
			note "add   $key=$value"
			pairs+=("$key=$value")
		fi
	done <<<"$text"
	if [ "${#pairs[@]}" -gt 0 ]; then
		vault_cli kv patch -mount=secret "$ENV/$path" "${pairs[@]}" >/dev/null
	fi
}

ask_token
log "backend.env -> secret/$ENV/django"
import backend django
log "frontend.env -> secret/$ENV/frontend"
import frontend frontend
log "Imported. Load the values now: scripts/restart.sh $ENV all"
