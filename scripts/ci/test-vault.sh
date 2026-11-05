#!/usr/bin/env bash
# End-to-end test of the Vault design, without Docker: a throwaway `vault server -dev`, the real
# scripts/vault/configure.sh and generate-app-secrets.sh for BOTH environments, the negative authorization
# matrix, and a real Vault Agent per role rendering every template from vault/agent/.
#
#   VAULT_BIN=/path/to/vault scripts/ci/test-vault.sh        (CI copies the binary out of the pinned image)
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
vault="${VAULT_BIN:-vault}"
work="$(mktemp -d)"
port=18299
export VAULT_ADDR="http://127.0.0.1:$port"
"$vault" server -dev -dev-root-token-id=root -dev-listen-address="127.0.0.1:$port" >"$work/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 50); do VAULT_TOKEN=root "$vault" status >/dev/null 2>&1 && break; sleep 0.2; done
VAULT_TOKEN=root "$vault" secrets disable secret >/dev/null # production starts without the dev KV mount

failures=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi; }

for env in staging production; do
	rt="$work/rt-$env"
	mkdir -p "$rt"
	env GLOWDERMA_SKIP_ENV_GUARD=1 RUNTIME_DIR="$rt" VAULT_LOCAL_BIN="$vault" VAULT_TOKEN=root \
		DEPLOY_USER="$(id -un)" AUDIT_FILE_PATH="$work/audit-$env.log" "$here/scripts/vault/configure.sh" "$env" >/dev/null
	env GLOWDERMA_SKIP_ENV_GUARD=1 RUNTIME_DIR="$rt" VAULT_LOCAL_BIN="$vault" VAULT_TOKEN=root \
		"$here/scripts/vault/generate-app-secrets.sh" "$env" >/dev/null
done

# Authorization matrix: exactly these reads are allowed, everything else (including every cross-environment
# read) is denied.
allowed() {
	case "$1:$2" in
	backend:django | backend:shared | backend:db-app | backend:redis) return 0 ;;
	frontend:frontend | frontend:shared) return 0 ;;
	datastores:postgres | datastores:db-app | datastores:redis) return 0 ;;
	*) return 1 ;;
	esac
}
for env in staging production; do
	other=$([ "$env" = staging ] && echo production || echo staging)
	for role in backend frontend datastores; do
		dir="$work/rt-$env/vault/approle/$role"
		token="$(VAULT_TOKEN=root "$vault" write -field=token auth/approle/login role_id="$(cat "$dir/role_id")" secret_id="$(cat "$dir/secret_id")")"
		for path in django frontend shared db-app redis postgres; do
			if VAULT_TOKEN="$token" "$vault" kv get -mount=secret "$env/$path" >/dev/null 2>&1; then got=allow; else got=deny; fi
			if allowed "$role" "$path"; then want=allow; else want=deny; fi
			check "$env $role reads $env/$path: $want" "[ $got = $want ]"
			if VAULT_TOKEN="$token" "$vault" kv get -mount=secret "$other/$path" >/dev/null 2>&1; then got=allow; else got=deny; fi
			check "$env $role cannot read $other/$path" "[ $got = deny ]"
		done
		check "$env $role cannot list secret/" "! VAULT_TOKEN=$token $vault kv list -mount=secret / >/dev/null 2>&1"
	done
done

# Real agents render every template.
for role in backend frontend datastores; do
	out="$work/out-$role"
	mkdir -p "$out"
	sed -e "s#https://vault:8200#$VAULT_ADDR#" -e '/ca_cert/d' \
		-e "s#/vault/approle#$work/rt-staging/vault/approle/$role#g" \
		-e "s#/vault/agent/templates#$here/vault/agent/templates#g" \
		-e "s#/run/secrets#$out#g" -e "s#/tmp/agent.pid#$work/$role.pid#" \
		"$here/vault/agent/$role.hcl" >"$work/$role.hcl"
	GLOWDERMA_ENV=staging VAULT_TOKEN='' timeout 15 "$vault" agent -config="$work/$role.hcl" >"$work/agent-$role.log" 2>&1 &
done
sleep 8
b="$work/out-backend/django.json" f="$work/out-frontend/frontend.json" d="$work/out-datastores"
check "django.json is valid JSON with the required keys" "python3 -c \"
import json; d = json.load(open('$b'))
need = {'SECRET_KEY','JWT_SIGNING_KEYS','JWT_ACTIVE_KID','INTERNAL_API_SECRET','POSTGRES_PASSWORD','REDIS_URL',
        'CELERY_BROKER_URL','SMS_CODE_HMAC_KEY','SECRETBOX_KEY','CLICK_SECRET_KEY','PAYME_KEY'}
assert need <= set(d), need - set(d)
assert all(isinstance(v, str) and v for v in d.values())
\""
check "frontend.json holds the same internal secret as django.json" "python3 -c \"
import json; a = json.load(open('$b')); b = json.load(open('$f'))
assert a['INTERNAL_API_SECRET'] == b['GLOWDERMA_INTERNAL_SECRET'] and b['GLOWDERMA_REVALIDATE_SECRET']
\""
check "Postgres app password = Django POSTGRES_PASSWORD" "python3 -c \"
import json; assert json.load(open('$b'))['POSTGRES_PASSWORD'] == open('$d/postgres_app_password').read()
\""
check "Redis password in redis.conf and REDIS_URL" "grep -q \"^requirepass \$(cat $d/redis_password)\$\" $d/redis.conf && grep -q \"\$(cat $d/redis_password)@redis\" $b"
check "rendered files are 0400" "[ \"\$(stat -c %a $b $f $d/redis.conf | sort -u)\" = 400 ]"
check "no previous-render backups" "! ls $work/out-*/*.bak* >/dev/null 2>&1"
pkill -f "$work/.*\.hcl" 2>/dev/null || true

echo
[ "$failures" -eq 0 ] || { echo "$failures Vault check(s) failed"; exit 1; }
echo "Vault design: all checks passed"
