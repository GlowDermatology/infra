#!/usr/bin/env bash
# Backups of one environment. Run as root on its server.
#
#   scripts/backup.sh <env> nightly      database + media (disk, or a mirror of the object storage; nothing for an
#                                        external S3 provider) + Vault snapshot, prune old local files, copy off-host
#                                        (cron: /etc/cron.d/glowderma-backup, installed by bootstrap-server.sh)
#   scripts/backup.sh <env> pre-deploy   database only, before a release that changes the backend (deploy.sh)
#
# Every file is written as <name>.tmp, verified, then renamed: a partial file never has a final name. Files are
# 0600 in a 0700 directory (they hold every personal record).
#
# Off-host copy (docs/disaster-recovery.md), configured in /opt/glowderma/runtime/local.env:
#   BACKUP_AGE_RECIPIENT=age1...      public key; the private key lives OFF this server (password manager)
#   BACKUP_RCLONE_REMOTE=offsite:glowderma/<env>    an rclone remote off this server
# Plaintext never leaves the host: a remote without an age recipient is refused.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
label="${2:-}"
case "$label" in nightly | pre-deploy) ;; *) die "usage: scripts/backup.sh <env> nightly|pre-deploy" ;; esac
umask 077

backup_dir="${GLOWDERMA_BACKUP_DIR:-$RUNTIME_DIR/backups}"
keep_days="${GLOWDERMA_BACKUP_KEEP_DAYS:-14}"
recipient="$(local_value BACKUP_AGE_RECIPIENT)"
remote="$(local_value BACKUP_RCLONE_REMOTE)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_dir"
if [ -n "$remote" ] && [ -z "$recipient" ]; then
	die "BACKUP_RCLONE_REMOTE is set but BACKUP_AGE_RECIPIENT is not: refusing to copy unencrypted backups off-host"
fi

pending=""
trap '[ -n "$pending" ] && rm -f -- "$pending"' EXIT
created=()

# finish <file>: encrypt when a recipient is configured (the plaintext is then removed), record the result.
finish() {
	local file="$1"
	if [ -n "$recipient" ]; then
		pending="$file.age.tmp"
		age -r "$recipient" -o "$pending" "$file"
		mv -- "$pending" "$file.age"
		pending=""
		rm -f -- "$file"
		file="$file.age"
	fi
	created+=("$file")
	echo "backup $label: $file"
}

# Database: custom-format dump as the superuser over the container's socket, read back in full.
db="$backup_dir/$ENV-db-$label-$stamp.dump"
pending="$db.tmp"
app_compose exec -T postgres pg_dump -U glowderma -Fc glowderma >"$pending" || die "pg_dump failed"
[ -s "$pending" ] || die "pg_dump wrote nothing"
app_compose exec -T postgres pg_restore --list >/dev/null <"$pending" || die "the dump does not read back"
mv -- "$pending" "$db"
pending=""
finish "$db"

if [ "$label" = nightly ]; then
	# Media: on disk, mirrored out of the stack's object storage, or an external provider (not our data).
	media_src=""
	media_error=""
	# The mirror follows stack.env; Django follows secret/<env>/s3. If they disagree (a Vault-only switch to another
	# provider), mirroring the stack's bucket would back up a stale copy without a word: refuse it loudly instead and
	# still finish the database and Vault backups (the script then exits non-zero).
	if [ "$(media_backend)" = object-storage ] && ! (
		secret_must_exist s3 S3_BUCKET_NAME
		own_storage_endpoint_check
	); then
		media_error="media NOT backed up: Django does not use the stack's object storage (see the error above)"
		echo "ERROR: $media_error" >&2
	elif [ "$(media_backend)" = object-storage ]; then
		# Admin keys are read from files inside the container (as in object-storage/init.sh), never put in argv.
		app_compose --profile object-storage-tools run --rm --no-deps -T -e MEDIA_LOCATION="$(stack_value S3_LOCATION)" \
			--entrypoint sh object-storage-init -c '
			set -eu
			for f in /run/secrets/object_storage_admin_access_key /run/secrets/object_storage_admin_secret_key; do
				[ -s "$f" ] || { echo "backup: $f is missing or empty" >&2; exit 1; }
			done
			AWS_ACCESS_KEY_ID="$(cat /run/secrets/object_storage_admin_access_key)"
			AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/object_storage_admin_secret_key)"
			AWS_DEFAULT_REGION=us-east-1
			export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
			exec aws --endpoint-url http://object-storage:8333 s3 sync "s3://glowderma-media/$MEDIA_LOCATION" /mirror --delete --only-show-errors' ||
			die "object storage mirror failed"
		media_src="$RUNTIME_DIR/media-mirror"
	elif [ "$(stack_value USE_S3)" = true ]; then
		echo "media: external provider, not backed up here"
	else
		media_src="$RUNTIME_DIR/media"
	fi
	if [ -n "$media_src" ]; then
		media="$backup_dir/$ENV-media-$stamp.tar.gz"
		pending="$media.tmp"
		tar -C "$media_src" -czf "$pending" . || die "media tarball failed"
		tar -tzf "$pending" >/dev/null || die "the media tarball does not list"
		mv -- "$pending" "$media"
		pending=""
		finish "$media"
	fi

	# Vault Raft snapshot (encrypted by Vault's own barrier; restoring it needs the unseal keys).
	token_file="$RUNTIME_DIR/vault/snapshot-token"
	if [ -s "$token_file" ]; then
		snap="$backup_dir/$ENV-vault-$stamp.snap"
		pending="$snap.tmp"
		vault_compose exec -T -e VAULT_TOKEN="$(cat "$token_file")" vault sh -c \
			'vault token renew >/dev/null && vault operator raft snapshot save /tmp/s.snap >/dev/null && cat /tmp/s.snap && rm -f /tmp/s.snap' \
			>"$pending" || die "Vault snapshot failed"
		[ -s "$pending" ] || die "Vault snapshot is empty"
		mv -- "$pending" "$snap"
		pending=""
		finish "$snap"
	else
		echo "backup: no $token_file (scripts/vault/configure.sh creates it); Vault snapshot skipped" >&2
	fi

	find "$backup_dir" -maxdepth 1 -type f -name "$ENV-*" -mtime +"$keep_days" -delete
	find "$backup_dir" -maxdepth 1 -type f -name "$ENV-db-pre-deploy-*" -mtime +3 -delete
fi

if [ -n "$remote" ]; then
	for file in "${created[@]}"; do
		rclone copy --immutable "$file" "$remote/" || die "off-host copy of $file failed"
	done
	echo "backup $label: copied ${#created[@]} file(s) to $remote"
fi
[ -z "${media_error:-}" ] || die "$media_error"
