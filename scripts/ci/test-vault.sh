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
	backend:django | backend:shared | backend:db-app | backend:redis | backend:s3) return 0 ;;
	frontend:frontend | frontend:shared) return 0 ;;
	datastores:postgres | datastores:db-app | datastores:redis | datastores:object-storage | datastores:s3) return 0 ;;
	*) return 1 ;;
	esac
}
for env in staging production; do
	other=$([ "$env" = staging ] && echo production || echo staging)
	for role in backend frontend datastores; do
		dir="$work/rt-$env/vault/approle/$role"
		token="$(VAULT_TOKEN=root "$vault" write -field=token auth/approle/login role_id="$(cat "$dir/role_id")" secret_id="$(cat "$dir/secret_id")")"
		for path in django frontend shared db-app redis postgres s3 object-storage; do
			if VAULT_TOKEN="$token" "$vault" kv get -mount=secret "$env/$path" >/dev/null 2>&1; then got=allow; else got=deny; fi
			if allowed "$role" "$path"; then want=allow; else want=deny; fi
			check "$env $role reads $env/$path: $want" "[ $got = $want ]"
			if VAULT_TOKEN="$token" "$vault" kv get -mount=secret "$other/$path" >/dev/null 2>&1; then got=allow; else got=deny; fi
			check "$env $role cannot read $other/$path" "[ $got = deny ]"
		done
		check "$env $role cannot list secret/" "! VAULT_TOKEN=$token $vault kv list -mount=secret / >/dev/null 2>&1"
	done
done

# generate-app-secrets.sh is idempotent: a second run keeps every existing value (checked on staging).
snapshot() { for p in django s3 object-storage; do VAULT_TOKEN=root "$vault" kv get -format=json -mount=secret "staging/$p" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['data']['data'], sort_keys=True))"; done; }
before="$(snapshot)"
env GLOWDERMA_SKIP_ENV_GUARD=1 RUNTIME_DIR="$work/rt-staging" VAULT_LOCAL_BIN="$vault" VAULT_TOKEN=root 	"$here/scripts/vault/generate-app-secrets.sh" staging >/dev/null
check "a second generate-app-secrets.sh run keeps existing values" "[ \"\$(snapshot)\" = \"\$before\" ]"

# Real agents render every template.
for role in backend frontend datastores; do
	out="$work/out-$role"
	mkdir -p "$out"
	sed -e "s#https://vault:8200#$VAULT_ADDR#" -e '/ca_cert/d' -e 's#static_secret_render_interval = "5m"#static_secret_render_interval = "2s"#' \
		-e "s#/vault/approle#$work/rt-staging/vault/approle/$role#g" \
		-e "s#/vault/agent/templates#$here/vault/agent/templates#g" \
		-e "s#/run/secrets#$out#g" -e "s#/tmp/agent.pid#$work/$role.pid#" \
		"$here/vault/agent/$role.hcl" >"$work/$role.hcl"
	GLOWDERMA_ENV=staging VAULT_TOKEN='' timeout 15 "$vault" agent -config="$work/$role.hcl" >"$work/agent-$role.log" 2>&1 &
