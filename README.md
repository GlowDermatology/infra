# Glow Derma infra

Everything that runs Glow Derma on its servers: Docker Compose stacks, Caddy edge, HashiCorp Vault, deploy and
operations scripts, and the only GitHub workflows that touch a server. Application code lives in
[`backend`](https://github.com/GlowDermatology/backend) and [`frontend`](https://github.com/GlowDermatology/frontend);
those repositories only **build, scan and publish images**, then write the new image digest here.

```
 backend repo ──┐ scans → tests → build+push → image scan → write digest ─┐
                │                                                          ▼
 frontend repo ─┘                                     infra: environments/staging/<app>/image.env
                                                                           │ (push to main)
                                                         Deploy staging ◄──┘  automatic
                                                                           │
                    Promote to production (button) ── environments/production/<app>/image.env
                                                                           │
                                                      Deploy production ◄──┘  waits for approval
```

## The five things to know

1. **An environment = one folder + one server.** `environments/staging/` and `environments/production/` hold
   the public settings and the exact image digests. Each server knows its own name (`/etc/glowderma/environment`)
   and every script refuses to act on the other one.
2. **Git is the deploy history.** A deploy happens because a commit changed an `image.env` (or a shared file).
   `git log environments/production/backend/image.env` is the list of every production backend release.
3. **Secrets live in Vault on each server**, never in GitHub or in this repository. Vault Agent sidecars render
   them into memory-only files for each container. GitHub holds only SSH access and one push token.
4. **Same origin.** `https://<SITE_DOMAIN>/` is Next.js, `https://<SITE_DOMAIN>/api/v1/` is Django, `/media/` is
   files. The domain is a value in `stack.env`, never in code.
5. **Nothing destructive is automated.** No `down -v`, no volume removal, migrations run once per release with
   a database dump taken just before.

## Layout

| Path | What |
|---|---|
| `compose/app.yaml` | the application stack (one file for both environments) |
| `compose/vault.yaml` | Vault server; its own Compose project, never restarted by deploys |
| `caddy/Caddyfile` | edge: TLS, HTTP/3, IPv4+IPv6, routing, log redaction; `edge_probe.py` tests it |
| `vault/` | server config, agent configs and templates, per-environment policies |
| `postgres/initdb/` | creates the non-superuser application role |
| `environments/<env>/` | `stack.env` (domain, limits), `backend.env`, `frontend.env`, `<app>/image.env` |
| `scripts/` | `deploy.sh`, `healthcheck.sh`, `manage.sh`, `backup.sh`, `restore-postgres.sh`, `bootstrap-server.sh` |
| `scripts/vault/` | TLS, init, unseal, configure, initial secrets, put/rotate secrets |
| `.github/workflows/` | `validate`, `deploy-staging`, `deploy-production`, `promote`, `bootstrap-server`, `rescan-deployed` |

## Daily operations

| I want to… | Do this |
|---|---|
| ship a change to staging | merge to `main` in the app repo; its pipeline deploys staging by itself |
| ship to production | Actions → **Promote to production** → Run; then approve the **Deploy production** run |
| roll production back | **Promote to production** with `tag` = the previous build (see `git log`), `scan_policy` = report |
| see what runs | `cat environments/<env>/*/image.env`, or on the server `scripts/manage.sh <env> ps` |
| run a Django command | `scripts/manage.sh <env> django <command>` on the server |
| add a provider credential | `scripts/vault/put-secret.sh <env> django ESKIZ_PASSWORD` on the server |
| set up a new server | [`docs/first-server-runbook.md`](docs/first-server-runbook.md) |
| check everything before a PR | `scripts/validate.sh` |

## Documentation

- [Architecture](docs/architecture.md): components, networks, request and secret flows
- [Deployment](docs/deployment.md): pipelines, GitHub settings to create, promotion, rollback
- [Staging and production](docs/staging-production.md): what differs, what is isolated
- [Secrets management](docs/secrets-management.md): Vault layout, rotation, failure behaviour
- [Security](docs/security.md): hardening, scanners, threat model, accepted risks
- [First server runbook](docs/first-server-runbook.md): from an empty VPS to a running environment
- [Disaster recovery](docs/disaster-recovery.md): backups, restore, rebuilding a server
