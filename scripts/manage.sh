#!/usr/bin/env bash
# Run anything against an environment's Compose project, the safe way (right project, right env files).
#
#   scripts/manage.sh <env> ps
#   scripts/manage.sh <env> logs -f backend-api
#   scripts/manage.sh <env> django createstaff owner@example.com --superuser   (= manage.py inside backend-api)
#   scripts/manage.sh <env> shell                                              (Django shell)
#   scripts/manage.sh <env> sync-media [--apply]                               (runtime/media -> S3; dry run without --apply)
#   scripts/manage.sh <env> psql                                              (superuser psql over the socket)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_env "${1:-}"
shift
case "${1:-}" in
django)
	shift
	app_compose exec backend-api python manage.py "$@"
	;;
sync-media)
	shift
	# Runs before the switch too (USE_S3=false in stack.env, Django still on the disk): this one process gets
	# USE_S3=true, so its default storage is the bucket of secret/<env>/s3 (the S3_* keys are in django.json in
	# every mode) while the source is runtime/media. USE_S3 is a topology key read at settings import, so the
	# override holds for this command only; the running app is untouched.
	app_compose exec -e USE_S3=true backend-api python manage.py sync_media_to_s3 "$@"
	;;
shell) app_compose exec backend-api python manage.py shell ;;
psql) app_compose exec postgres psql -U glowderma -d glowderma ;;
down | rm) die "'$1' is not allowed through manage.sh (it would remove containers or volumes)" ;;
"") die "usage: scripts/manage.sh <env> <compose command | django ... | shell | psql | sync-media [--apply]>" ;;
*) app_compose "$@" ;;
esac
