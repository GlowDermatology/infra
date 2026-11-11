#!/usr/bin/env bash
# Unseal the Vault of one environment (needed after every Vault or server restart). Asks for key shares until
# Vault is unsealed; the input is hidden. The Vault agents and their consumers recover on their own within a
# minute: nothing else to restart.
#
#   scripts/vault/unseal.sh <env>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
vault_compose up -d --no-recreate --wait --wait-timeout 120 vault
while vault_status_json | grep -q '"sealed": true'; do
	# Interactive: Vault itself prompts with hidden input, so the share never appears on a command line.
	vault_compose exec vault vault operator unseal
done
vault_status_json | grep -q '"sealed": false' || die "Vault ($ENV) does not answer: docker logs glowderma-$ENV-vault-vault-1"
log "Vault ($ENV) is unsealed"
