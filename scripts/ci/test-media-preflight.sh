#!/usr/bin/env bash
# Cases of media_preflight (scripts/lib.sh) with the Vault read stubbed: no Docker, no Vault.
#
#   scripts/ci/test-media-preflight.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GLOWDERMA_SKIP_ENV_GUARD=1
# shellcheck source=../lib.sh
source "$here/scripts/lib.sh"
use_env staging
ENV_DIR="$work"
export ENV_DIR

# Distinctive values: none of them may ever appear in the output.
SECRET_ENDPOINT_MARK=endpoint-mark-7f3a
SECRET_PUBLIC_MARK=public-mark-91bc

# The stub answers the exact commands media_preflight runs (scripts/ci/test-vault.sh runs the same ones against a
# real Vault). STUB_S3 / STUB_OS: present | missing (exit 2 + vault's "No value found") | error (exit 2, another message).
vault_kv() {
	local state
	case "$*" in
	"get -mount=secret -field=S3_BUCKET_NAME staging/s3") state="$STUB_S3"; [ "$state" != present ] || { printf "%s" "${STUB_BUCKET:-glowderma-media}"; return 0; } ;;
	"get -mount=secret -field=OBJECT_STORAGE_ADMIN_ACCESS_KEY_ID staging/object-storage") state="$STUB_OS" ;;
	"get -mount=secret -field=S3_ENDPOINT_URL staging/s3") printf '%s' "$STUB_ENDPOINT"; return 0 ;;
	"get -mount=secret -field=PUBLIC_MEDIA_BASE_URL staging/s3") [ -n "$STUB_PUBLIC" ] && printf '%s' "$STUB_PUBLIC"; return 0 ;;
	*) echo "unexpected vault_kv call: $*" >&2; return 1 ;;
	esac
	case "$state" in
	present) printf 'value-never-printed' ;;
	missing) echo "No value found at secret/data/staging/x" >&2; return 2 ;;
	*) echo "Error making API request: permission denied" >&2; return 2 ;;
	esac
}

failures=0
# run_case <name> <OBJECT_STORAGE_ENABLED> <s3> <object-storage> <endpoint> <public> <ok|fail> [expected message]
run_case() {
	local name="$1" os="$2" want="$7" msg="${8:-}" out status
	printf 'OBJECT_STORAGE_ENABLED=%s\nS3_LOCATION=media\n' "$os" >"$work/stack.env"
	set +e
	# A subshell: die() exits it, not this script.
	out="$(
		STUB_S3="$3" STUB_OS="$4" STUB_ENDPOINT="$5" STUB_PUBLIC="$6"
		media_preflight 2>&1
	)"
	status=$?
	set -e
	if { [ "$want" = ok ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -eq 0 ]; }; then
		echo "FAIL  $name (exit $status, wanted $want): $out"
		failures=$((failures + 1))
		return
	fi
	if [ -n "$msg" ] && [[ "$out" != *"$msg"* ]]; then
		echo "FAIL  $name (message lacks '$msg'): $out"
		failures=$((failures + 1))
		return
	fi
	if [[ "$out" == *"$SECRET_ENDPOINT_MARK"* || "$out" == *"$SECRET_PUBLIC_MARK"* ]]; then
		echo "FAIL  $name (output leaks a value)"
		failures=$((failures + 1))
		return
	fi
	echo "ok    $name"
}

EXT="https://$SECRET_ENDPOINT_MARK.s3.example.com"
PUB="https://$SECRET_PUBLIC_MARK.example.com/media/"
FIX="run scripts/vault/generate-app-secrets.sh staging first"

# External S3 still needs a readable provider secret.
run_case "external, Vault read fails" false error missing "" "" fail "reading secret/staging/s3 from Vault failed"
# A failing Vault read is not "missing".
run_case "object storage, Vault read fails" true error present "" "" fail "reading secret/staging/s3 from Vault failed"
run_case "object storage, object-storage read fails" true present error "" "" fail "reading secret/staging/object-storage from Vault failed"
# Object storage on.
run_case "object storage, s3 missing" true missing present "" "" fail "$FIX"
run_case "object storage, object-storage missing" true present missing "" "" fail "$FIX"
run_case "object storage (own endpoint, no public url needed)" true present present "http://object-storage:8333" "" ok
# A Vault-only switch to another provider while the stack still runs its own storage: /media and the backups would
# keep following the stack's bucket.
run_case "object storage, external endpoint" true present present "$EXT" "$PUB" fail \
	"set OBJECT_STORAGE_ENABLED=false in stack.env"
run_case "object storage, endpoint unset" true present present "" "" fail \
	"S3_ENDPOINT_URL in secret/staging/s3 is not the stack's object"
# External provider.
STUB_BUCKET=wrong-bucket run_case "object storage, wrong bucket" true present present "http://object-storage:8333" "" fail \
	"Bundled SeaweedFS requires S3_BUCKET_NAME"
run_case "external, s3 missing" false missing missing "" "" fail "$FIX"
run_case "external, own endpoint, object storage off" false present missing "http://object-storage:8333" "$PUB" fail \
	"S3_ENDPOINT_URL points at the stack's object storage but OBJECT_STORAGE_ENABLED=false"
run_case "external, own endpoint spelled differently" false present missing "HTTP://User@Object-Storage.:8333/x" "$PUB" fail \
	"OBJECT_STORAGE_ENABLED=false"
run_case "external without PUBLIC_MEDIA_BASE_URL" false present missing "$EXT" "" fail \
	"an external provider needs PUBLIC_MEDIA_BASE_URL in secret/staging/s3"
run_case "external, complete" false present missing "$EXT" "$PUB" ok
run_case "external, host merely contains object-storage" false present missing "https://object-storage.example.com" "$PUB" ok

if [ "$failures" -gt 0 ]; then
	echo "$failures case(s) failed"
	exit 1
fi
echo "all media preflight cases passed"
