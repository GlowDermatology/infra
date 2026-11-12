# Ops console access (Tailscale)

The ops console is Django's admin at `https://<OPS_DOMAIN>/django-admin/` (staging: `ops.website-project.uz`,
production: `ops.glowderma.uz`). It edits store settings, contacts and legal texts, so it is locked three times:

| Lock | Where | What it checks |
|---|---|---|
| 1. Network | Caddy, then Django again | your IP is in `OPS_ALLOWED_IPS`, otherwise an empty **404** |
| 2. Switch | Django | `DJANGO_ADMIN_ENABLED=true` (production default: `false` = 404) |
| 3. Login | Django | a staff account **and** a TOTP code from your authenticator app |

Lock 1 used to mean "my home IP". Home and mobile IPs change, and then you are locked out. With Tailscale every
device of yours gets a private IP that **never changes**, wherever you are. You allow those IPs once and forget
about it. The console stays invisible to the rest of the internet.

## How it works, in one picture

```
your laptop (Tailscale 100.101.1.5)
   │  the hosts file says: ops.website-project.uz = 100.80.2.9  (the server's Tailscale IP)
   ▼
encrypted Tailscale tunnel (works from home, office, mobile hotspot, a café)
   ▼
server (Tailscale 100.80.2.9) ─► Caddy :443 ─► sees 100.101.1.5 ─► in OPS_ALLOWED_IPS? ─► Django ─► login + TOTP
```

Everyone else still resolves `ops.website-project.uz` through public DNS to the server's public IP, and Caddy
answers them with an empty 404. Public DNS stays exactly as it is, so Caddy keeps renewing the certificate.

## One-time setup

Do it per environment (staging first). Names in `<angle brackets>` are yours to fill in.

### 1. Tailscale account

Sign up at <https://tailscale.com> (free for personal use). This is your "tailnet": the private network of
your devices.

### 2. Tailscale on the server

```bash
ssh root@<server>
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --accept-dns=false --hostname=glowderma-<env>
```

- `tailscale up` prints a login link: open it and approve the server.
- `--accept-dns=false` keeps the server's own DNS untouched (Docker and Caddy rely on it).
- Note the server's Tailscale IP: `tailscale ip -4` (for example `100.80.2.9`).
- In the Tailscale admin console → **Machines** → the server → **⋯** → **Disable key expiry**. Otherwise the
  server leaves your tailnet after 180 days and the console is locked again.

Optional, for a faster direct connection (Tailscale works without it, through its relays):

```bash
ufw allow 41641/udp
```

### 3. Tailscale on your laptop

Install the app from <https://tailscale.com/download>, sign in with the same account, and note the laptop's
Tailscale IP (the app shows it, or run `tailscale ip -4`), for example `100.101.1.5`.

### 4. Allow your laptop (lock 1)

On the server, edit `/opt/glowderma/runtime/local.env` and set your device IPs, space separated, each as `/32`:

```
OPS_ALLOWED_IPS=100.101.1.5/32
```

Both Caddy and Django read it, so restart both:

```bash
cd /opt/glowderma/infra
su deploy -c 'scripts/deploy.sh <env> --restart edge backend-api'
```

Allow single devices (`/32`), not the whole `100.64.0.0/10` range: that range also belongs to other people's
mobile carriers.

### 5. Point the ops name at the tunnel (laptop only)

Add one line to your laptop's hosts file:

```
100.80.2.9    ops.website-project.uz
```

(the **server's** Tailscale IP, then the ops domain; production: its own server IP and `ops.glowderma.uz`).

| System | Hosts file | Then |
|---|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` (open Notepad **as administrator**) | `ipconfig /flushdns` |
| macOS | `/etc/hosts` (`sudo nano /etc/hosts`) | `sudo dscacheutil -flushcache` |
| Linux | `/etc/hosts` (`sudo nano /etc/hosts`) | nothing |

Only the ops name goes there. The shop (`website-project.uz`) keeps using public DNS.

### 6. Turn the console on (lock 2)

In the Vault UI (SSH tunnel, see `vault/config/vault.hcl`), set `DJANGO_ADMIN_ENABLED` = `true` in
`secret/<env>/django`, then Actions → **Restart** → `<env>` → `backend` (or on the server:
`su deploy -c 'scripts/restart.sh <env> backend'`).

### 7. Your staff account (lock 3)

Once per environment:

```bash
su deploy -c 'scripts/manage.sh <env> django createstaff you@example.com --superuser'
```

The first login asks you to set up TOTP: scan the QR code with an authenticator app (Google Authenticator,
1Password, Aegis, ...).

### 8. Check

With Tailscale **on**, open `https://ops.website-project.uz/`: it redirects to `/django-admin/` and shows the
login page. With Tailscale **off**, the same address gives an empty 404. Both results are correct.

## Daily use

1. Turn Tailscale on (or leave it on: it only carries traffic to your own devices).
2. Open `https://<OPS_DOMAIN>/`, log in, enter the TOTP code.

Nothing else, whatever network you are on.

## Changes later

| You want to | Do |
|---|---|
| add a device (a second laptop) | install Tailscale on it, add its `100.x.y.z/32` to `OPS_ALLOWED_IPS` (step 4, then restart), add the hosts line (step 5) |
| remove a lost or sold device | Tailscale admin console → **Machines** → the device → **Remove**, then delete its IP from `OPS_ALLOWED_IPS` and restart (step 4) |
| close the console completely | set `DJANGO_ADMIN_ENABLED` = `false` in Vault, then Restart → `backend` |
| set up production | repeat steps 2 to 8 on the production server (its own Tailscale IP, `ops.glowderma.uz`) |

A device's Tailscale IP stays the same until you remove it from the tailnet, so `OPS_ALLOWED_IPS` rarely changes.

## Phones

Phones cannot edit a hosts file, so steps 5 to 8 do not work there as written. Use the laptop for the console.

## Troubleshooting

| You see | Usually means | Check |
|---|---|---|
| empty 404 on every page | Caddy sees an IP that is not allowed (Tailscale off, or the hosts line is missing or not active yet) | on the laptop: `ping ops.website-project.uz` must answer from the server's **100.x** address. If it shows the public IP: hosts file, then flush DNS (step 5). Browsers with "secure DNS" can skip the hosts file: turn it off for a test |
| empty 404 although `ping` shows 100.x | your IP is not in `OPS_ALLOWED_IPS`, or the edge was not restarted | compare `tailscale ip -4` (laptop) with `OPS_ALLOWED_IPS` in `local.env`, then step 4 restart |
| redirect works, but `/django-admin/` is 404 | lock 2: `DJANGO_ADMIN_ENABLED` is not `true`, or the backend was not restarted | step 6 |
| certificate warning | you opened the server's 100.x IP instead of the name | always use `https://ops.<domain>/` |
| page does not load at all (timeout) | Tailscale tunnel down | the Tailscale app shows the server as connected? `tailscale ping glowderma-<env>` |
| it worked for months, then stopped | server key expired | step 2: disable key expiry, then `tailscale up` on the server again |

To see the IP Caddy saw for your request:

```bash
docker logs glowderma-<env>-edge-1 2>&1 | grep '"host":"ops\.' | tail -n 3
```

Look at `remote_ip` in those lines: it must be one of the IPs in `OPS_ALLOWED_IPS`.
