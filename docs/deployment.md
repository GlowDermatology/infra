# Deployment

## Pipelines

**App repositories** (`backend`, `frontend`), file `.github/workflows/ci.yml`:

```
security-gitleaks ┐
security-semgrep  │
security-codeql   ├─► tests ─► build-publish ─► image-scan ─► deploy ─► cleanup-ghcr
security-deps     │            (main only)      (main only)   (main)    (main)
security-iac      ┘
```

| Stage | What |
|---|---|
| security-* | secrets in history, SAST (semgrep + CodeQL), dependency CVEs (trivy fs + pip-audit / npm audit), Dockerfile + workflow misconfiguration (hadolint, zizmor, trivy config) |
| tests | the app's full test suite (backend: lint, types, import layers, migrations check, pytest with coverage, OpenAPI diff, production settings check; plus the ops-console browser suite) |
| build-publish | multi-stage image build, push to GHCR as `backend-<sha7>` / `frontend-<sha7>-{staging,production}`, SBOM + SLSA provenance attestation |
| image-scan | the pushed digest: trivy (OS + language CVEs, secrets), grype (second database), dockle (CIS image checks) |
| deploy | writes `environments/staging/<app>/image.env` in this repository (never touches a server) |
| cleanup-ghcr | deletes old images, keeping the newest ones plus every image referenced by staging, production and the last three production releases |

Pull requests run the security stages, the tests and a build without push.

**This repository:**

| Workflow | Trigger | Does |
|---|---|---|
| `validate` | every push / PR | compose for both envs, structural rules, Caddy edge probe, Vault end-to-end test, actionlint, zizmor, shellcheck, gitleaks, semgrep, trivy config |
| `deploy-staging` | push to `main` touching `environments/staging/**` or shared files; manual | pre-deploy image scan → `scripts/deploy.sh staging` over SSH |
| `deploy-production` | same for production; manual | pre-deploy image scan → **approval** → `scripts/deploy.sh production` |
| `promote` | manual | copies staging's release into `environments/production/` (verified), commits |
| `bootstrap-server` | manual | prepares a fresh Ubuntu server |
| `rescan-deployed` | weekly, manual | scans what both environments run today; opens an issue on new fixable CVEs |

## Promotion: how a release reaches production

1. Merge to `main` in an app repo. Its pipeline publishes the image and commits
   `deploy(staging): backend backend-a3f2e1b` here. **Deploy staging** runs on its own.
