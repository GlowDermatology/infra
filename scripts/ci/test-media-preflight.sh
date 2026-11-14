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
	"get -mount=secret -field=S3_BUCKET_NAME staging/s3") state="$STUB_S3" ;;
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
# run_case <name> <OBJECT_STORAGE_ENABLED> <USE_S3> <s3> <object-storage> <endpoint> <public> <ok|fail> [expected message]
run_case() {
	local name="$1" os="$2" us="$3" want="$8" msg="${9:-}" out status
	printf 'OBJECT_STORAGE_ENABLED=%s\nUSE_S3=%s\nS3_LOCATION=media\n' "$os" "$us" >"$work/stack.env"
	set +e
	# A subshell: die() exits it, not this script.
	out="$(
		STUB_S3="$4" STUB_OS="$5" STUB_ENDPOINT="$6" STUB_PUBLIC="$7"
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

# Both off: Vault is not even asked.
run_case "both off: nothing to check" false false missing missing "" "" ok
# A failing Vault read is not "missing".
run_case "object storage, Vault read fails" true false error present "" "" fail "reading secret/staging/s3 from Vault failed"
run_case "object storage, object-storage read fails" true false present error "" "" fail "reading secret/staging/object-storage from Vault failed"
# Object storage on.
run_case "object storage, s3 missing" true false missing present "" "" fail "$FIX"
run_case "object storage, object-storage missing" true false present missing "" "" fail "$FIX"
run_case "object storage, both present" true false present present "http://object-storage:8333" "" ok
run_case "object storage + USE_S3 (own endpoint, no public url needed)" true true present present "http://object-storage:8333" "" ok
# External provider.
run_case "USE_S3, s3 missing" false true missing missing "" "" fail "$FIX"
run_case "USE_S3, own endpoint, object storage off" false true present missing "http://object-storage:8333" "$PUB" fail \
	"USE_S3 points at the stack's object storage but OBJECT_STORAGE_ENABLED=false"
run_case "USE_S3, own endpoint spelled differently" false true present missing "HTTP://User@Object-Storage.:8333/x" "$PUB" fail \
	"OBJECT_STORAGE_ENABLED=false"
run_case "USE_S3, external without PUBLIC_MEDIA_BASE_URL" false true present missing "$EXT" "" fail \
	"an external provider needs PUBLIC_MEDIA_BASE_URL in secret/staging/s3"
run_case "USE_S3, external, complete" false true present missing "$EXT" "$PUB" ok
run_case "USE_S3, host merely contains object-storage" false true present missing "https://object-storage.example.com" "$PUB" ok

if [ "$failures" -gt 0 ]; then
	echo "$failures case(s) failed"
	exit 1
fi
echo "all media preflight cases passed"
