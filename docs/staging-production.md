# Staging and production

| | staging | production |
|---|---|---|
| server | its own VPS (later its own cluster) | its own VPS |
| Compose projects | `glowderma-staging`, `glowderma-staging-vault` | `glowderma-production`, `glowderma-production-vault` |
| domain | `environments/staging/stack.env` (`staging.glowderma.uz`) | `environments/production/stack.env` (`glowderma.uz`) |
| Vault | its own server, its own unseal keys | its own server, its own unseal keys |
| secrets paths | `secret/staging/*` | `secret/production/*` |
| AppRoles | `staging-backend`, `staging-frontend`, `staging-datastores` | `production-…` |
| database, Redis, media | on the staging server | on the production server |
| deploy trigger | automatic on every app `main` build | Promote button + required reviewer |
| GitHub environment (infra repo) | `staging` (no reviewers) | `production` (required reviewers, `main` only) |
| `ALERT_ENV` / ops console badge | `staging` | `production` |
| backend image | the same digest is promoted | ← byte-for-byte |
| frontend image | `frontend-<sha>-staging` | `frontend-<sha>-production` (same commit, production domain baked in) |

## Isolation guarantees and how they are enforced

- **Different machines.** Production never depends on a staging service: nothing in `compose/` names another
  host, and the two Vaults are separate servers.
- **No cross-environment secret read.** Even if both were on one Vault, the policies only grant
  `secret/data/<env>/…`; `scripts/ci/test-vault.sh` proves a staging AppRole cannot read
  `secret/data/production/django` (and every other combination).
- **No wrong-server command.** `/etc/glowderma/environment` names the server; every script refuses another
  environment argument; the deploy workflow uses the GitHub environment's own SSH secrets.
- **No accidental production deploy.** Production changes only through a commit to
  `environments/production/**` (made by Promote) or to shared files, and every production deploy waits for a
  reviewer.

## Changing the domain

Edit `SITE_DOMAIN` / `OPS_DOMAIN` in `environments/<env>/stack.env` and the frontend repo's repository variables
`<ENV>_NEXT_PUBLIC_SITE_URL`, `<ENV>_GLOWDERMA_ALLOWED_ORIGINS`, `<ENV>_GLOWDERMA_MEDIA_HOSTS`; update DNS; re-run the
frontend pipeline (the domain is baked into the Next.js build) and deploy. Register the new OAuth callback URLs
with Google/Facebook/Apple (`https://<SITE_DOMAIN>/admin/auth/oauth/<provider>/callback`).

## Moving staging to its own cluster later

Nothing in the app repositories changes. Point the `staging` GitHub environment's SSH secrets at the new
host, run **Bootstrap server**, follow the runbook. Only `scripts/deploy.sh` (one host, Docker Compose) would
be replaced if the target stops being Docker Compose.
