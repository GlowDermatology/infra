#!/usr/bin/env bash
# Full vulnerability + secret scan of one image BY DIGEST with a fresh Trivy database (CI only).
#
#   scripts/ci/scan-image.sh <image@sha256:...> <sarif output file> <enforce|report>
#
# enforce: exit 1 on any HIGH/CRITICAL vulnerability that has a fix (or any embedded secret).
# report:  same scan and SARIF, never fails (rollbacks to an older image; see docs/deployment.md).
set -euo pipefail
ref="${1:?image reference}"
sarif="${2:?sarif output}"
policy="${3:-enforce}"
case "$ref" in *@sha256:*) ;; *) echo "refusing to scan a mutable reference: $ref" >&2; exit 2 ;; esac
trivy="aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c"
cache="${TRIVY_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/trivy-cache}"
mkdir -p "$cache" "$(dirname "$sarif")"
auth=()
[ -f "$HOME/.docker/config.json" ] && auth=(-v "$HOME/.docker/config.json:/root/.docker/config.json:ro")
run() {
	docker run --rm "${auth[@]}" -v "$cache:/root/.cache/trivy" -v "$(cd "$(dirname "$sarif")" && pwd):/out" \
		-e TRIVY_DB_REPOSITORY="public.ecr.aws/aquasecurity/trivy-db:2,ghcr.io/aquasecurity/trivy-db:2,mirror.gcr.io/aquasec/trivy-db:2" \
		-e TRIVY_JAVA_DB_REPOSITORY="public.ecr.aws/aquasecurity/trivy-java-db:1,ghcr.io/aquasecurity/trivy-java-db:1" \
		"$trivy" image --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --no-progress "$@" "$ref"
}
run --format sarif --output "/out/$(basename "$sarif")"
if [ "$policy" = enforce ]; then
	run --skip-db-update --format table --exit-code 1
else
	run --skip-db-update --format table --exit-code 0
	echo "scan policy 'report': findings above do not block this deploy" >&2
fi
