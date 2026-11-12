#!/usr/bin/env bash
# Forced command of the deploy workflows' SSH key (VPS_SSH_KEY). bootstrap-server.sh installs a root-owned copy
# as /usr/local/sbin/glowderma-deploy-gate and pins the key to it in ~deploy/.ssh/authorized_keys:
#
#   restrict,command="/usr/local/sbin/glowderma-deploy-gate" ssh-ed25519 AAAA...
#
# Whatever the client asks for, sshd runs this script instead. It accepts exactly two requests:
#
#   deploy <staging|production> <40-hex infra commit> <GHCR user>      (GHCR token = first line of stdin)
#   restart <staging|production> <backend|frontend|all>               (scripts/restart.sh: reload from Vault)
#
# deploy only for a commit that is already on origin/main; restart runs the checkout already deployed. So a
# leaked deploy key gives no shell, and the most it can do is redeploy something already on main or restart
# the apps. Not sourced from lib.sh on purpose: the installed copy runs
# outside the checkout and must not depend on files the deploy user can change.
set -euo pipefail

refuse() {
	echo "deploy-gate: refused: $*" >&2
	exit 2
}

INFRA_DIR=/opt/glowderma/infra
LOCK=/opt/glowderma/runtime/deploy.lock

read -r -a request <<<"${SSH_ORIGINAL_COMMAND:-}"
usage="only 'deploy <env> <commit> <ghcr-user>' or 'restart <env> <backend|frontend|all>' is allowed"
[ "${#request[@]}" -ge 3 ] || refuse "$usage"
env="${request[1]}"
[[ "$env" =~ ^(staging|production)$ ]] || refuse "unknown environment '$env'"

# restart: no checkout, no registry login; the release already deployed reloads its settings from Vault.
if [ "${request[0]}" = restart ]; then
	[ "${#request[@]}" -eq 3 ] || refuse "$usage"
	target="${request[2]}"
	[[ "$target" =~ ^(backend|frontend|all)$ ]] || refuse "unknown restart target '$target'"
	exec 9>"$LOCK"
	flock -w 900 9 || refuse "a deploy or restart holds the lock"
	cd "$INFRA_DIR"
	exec scripts/restart.sh "$env" "$target"
fi

[ "${#request[@]}" -eq 4 ] && [ "${request[0]}" = deploy ] || refuse "$usage"
sha="${request[2]}"
ghcr_user="${request[3]}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || refuse "commit must be a full 40-character SHA"
[[ "$ghcr_user" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || refuse "malformed GHCR user"

IFS= read -r -t 30 GHCR_TOKEN || refuse "no registry token on stdin"
[ -n "$GHCR_TOKEN" ] || refuse "empty registry token"

exec 9>"$LOCK"
flock -w 900 9 || refuse "a deploy or restart holds the lock"

# Throwaway Docker config: the GHCR login exists for this deploy only, never in ~/.docker.
DOCKER_CONFIG="$(mktemp -d)"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$ghcr_user" --password-stdin >/dev/null
unset GHCR_TOKEN

cd "$INFRA_DIR"
git fetch --quiet origin
git cat-file -e "$sha^{commit}" 2>/dev/null || refuse "commit $sha does not exist in origin"
git merge-base --is-ancestor "$sha" origin/main || refuse "commit $sha is not on main"
git checkout --quiet --force --detach "$sha"
scripts/deploy.sh "$env"