2. Test on staging.
3. Actions → **Promote to production** → *Run workflow* (`app`: both, backend or frontend; leave `tag` empty).
   It checks that the tag still points at the digest staging runs, verifies the provenance attestation (built
   by the app's `ci.yml` on `main`), and commits `promote(production): backend-a3f2e1b` here. The backend is
   promoted **by digest** (byte-for-byte what staging tested). The frontend gets its sibling image built from
   the same commit with the production domain baked in.
4. **Deploy production** starts and waits: open the run, *Review deployments*, approve. Only then does it scan
   both images again with today's vulnerability data and deploy.

## Rollback

- **Code:** Promote with `tag` = an earlier build (`backend-<sha7>` or `frontend-<sha7>`, see
  `git log -p environments/production/backend/image.env`) and `scan_policy` = `report` (an older image may have
  CVEs published since; the scan still runs and is recorded but does not block). Approve the deploy. Or
  `git revert` the promotion commit. Then fix forward with a new build as soon as possible.
- **Database:** migrations are never reversed automatically. Every deploy that changes the backend first takes
  `/opt/glowderma/runtime/backups/<env>-db-pre-deploy-*.dump`. If a migration must be undone, restore it with
  `scripts/restore-postgres.sh <env> <file>` (it asks for confirmation and makes a safety dump first).
- The last three production images are kept in GHCR by the cleanup job, so they can always be redeployed.

## What `scripts/deploy.sh` does on the server

1. Refuses if the server is a different environment (`/etc/glowderma/environment`).
2. Exits without doing anything if an app has no image yet (first days of a new environment).
3. Checks the Vault TLS and AppRole files exist and the Compose file resolves.
4. Starts Vault if it is stopped (never recreates it) and refuses to continue while it is sealed.
5. Pulls every image by digest.
6. If the backend image changes: dumps the database, stops api/worker/beat, runs `backend-migrate` alone.
7. `up -d --remove-orphans --wait`: every service healthy within 10 minutes, or it prints `ps` and the last
   log lines and fails.
8. Reloads Caddy, runs `scripts/healthcheck.sh`, records the release in `runtime/deployed/history.log`.

The SSH session takes a lock (`runtime/deploy.lock`): two deploys never overlap.

## GitHub settings to create (once)

### Repository `infra`

| Where | Name | Value |
|---|---|---|
| Environment `staging` | secret `VPS_HOST` | staging server IP or hostname |
| | secret `VPS_USERNAME` | `deploy` |
| | secret `VPS_SSH_KEY` | private key (ed25519) whose public half the provider installed for root |
| | variable `VPS_HOST_KEY` | the server's host key, e.g. `ssh-ed25519 AAAA...` (verified out of band) |
| | variable `VPS_BOOTSTRAP_USER` | `root` (or a passwordless-sudo user) |
| Environment `production` | the same five, for the production server | |
| | protection: **required reviewers**, deployment branches: `main` only | |
| Repository variable | `INFRA_APP_CLIENT_ID` | Client ID of the GitOps GitHub App, below |
| Repository secret | `INFRA_APP_PRIVATE_KEY` | the App's private key (whole `.pem` file) |

### Repositories `backend` and `frontend`

| Where | Name | Value |
|---|---|---|
| Repository variable | `INFRA_APP_CLIENT_ID` | same Client ID |
| Repository secret | `INFRA_APP_PRIVATE_KEY` | same private key |
| Code security | CodeQL **default setup off** | the pipeline runs CodeQL itself (advanced setup) |

Frontend only: **repository variables** (Settings → Secrets and variables → Actions → Variables), because
Next.js bakes these into the build. The pipeline builds one image per environment from the same commit.

| Variable | Example |
|---|---|
| `STAGING_NEXT_PUBLIC_SITE_URL` | `https://staging.glowderma.uz` |
| `STAGING_GLOWDERMA_ALLOWED_ORIGINS` | `staging.glowderma.uz` |
| `STAGING_GLOWDERMA_MEDIA_HOSTS` | `staging.glowderma.uz/media` (host + path prefix: same origin) |
| `STAGING_GLOWDERMA_MEDIA_ALLOW_LOCAL` | empty |
| `PRODUCTION_NEXT_PUBLIC_SITE_URL` | `https://glowderma.uz` |
| `PRODUCTION_GLOWDERMA_ALLOWED_ORIGINS` | `glowderma.uz` |
| `PRODUCTION_GLOWDERMA_MEDIA_HOSTS` | `glowderma.uz/media` |
| `PRODUCTION_GLOWDERMA_MEDIA_ALLOW_LOCAL` | empty |

They must agree with `SITE_DOMAIN` in this repository's `environments/<env>/stack.env`.

### GitOps GitHub App

The app pipelines (staging `image.env`) and this repository's Promote workflow (production `image.env`) push
to `infra` with a GitHub App installation token minted per run by `actions/create-github-app-token`: it lives
one hour, is revoked when the job ends, is limited to
*Contents: write* on `infra`, and belongs to no person. A push made with it starts the deploy workflow (a
push with the workflow's own `GITHUB_TOKEN` never would).

One-time setup, as an organization owner:

1. Organization settings → Developer settings → GitHub Apps → **New GitHub App**. Name e.g.
   `glowderma-gitops`; any homepage URL; **Webhook: inactive**; repository permission **Contents: Read and
   write** and nothing else; install target **Only on this account**.
2. On the App's page: copy the **Client ID**, then **Generate a private key** (downloads a `.pem`).
3. **Install App** → `GlowDermatology` → **Only select repositories** → `infra`.
4. In `backend`, `frontend` and `infra`: variable `INFRA_APP_CLIENT_ID`, secret `INFRA_APP_PRIVATE_KEY` (paste the
   whole `.pem`, including the BEGIN/END lines). Delete the downloaded file.
5. If `main` in `infra` is protected by a ruleset, add the App to its bypass list.

Rotate the key: generate a new one on the App's page, update the secret in all three repositories, delete the old
key. The key does not expire.

### GHCR packages

The first push of each package must come from the app's workflow (that gives the repository admin rights on
the package, which the cleanup job needs). Then, in each package's settings, either make it public or grant
the `infra` repository read access (the pre-deploy scan and the promote workflow pull with infra's token).
Servers pull anonymously, so **public** is the simple choice; if the packages stay private, `docker login
ghcr.io` once on each server as the `deploy` user with a read-only token.
