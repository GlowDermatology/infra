#!/usr/bin/env bash
# Prepare a fresh Ubuntu 24.04 / 26.04 server for one environment. Idempotent: safe to run again at any time
# (it never deletes data, never touches running containers, never overwrites Vault material or local.env).
#
# Normally run by the "Bootstrap server" workflow, which streams this file over SSH:
#   ssh root@host "DEPLOY_PUBLIC_KEY='ssh-ed25519 AAAA...' bash -s -- staging" < scripts/bootstrap-server.sh
#
# Environment:
#   DEPLOY_PUBLIC_KEY   required: public key of the "deploy" user (the workflows' VPS_SSH_KEY). It is pinned
#                       to the deploy gate (scripts/deploy-gate.sh) and removed from root's authorized_keys.
#                       Log in for this script with a DIFFERENT key (VPS_BOOTSTRAP_SSH_KEY).
#   INFRA_REPO_URL      default https://github.com/GlowDermatology/infra.git
#
# What it does: packages and security updates, Docker Engine + Compose from Docker's repository, dual-stack
# Docker networking, kernel tuning for QUIC/HTTP3 and IPv6, firewall, SSH hardening, the deploy user, the
# directory layout with the UIDs the containers run as, the infra checkout, backup cron and log rotation.
set -euo pipefail

env="${1:-}"
case "$env" in staging | production) ;; *)
	echo "usage: bootstrap-server.sh <staging|production>" >&2
	exit 2
	;;
esac
[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}
: "${DEPLOY_PUBLIC_KEY:?DEPLOY_PUBLIC_KEY is required (public key of the deploy user)}"
INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/GlowDermatology/infra.git}"
BASE=/opt/glowderma
RUNTIME="$BASE/runtime"
step() { printf '\n==> %s\n' "$*"; }

if [ -r /etc/glowderma/environment ] && [ "$(cat /etc/glowderma/environment)" != "$env" ]; then
	echo "this server is already '$(cat /etc/glowderma/environment)'; refusing to turn it into '$env'" >&2
	exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
case "${ID}:${VERSION_ID}" in
ubuntu:24.04 | ubuntu:26.04) ;;
*)
	echo "unsupported OS ${PRETTY_NAME:-unknown}: Ubuntu 24.04 or 26.04 only" >&2
	exit 1
	;;
esac

step "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq --no-install-recommends ca-certificates curl gnupg git jq openssl age rclone \
	ufw fail2ban chrony unattended-upgrades logrotate cron

step "Docker Engine and Compose (Docker's own repository)"
install -d -m 0755 /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/docker.asc ]; then
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
fi
codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/$codename/Release" >/dev/null; then
	echo "Docker publishes no repository for '$codename' yet; using noble (24.04) packages" >&2
	codename=noble
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
	>/etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

step "Docker daemon: IPv6, log rotation, live restore"
install -d -m 0755 /etc/docker
desired='{"ipv6": true, "fixed-cidr-v6": "fd00:6764:ffff::/64", "ip6tables": true, "live-restore": true,
  "log-driver": "json-file", "log-opts": {"max-size": "20m", "max-file": "5"}}'
current='{}'
[ -s /etc/docker/daemon.json ] && current="$(cat /etc/docker/daemon.json)"
merged="$(jq -s '.[0] * .[1]' <(echo "$current") <(echo "$desired"))"
if [ "$merged" != "$(jq . <(echo "$current"))" ]; then
	echo "$merged" >/etc/docker/daemon.json
	systemctl restart docker # live-restore keeps running containers up
fi
systemctl enable --now docker

step "Kernel: QUIC buffers, BBR, forwarding, IPv6 router advertisements"
uplink="$(ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit}')"
[ -n "$uplink" ] || uplink="$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit}')"
cat >/etc/sysctl.d/90-glowderma.conf <<EOF
# HTTP/3 (QUIC over UDP): larger socket buffers, as quic-go recommends.
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
# Modern congestion control.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Docker routes both families.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# With forwarding on, Linux ignores router advertisements unless accept_ra = 2: a VPS that learns its IPv6
# default route by SLAAC would silently lose IPv6 a few minutes later.
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
${uplink:+net.ipv6.conf.$uplink.accept_ra = 2}
EOF
sysctl --system >/dev/null
if ip -6 route show default | grep -q .; then
	echo "IPv6 default route present: publish AAAA records for the domains"
else
	echo "WARNING: no IPv6 default route on this server; do NOT publish AAAA records until it has one" >&2
fi

step "Firewall (ufw): SSH, HTTP, HTTPS over TCP and UDP (HTTP/3), IPv4 and IPv6"
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for rule in 22/tcp 80/tcp 443/tcp 443/udp; do ufw allow "$rule" >/dev/null; done
ufw --force enable >/dev/null
# Note: Docker programs its own rules for published ports. Only the edge publishes anything (80, 443).

step "SSH hardening and fail2ban"
cat >/etc/ssh/sshd_config.d/90-glowderma.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
EOF
sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd
systemctl enable --now fail2ban chrony