done
sleep 8
# a key added later to secret/<env>/s3 reaches django.json at the next render (the test config shortens the
# render interval from 5m to 2s; the templates are the real ones)
VAULT_TOKEN=root "$vault" kv patch -mount=secret staging/s3 PUBLIC_MEDIA_BASE_URL=https://cdn.example.test/media/ >/dev/null
b="$work/out-backend/django.json" f="$work/out-frontend/frontend.json" d="$work/out-datastores"
for _ in $(seq 60); do grep -q PUBLIC_MEDIA_BASE_URL "$b" 2>/dev/null && break; sleep 0.5; done
for p in s3 object-storage; do VAULT_TOKEN=root "$vault" kv get -format=json -mount=secret "staging/$p" >"$work/kv-$p.json"; done
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
check "django.json carries every key of secret/staging/s3 with its value, and no topology key" "python3 -c \"
import json
d = json.load(open('$b'))
s3 = json.load(open('$work/kv-s3.json'))['data']['data']
assert {'S3_ENDPOINT_URL','S3_BUCKET_NAME','S3_REGION_NAME','S3_ADDRESSING_STYLE','S3_ACCESS_KEY_ID','S3_SECRET_ACCESS_KEY','PUBLIC_MEDIA_BASE_URL'} <= set(s3)
assert all(d[k] == v for k, v in s3.items()), [k for k, v in s3.items() if d.get(k) != v]
assert not ({'USE_S3', 'S3_LOCATION'} & set(d))
\""
check "datastores agent renders the 3 object storage files" "[ -s $d/object_storage_s3.json ] && [ -s $d/object_storage_admin_access_key ] && [ -s $d/object_storage_admin_secret_key ]"
check "object_storage_s3.json has the admin, app and anonymous identities" "python3 -c \"
import json
j = json.load(open('$d/object_storage_s3.json'))
s3 = json.load(open('$work/kv-s3.json'))['data']['data']
adm = json.load(open('$work/kv-object-storage.json'))['data']['data']
ids = {i['name']: i for i in j['identities']}
assert list(ids) == ['admin', 'app', 'anonymous'], list(ids)
assert ids['admin']['credentials'] == [{'accessKey': adm['OBJECT_STORAGE_ADMIN_ACCESS_KEY_ID'], 'secretKey': adm['OBJECT_STORAGE_ADMIN_SECRET_ACCESS_KEY']}]
assert ids['admin']['actions'] == ['Admin', 'Read', 'Write', 'List', 'Tagging']
assert ids['app']['credentials'] == [{'accessKey': s3['S3_ACCESS_KEY_ID'], 'secretKey': s3['S3_SECRET_ACCESS_KEY']}]
assert ids['app']['actions'] == ['Read:glowderma-media', 'Write:glowderma-media', 'List:glowderma-media', 'Tagging:glowderma-media']
assert 'credentials' not in ids['anonymous'] and ids['anonymous']['actions'] == ['Read:glowderma-media']
assert open('$d/object_storage_admin_access_key').read() == adm['OBJECT_STORAGE_ADMIN_ACCESS_KEY_ID']
assert open('$d/object_storage_admin_secret_key').read() == adm['OBJECT_STORAGE_ADMIN_SECRET_ACCESS_KEY']
\""
check "rendered files are 0400" "[ \"\$(stat -c %a $b $f $d/redis.conf $d/object_storage_s3.json $d/object_storage_admin_access_key $d/object_storage_admin_secret_key | sort -u)\" = 400 ]"
check "no previous-render backups" "! ls $work/out-*/*.bak* >/dev/null 2>&1"
pkill -f "$work/.*\.hcl" 2>/dev/null || true

# Fail closed: when secret/<env>/object-storage or secret/<env>/s3 is missing (an existing environment where
# generate-app-secrets.sh was not rerun, or a deleted path), the datastores agent must not leave an EMPTY
# object storage file (an empty s3.json could mean open access, an empty admin key a blank credential).
neg_case() { # <label> <env> <path to delete>
	local label="$1" nenv="$2" gone="$3" nout="$work/neg-$1"
	mkdir -p "$nout"
	VAULT_TOKEN=root "$vault" kv metadata delete -mount=secret "$nenv/$gone" >/dev/null
	sed -e "s#https://vault:8200#$VAULT_ADDR#" -e '/ca_cert/d' 		-e "s#/vault/approle#$work/rt-$nenv/vault/approle/datastores#g" 		-e "s#/vault/agent/templates#$here/vault/agent/templates#g" 		-e "s#/run/secrets#$nout#g" -e "s#/tmp/agent.pid#$work/neg-$label.pid#" 		"$here/vault/agent/datastores.hcl" >"$work/neg-$label.hcl"
	GLOWDERMA_ENV="$nenv" VAULT_TOKEN='' "$vault" agent -config="$work/neg-$label.hcl" >"$work/neg-$label.log" 2>&1 &
	sleep 10
	pkill -f "$work/neg-$label.hcl" 2>/dev/null || true
	check "$label: no object storage file is written empty" "python3 -c \"
import os
for n in ('object_storage_s3.json', 'object_storage_admin_access_key', 'object_storage_admin_secret_key'):
    p = '$nout/' + n
    assert not os.path.exists(p) or os.path.getsize(p) > 0, n
\""
	check "$label: object_storage_s3.json is not written at all" "[ ! -e $nout/object_storage_s3.json ]"
	check "$label: the agent reports the missing path (key path only), no secret_id leaked" "grep -q 'no secret exists at secret/data/$nenv/$gone' $work/neg-$label.log && ! grep -qF \"\$(cat $work/rt-$nenv/vault/approle/datastores/secret_id)\" $work/neg-$label.log"
	check "$label: the other datastores files are still rendered and non-empty" "[ -s $nout/postgres_app_password ] && [ -s $nout/postgres_superuser_password ] && [ -s $nout/redis.conf ] && [ -s $nout/redis_password ]"
}
neg_case missing-object-storage production object-storage
neg_case missing-s3 staging s3

echo
[ "$failures" -eq 0 ] || { echo "$failures Vault check(s) failed"; exit 1; }
echo "Vault design: all checks passed"
