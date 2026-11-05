# First server runbook: from an empty VPS to a running environment

About 30 minutes. Do staging first. Every command after step 2 runs **on the server**, in
`/opt/glowderma/infra`.

## 0. What you need

- An Ubuntu 24.04 or 26.04 VPS (2 vCPU / 4 GB / 40 GB is enough) in Uzbekistan (compliance), with IPv4 and,
  ideally, IPv6. The provider installs your SSH public key for `root`.
- A dedicated ed25519 key pair for GitHub: `ssh-keygen -t ed25519 -f glowderma-<env> -N ''`. Give the provider
  `glowderma-<env>.pub`; the private file becomes the `VPS_SSH_KEY` secret.
- The server's host key, read **out of band**: the provider console shows it, or run
  `ssh-keyscan -t ed25519 <ip>` from your machine and compare with the console.
- DNS access for the domains in `environments/<env>/stack.env` (`SITE_DOMAIN`, `www.SITE_DOMAIN`, `OPS_DOMAIN`).
- The GitHub settings of [deployment.md](deployment.md#github-settings-to-create-once).

## 1. GitHub

In the infra repository, environment `<env>`: secrets `VPS_HOST`, `VPS_USERNAME=deploy`, `VPS_SSH_KEY`;
variables `VPS_HOST_KEY` (the host key, e.g. `ssh-ed25519 AAAA...`) and `VPS_BOOTSTRAP_USER=root`.

## 2. Bootstrap

Actions → **Bootstrap server** → environment `<env>`, host key → Run. It installs Docker, the firewall, kernel
tuning for HTTP/3 and IPv6, the `deploy` user, the directories and the infra checkout. Read its last lines.

## 3. DNS

`A` records (and `AAAA` if the bootstrap reported an IPv6 default route) for `SITE_DOMAIN`, `www.SITE_DOMAIN`
and `OPS_DOMAIN` pointing at the server. Caddy obtains the certificates on the first deploy.

## 4. Vault (on the server)

```bash
ssh root@<server>
cd /opt/glowderma/infra
scripts/vault/gen-tls.sh <env>            # as root: CA + server certificate in /opt/glowderma/runtime/vault/tls
su deploy -c 'scripts/vault/init.sh <env>'
```

`init.sh` prints 5 unseal key shares and the root token **once**. Store each share in a different
person's password manager entry, and the root token separately. Never paste them into chat, tickets or GitHub.

```bash
su deploy -c 'scripts/vault/unseal.sh <env>'                  # 3 of the 5 shares
scripts/vault/configure.sh <env>                               # as root; asks for the root token
su deploy -c 'scripts/vault/generate-app-secrets.sh <env>'     # asks for the root token
```

When done, revoke the root token (it can always be regenerated from the unseal keys with
`vault operator generate-root`, so nobody keeps a standing admin credential):

```bash
read -rs VAULT_TOKEN && export VAULT_TOKEN       # paste the root token; it stays out of the shell history
docker compose -p glowderma-<env>-vault -f compose/vault.yaml --env-file environments/<env>/stack.env \
  exec -e VAULT_TOKEN vault vault token revoke -self
unset VAULT_TOKEN
```

## 5. Host-local settings

Edit `/opt/glowderma/runtime/local.env`: `OPS_ALLOWED_IPS` (space-separated office IPs for the ops console),
and the backup settings of [disaster-recovery.md](disaster-recovery.md).

## 6. First deploy

Actions → **Deploy <env>** → Run (or simply wait for the next app pipeline run). The deploy exits early, with a
notice, until both apps have published an image for this environment.

Then create the first staff account:

```bash
su deploy -c 'scripts/manage.sh <env> django createstaff owner@example.com --superuser'
```

## 7. Check

```bash
su deploy -c 'scripts/healthcheck.sh <env>'
```

All `ok`: containers healthy, Django ready, the Next → Django hop with the internal secret, same-origin routes,
private paths hidden, HTTP/3 advertised. From your machine: `curl -sI --http3 https://<SITE_DOMAIN>/healthz`.

## After a reboot

Vault starts sealed; every container waits for its secrets. Run `scripts/vault/unseal.sh <env>` and the stack
comes up by itself within a minute. Nothing else to do.
