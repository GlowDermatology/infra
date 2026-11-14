#!/bin/sh
# One-shot: create the stack's media bucket on the self-hosted object storage (SeaweedFS). Idempotent.
# Run by scripts/deploy.sh as `run --rm object-storage-init` (profile object-storage-tools); never `up`.
#
# Only "the bucket is already there" counts as success. Every other failure (endpoint down, bad keys,
# a refused request) exits non-zero with the aws error on stderr. Keys are read from files, never printed.
set -eu

: "${OBJECT_STORAGE_BUCKET:?OBJECT_STORAGE_BUCKET is not set}"
endpoint="${OBJECT_STORAGE_ENDPOINT:-http://object-storage:8333}"

for f in /run/secrets/object_storage_admin_access_key /run/secrets/object_storage_admin_secret_key; do
	[ -s "$f" ] || {
		echo "init: $f is missing or empty (secret/<env>/object-storage in Vault)" >&2
		exit 1
	}
done
AWS_ACCESS_KEY_ID="$(cat /run/secrets/object_storage_admin_access_key)"
AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/object_storage_admin_secret_key)"
AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

if out="$(aws --endpoint-url "$endpoint" s3api create-bucket --bucket "$OBJECT_STORAGE_BUCKET" 2>&1)"; then
	echo "bucket $OBJECT_STORAGE_BUCKET created"
	exit 0
fi
# BucketAlreadyExists is safe to accept here: this SeaweedFS has a single owner (the admin identity), so
# "exists" can only mean "ours". Anything else, including other HTTP 409 codes, is a real failure.
case "$out" in
*BucketAlreadyOwnedByYou* | *BucketAlreadyExists*)
	echo "bucket $OBJECT_STORAGE_BUCKET already exists"
	exit 0
	;;
esac
echo "$out" >&2
exit 1
