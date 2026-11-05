#!/usr/bin/env bash
# Write the first value of every secret the stack needs, generated randomly on this server. Never overwrites
# an existing path (re-running is safe). Provider credentials (Click, Payme, BTS, Eskiz, Billz, SMTP, OAuth
# secrets) are added later, at go-live, with scripts/vault/put-secret.sh.
#
#   scripts/vault/generate-app-secrets.sh <env>
#
# Layout (each value stored once; policies in vault/policies/<env>/):
#   secret/<env>/django    every Django secret (keys = environment variable names)       backend
#   secret/<env>/frontend  every Next.js secret (keys = environment variable names)      frontend
#   secret/<env>/shared    INTERNAL_API_SECRET (Django) = GLOWDERMA_INTERNAL_SECRET (Next) backend + frontend
#   secret/<env>/db-app    password of the glowderma_app database role                  backend + datastores
#   secret/<env>/redis     Redis password                                               backend + datastores
#   secret/<env>/postgres  Postgres superuser password                                  datastores only
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
ask_token

# put_new <path> <json>: creates the secret only when it does not exist. The JSON goes through stdin.
put_new() {
	if kv_exists "$ENV/$1"; then
		note "secret/$ENV/$1 exists: kept"
	else
		printf '%s' "$2" | vault_cli kv put -mount=secret "$ENV/$1" - >/dev/null
		note "secret/$ENV/$1 created"
	fi
}

log "Generating secrets for $ENV"
put_new django "$(printf '{"SECRET_KEY":"%s","JWT_SIGNING_KEYS":"{\\"k1\\":\\"%s\\"}","JWT_ACTIVE_KID":"k1","SMS_CODE_HMAC_KEY":"%s","LOG_PII_KEY":"%s","PAYMENT_REF_KEY":"%s","QR_HMAC_KEY":"%s","BTS_WEBHOOK_SECRET":"%s","SECRETBOX_KEY":"%s","CLICK_SECRET_KEY":"%s","PAYME_KEY":"%s"}' \
	"$(rand_b64url 48)" "$(rand_b64url 32)" "$(rand_hex 32)" "$(rand_hex 32)" "$(rand_hex 32)" "$(rand_hex 32)" \
	"$(rand_hex 32)" "$(rand_b64url 32)" "$(rand_hex 16)" "$(rand_hex 16)")"
put_new frontend "$(printf '{"GLOWDERMA_REVALIDATE_SECRET":"%s"}' "$(rand_hex 32)")"
put_new shared "$(printf '{"INTERNAL_API_SECRET":"%s"}' "$(rand_hex 32)")"
put_new db-app "$(printf '{"password":"%s"}' "$(rand_hex 24)")"
put_new redis "$(printf '{"password":"%s"}' "$(rand_hex 24)")"
put_new postgres "$(printf '{"password":"%s"}' "$(rand_hex 24)")"
log "Done. CLICK_SECRET_KEY and PAYME_KEY are random placeholders until the providers issue the real ones."
