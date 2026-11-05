#!/usr/bin/env bash
# Generate the Vault TLS material for one server (run as root). Refuses to overwrite unless --renew, which
# reissues the server certificate with the existing CA (agents keep trusting it).
#
#   scripts/vault/gen-tls.sh <env> [--renew]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
[ "$(id -u)" -eq 0 ] || die "run as root (the key must belong to the vault user, uid 100)"
dir="$RUNTIME_DIR/vault/tls"
install -d -m 0755 "$dir"
cd "$dir" || exit 1
umask 077
if [ ! -s ca.key ]; then
	log "Creating the CA (10 years)"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
		-subj "/CN=glowderma-$ENV-vault-ca" -keyout ca.key -out ca.crt
elif [ -s vault.crt ] && [ "${2:-}" != "--renew" ]; then
	die "TLS material already exists in $dir (use --renew to reissue the server certificate)"
fi
log "Issuing the server certificate (5 years): vault, localhost, 127.0.0.1"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=vault" -keyout vault.key -out vault.csr
printf 'subjectAltName=DNS:vault,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature\n' >ext.cnf
openssl x509 -req -in vault.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1825 -extfile ext.cnf -out vault.crt
rm -f vault.csr ext.cnf ca.srl
chmod 0444 ca.crt vault.crt
chown 100:1000 vault.key && chmod 0400 vault.key
chmod 0400 ca.key
openssl verify -CAfile ca.crt vault.crt
note "Copy ca.key into the offline disaster-recovery kit; it is only needed to reissue vault.crt."
[ "${2:-}" = "--renew" ] && note "Now restart Vault: docker compose -p glowderma-$ENV-vault restart vault, then unseal"
exit 0
