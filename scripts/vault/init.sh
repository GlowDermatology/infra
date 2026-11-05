#!/usr/bin/env bash
# Initialise the Vault of one environment. ONCE per Vault, ever: refuses an initialised Vault.
#
#   scripts/vault/init.sh <env>
#
# Prints 5 unseal key shares (3 needed to unseal) and the initial root token ONE time. Store them offline, in
# separate places (password manager entries of different people). They are never written to disk here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
[ -s "$RUNTIME_DIR/vault/tls/vault.key" ] || die "no TLS material: run scripts/vault/gen-tls.sh $ENV (as root) first"
vault_compose up -d --no-recreate --wait --wait-timeout 120 vault
if vault_cli status -format=json 2>/dev/null | grep -q '"initialized": true'; then
	die "this Vault is already initialised. Never initialise twice (it would mean starting from empty storage)."
fi
read -r -p "Initialise the $ENV Vault now? Type '$ENV' to continue: " answer
[ "$answer" = "$ENV" ] || die "aborted"
echo
echo "############################################################################################"
echo "#  The values below are shown ONCE. Store every unseal key and the root token offline NOW.  #"
echo "############################################################################################"
vault_cli operator init -key-shares=5 -key-threshold=3
echo
echo "Next: scripts/vault/unseal.sh $ENV, then (as root) scripts/vault/configure.sh $ENV"