step "Automatic security updates (Docker packages excluded: upgrade them deliberately)"
cat >/etc/apt/apt.conf.d/52glowderma-unattended <<'EOF'
Unattended-Upgrade::Package-Blacklist { "docker-ce"; "docker-ce-cli"; "containerd.io"; "docker-compose-plugin"; "docker-buildx-plugin"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

step "deploy user (used by the deploy workflows)"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
usermod -aG docker deploy
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 0600 /home/deploy/.ssh/authorized_keys
# The key itself is added after the infra checkout, pinned to the deploy gate (step "Deploy key" below).

step "Directories (owned by the UIDs the containers run as)"
install -d -m 0755 /etc/glowderma "$BASE"
echo "$env" >/etc/glowderma/environment
install -d -m 0750 -o deploy -g deploy "$RUNTIME" "$RUNTIME/deployed"
install -d -m 0700 -o deploy -g deploy "$RUNTIME/backups"
install -d -m 0755 "$RUNTIME/vault" "$RUNTIME/vault/tls" "$RUNTIME/vault/approle"
install -d -m 0500 -o 10001 -g 10001 "$RUNTIME/vault/approle/backend"
install -d -m 0500 -o 1000 -g 1000 "$RUNTIME/vault/approle/frontend"
install -d -m 0500 -o 999 -g 999 "$RUNTIME/vault/approle/datastores"
install -d -m 0700 -o 1000 -g 1000 "$RUNTIME/caddy" "$RUNTIME/caddy/data" "$RUNTIME/caddy/config"
install -d -m 0755 -o 10001 -g 10001 "$RUNTIME/media"
if [ ! -e "$RUNTIME/local.env" ]; then
	install -m 0600 -o deploy -g deploy /dev/null "$RUNTIME/local.env"
	cat >"$RUNTIME/local.env" <<'EOF'
# Host-local values that are not secrets but must not be in the public repository.
# Space-separated IPs/CIDRs allowed to open the ops console (OPS_DOMAIN). Empty = nobody.
OPS_ALLOWED_IPS=
# Off-host backups (docs/disaster-recovery.md): age public key and an rclone remote IN UZBEKISTAN.
BACKUP_AGE_RECIPIENT=
BACKUP_RCLONE_REMOTE=
EOF
fi

step "Infra checkout ($BASE/infra)"
if [ ! -d "$BASE/infra/.git" ]; then
	install -d -o deploy -g deploy "$BASE/infra"
	sudo -u deploy git clone --quiet "$INFRA_REPO_URL" "$BASE/infra"
else
	sudo -u deploy git -C "$BASE/infra" fetch --quiet origin
fi

step "Deploy key: pinned to the deploy gate (no shell)"
# Root-owned copy of scripts/deploy-gate.sh from origin/main, outside the checkout the deploy user owns.
gate=/usr/local/sbin/glowderma-deploy-gate
gate_tmp="$(mktemp)"
sudo -u deploy git -C "$BASE/infra" show origin/main:scripts/deploy-gate.sh | tee "$gate_tmp" >/dev/null
install -m 0755 -o root -g root "$gate_tmp" "$gate"
rm -f "$gate_tmp"
read -r key_type key_blob _ <<<"$DEPLOY_PUBLIC_KEY"
[ -n "${key_blob:-}" ] || {
	echo "DEPLOY_PUBLIC_KEY is not a public key line" >&2
	exit 1
}
# Replace every line carrying this key (an older unrestricted entry included) with the pinned one.
keys=/home/deploy/.ssh/authorized_keys
{
	grep -vF "$key_blob" "$keys" || true
	echo "restrict,command=\"$gate\" $key_type $key_blob glowderma-deploy"
} >"$keys.new"
install -m 0600 -o deploy -g deploy "$keys.new" "$keys"
rm -f "$keys.new"
# The deploy key must not open root (or the bootstrap user) either. Removed only when another key remains,
# so a server set up with a single shared key is never locked out: it gets a warning instead.
admin_home=/root
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && admin_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
admin_keys="$admin_home/.ssh/authorized_keys"
if [ -f "$admin_keys" ] && grep -qF "$key_blob" "$admin_keys"; then
	if grep -vF "$key_blob" "$admin_keys" | grep -qE '^(ssh-|ecdsa-|sk-)'; then
		grep -vF "$key_blob" "$admin_keys" >"$admin_keys.new" || true
		chmod --reference="$admin_keys" "$admin_keys.new"
		chown --reference="$admin_keys" "$admin_keys.new"
		mv "$admin_keys.new" "$admin_keys"
		echo "removed the deploy key from $admin_keys"
	else
		echo "WARNING: the deploy key is the ONLY key in $admin_keys; left in place so you are not locked out." >&2
		echo "         Use a separate bootstrap key (docs/deployment.md), re-run, and this is removed." >&2
	fi
fi

step "Backups (nightly 02:15 Tashkent) and Vault audit log rotation"
cat >/etc/cron.d/glowderma-backup <<EOF
# Nightly backup of $env: database, media, Vault snapshot (scripts/backup.sh). Host clock is UTC.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 21 * * * deploy $BASE/infra/scripts/backup.sh $env nightly >>$RUNTIME/backups/backup.log 2>&1
EOF
chmod 0644 /etc/cron.d/glowderma-backup
cat >/etc/logrotate.d/glowderma-vault-audit <<EOF
/var/lib/docker/volumes/glowderma-$env-vault_vault-logs/_data/audit.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    copytruncate
}
EOF

step "Done"
cat <<EOF
Server prepared for '$env'. Next (docs/first-server-runbook.md):
  1. DNS: A (and AAAA if IPv6 is present) for SITE_DOMAIN, www.SITE_DOMAIN, OPS_DOMAIN of environments/$env/stack.env
  2. as root:   $BASE/infra/scripts/vault/gen-tls.sh $env
  3. as deploy: $BASE/infra/scripts/vault/init.sh $env       (store the unseal keys and root token OFFLINE)
  4. as deploy: $BASE/infra/scripts/vault/unseal.sh $env
  5. as root:   $BASE/infra/scripts/vault/configure.sh $env
  6. as deploy: $BASE/infra/scripts/vault/generate-app-secrets.sh $env
  7. edit $RUNTIME/local.env (OPS_ALLOWED_IPS, backups)
  8. run the "Deploy $env" workflow (or wait for the next pipeline)
EOF
