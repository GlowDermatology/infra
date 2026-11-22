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
| `validate` | pull requests, pushes that change files other than image pins, and as part of each deploy | compose for both envs, structural rules, Caddy edge probe, Vault end-to-end test, actionlint, zizmor, shellcheck, gitleaks, semgrep, trivy config |
| `deploy-staging` | push to `main` changing `environments/staging/backend/image.env` or `environments/staging/frontend/image.env`; manual | validation → pre-deploy image scan → `scripts/deploy.sh staging` over SSH |
| `deploy-production` | push to `main` touching `environments/production/**` or shared runtime files; manual | validation → pre-deploy image scan → **approval** → `scripts/deploy.sh production` |
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
4. **Deploy production** validates the infra and scans both images again. When it requests approval, open the
   run, select *Review deployments*, and approve.

To apply a staging infrastructure change without updating an image pin, run **Deploy staging** manually from `main`.

## Rollback

- **Code:** Promote with `tag` = an earlier build (`backend-<sha7>` or `frontend-<sha7>`, see
  `git log -p environments/production/backend/image.env`) and `scan_policy` = `report` (an older image may have
  CVEs published since; the scan still runs and is recorded but does not block). Approve the deploy. Or
  `git revert` the promotion commit. Then fix forward with a new build as soon as possible.
- **Database:** migrations are never reversed automatically. Every deploy that changes the backend first takes
  `/opt/glowderma/runtime/backups/<env>-db-pre-deploy-*.dump`. If a migration must be undone, restore it with
  `scripts/restore-postgres.sh <env> <file>` (it asks for confirmation and makes a safety dump first).
- The last three production images are kept in GHCR by the cleanup job, so they can always be redeployed.

## S3 media storage

Staging and production use S3 for uploads. Deploy a backend image with S3-only
settings together with this stack revision. Run `scripts/vault/generate-app-secrets.sh <env>`
before the first deploy to create the required Vault paths.

- **Bundled SeaweedFS (default).** Keep `OBJECT_STORAGE_ENABLED=true`. Deployment starts
  SeaweedFS and creates `glowderma-media`. Keep the generated internal endpoint and bucket in
  `secret/<env>/s3`. Leave `PUBLIC_MEDIA_BASE_URL` unset in Vault so the stack uses
  `https://<site>/media/`. Caddy serves reads from the bucket's `S3_LOCATION` prefix.
  The nightly backup mirrors that prefix.
- **External S3.** Set `OBJECT_STORAGE_ENABLED=false` and provision the bucket.
  Configure its bucket, region, credentials, addressing style, and endpoint (optional for AWS)
  in `secret/<env>/s3`. Set `PUBLIC_MEDIA_BASE_URL` to the browser-accessible origin and
  prefix, with a trailing slash. Caddy returns 404 on the stack's `/media/*` path in this mode.
  Set the matching host and path prefix in `GLOWDERMA_MEDIA_HOSTS` and rebuild the frontend.
  Backups and restores of external media are handled at the provider.

Before switching an existing environment between buckets, pause media writes and copy
the objects, including thumbnails and medium variants, to the new bucket under the
same keys. If the public URL changes, account for old absolute links already distributed
to clients, such as notification images. Verify an upload and fetch an original and both
variants using their public URLs after deploy.

For bundled key rotation, update the keys in Vault, restart `vault-agent-datastores`
to render the identities, restart `object-storage`, then run
`scripts/restart.sh <env> backend` to reload Django's credentials. For external key
rotation, update Vault and run the backend restart.

## AI assistant: the two Vault agents (once per server)

The release that adds `vault-agent-ai-writer` and `vault-agent-ai-reader` (secrets-management.md, "AI provider keys")
needs their policies and AppRoles in each Vault **before** it is deployed: `deploy.sh` stops at its first check
(`runtime/vault/approle/ai-writer is missing`) and changes nothing until they exist. Staging first, then production;
the backend release with the assistant can be deployed before or after (it stays off until a key is set).

1. **Before merging**, on each server as root, run `configure.sh` from the PR's files (idempotent; it keeps every
   existing AppRole credential and adds the two roles, their files and `max_versions`):

   ```bash
   cd /opt/glowderma/infra && git fetch origin <pr-branch>
   d="$(mktemp -d)" && git archive FETCH_HEAD | tar -x -C "$d"
   "$d/scripts/vault/configure.sh" <env>          # asks for an admin token
   rm -rf "$d"
   ```

   (Or merge first: the staging deploy then fails at its first check without touching anything; run
   `scripts/vault/configure.sh staging` on the server, now on the merged commit, and re-run **Deploy staging**.
   Do production's step before approving its deploy.)
2. Merge. **Deploy staging** recreates every agent (their config hash changed; each re-renders before its app
   restarts), starts the two AI agents and recreates api and worker on their new networks.
3. Check: `scripts/healthcheck.sh staging` lists both AI agents healthy. Then, in the backend's own steps (backend
   `docs/ops/ai-assistant.md`): `AI_MODE=live` in `secret/staging/django` + **Restart** backend, a superuser enters
   the key in the ops console, the test passes, the assistant is switched on.
4. Approve **Deploy production** after doing step 1 there; repeat step 3 on production.

Rollback: revert the merge commit (both deploys run again: the AI agents are removed as orphans, api and worker lose
`VAULT_MODE=live`, so the assistant answers "not configured"; nothing else changes). The policies, AppRoles and
stored key versions stay in Vault, harmless and ready for a re-apply. To remove them as well:
`vault delete auth/approle/role/<env>-ai-{writer,reader}`, `vault policy delete <env>-ai-{writer,reader}` and
`rm -r /opt/glowderma/runtime/vault/approle/ai-{writer,reader}` (keep `secret/<env>/ai/*` unless the key is retired).

## What `scripts/deploy.sh` does on the server

1. Refuses if the server is a different environment (`/etc/glowderma/environment`).
2. Exits without doing anything if an app has no image yet (first days of a new environment).
3. Checks the Vault TLS and AppRole files exist (all five agents) and the Compose file resolves.
4. Starts Vault if it is stopped (never recreates it) and refuses to continue while it is sealed.
5. Media preflight: `secret/<env>/s3` must exist in every mode (the backend's `django.json` is rendered from it)
   and, with `OBJECT_STORAGE_ENABLED=true`, `secret/<env>/object-storage` too, or it stops with `run
   scripts/vault/generate-app-secrets.sh <env> first`. On the stack's own storage the endpoint's
   host must be `object-storage` and the bucket must be `glowderma-media`; with an external provider (`OBJECT_STORAGE_ENABLED=false`) it must not be, and
   `PUBLIC_MEDIA_BASE_URL` must be set. Messages name keys, never values. (`scripts/restart.sh <env> backend` runs
   the same preflight.)
6. Pulls every image by digest (and the bucket-setup image when the object storage is enabled).
7. Starts the secrets agents, postgres and redis; with `OBJECT_STORAGE_ENABLED=true` it also starts
   `object-storage` and runs the one-shot `object-storage-init` (creates the bucket, idempotent). `vault/agent/` is
   bind-mounted, so its hash is a label of the agents (`org.glowderma.agent-config`): when a config or template
   changed, the agents are recreated, and the backend and frontend files are removed first so their healthchecks
   wait for a render from the new templates.
8. If the backend image changes: dumps the database, stops api/worker/beat, runs `backend-migrate` alone.
9. `up -d --remove-orphans --wait`: every service healthy within 10 minutes, or it prints `ps` and the last
   log lines and fails. With `OBJECT_STORAGE_ENABLED=false` a leftover object storage container (which
   `--remove-orphans` keeps) is removed, after moving the backend to the provider in Vault
   (`restart.sh <env> backend`); its data stays in `runtime/object-storage`.
10. Reloads Caddy and runs `scripts/healthcheck.sh` and `manage.py media_storage_check`. It
    fails the deploy with its output; records the release in `runtime/deployed/history.log`.

The server needs **Docker Compose v2.20 or newer** (`depends_on ... required: false` makes the object storage
optional). `docker compose version` shows it. `deploy.sh` does not check the version itself.

The SSH session takes a lock (`runtime/deploy.lock`): two deploys never overlap.

### The deploy gate (what the deploy key can do)

`VPS_SSH_KEY` opens no shell. Bootstrap pins it in `~deploy/.ssh/authorized_keys` with
`restrict,command="/usr/local/sbin/glowderma-deploy-gate"`, a root-owned copy of
[scripts/deploy-gate.sh](../scripts/deploy-gate.sh), and removes it from root's `authorized_keys`. Whatever a
client sends, sshd runs the gate, which accepts two requests: `deploy <env> <40-hex commit> <ghcr-user>`, only
for a commit already on `origin/main`, and `restart <env> <backend|frontend|edge|all>` (below). A leaked deploy key
can therefore only redeploy something on `main` or restart the apps.
Root access needs `VPS_BOOTSTRAP_SSH_KEY`, which only the Bootstrap workflow uses; you can remove that secret
between bootstraps and add it back when you need one.

Consequences: deploys run from `main` only (a `workflow_dispatch` from another branch is refused by the gate),
and a change to the gate takes effect on a server after **Bootstrap server** runs again (it installs the gate
from `origin/main`).

### Restart: reload settings and secrets from Vault

After changing `secret/<env>/django` or `secret/<env>/frontend` (Vault UI, `vault kv patch`): Actions →
**Restart** → environment + target (`backend`, `frontend`, `edge`, `all`). Through the gate it runs
[scripts/restart.sh](../scripts/restart.sh) on the release already deployed: refuses while Vault is sealed,
deletes the rendered file and restarts the agent (so the app cannot pick up the old file), waits for a fresh
render, recreates the app, runs `healthcheck.sh`. It shares the deploy lock and the `deploy-<env>` concurrency
group, and production waits for its required reviewer like a deploy. On the server the same thing is
`scripts/restart.sh <env> <target>`.

### Moving an existing server to two keys (once per server)

1. `ssh-keygen -t ed25519 -f glowderma-<env>-deploy -N ''` on your machine.
2. Environment `<env>` in infra: copy the current `VPS_SSH_KEY` value into a new secret
   `VPS_BOOTSTRAP_SSH_KEY` (it is the key installed for root), then set `VPS_SSH_KEY` to the new
   `glowderma-<env>-deploy` private key. Delete both local files.
3. Actions → **Bootstrap server** → `<env>`. It pins the new key to the gate and drops any old unrestricted entry.
4. Actions → **Deploy staging** / **Deploy production** → Run workflow (from `main`) and check it goes green.

Until step 3 runs, deploys to that server fail at the SSH step (the old setup runs `deploy ...` as a shell
command, which does not exist); nothing on the server changes.

## GitHub settings to create (once)

### Repository `infra`

| Where | Name | Value |
|---|---|---|
| Environment `staging` | secret `VPS_HOST` | staging server IP or hostname |
| | secret `VPS_USERNAME` | `deploy` |
| | secret `VPS_BOOTSTRAP_SSH_KEY` | private key (ed25519) whose public half the provider installed for root; used only by **Bootstrap server** |
| | secret `VPS_SSH_KEY` | a **different** private key (ed25519): the deploy key, pinned by bootstrap to the deploy gate |
| | variable `VPS_HOST_KEY` | the server's host key, e.g. `ssh-ed25519 AAAA...` (verified out of band) |
| | variable `VPS_BOOTSTRAP_USER` | `root` (or a passwordless-sudo user) |
| Environment `production` | the same six, for the production server | |
| | protection: **required reviewers**, deployment branches: `main` only | |
| Repository variable | `INFRA_APP_CLIENT_ID` | Client ID of the GitOps GitHub App, below |
| Repository secret | `INFRA_APP_PRIVATE_KEY` | the App's private key (whole `.pem` file) |

### Repositories `backend` and `frontend`

| Where | Name | Value |
|---|---|---|
| Repository variable | `INFRA_APP_CLIENT_ID` | same Client ID |
| Repository secret | `INFRA_APP_PRIVATE_KEY` | same private key |
| Code security | CodeQL **default setup off** | the pipeline runs CodeQL itself (advanced setup) |

Frontend only: **GitHub environments** `staging` and `production` (Settings → Environments), each with the same
**environment variables**, because Next.js bakes these into the build. The pipeline builds one image per
environment from the same commit, and each matrix row reads only its own environment, so a value missing in one
environment fails the main build. Not repository variables: the build job would not see them.

| Variable | `staging` | `production` |
|---|---|---|
| `NEXT_PUBLIC_SITE_URL` (required) | `https://staging.glowderma.uz` | `https://glowderma.uz` |
| `GLOWDERMA_ALLOWED_ORIGINS` (required) | `staging.glowderma.uz` | `glowderma.uz` |
| `GLOWDERMA_MEDIA_HOSTS` (required) | `staging.glowderma.uz/media` | `glowderma.uz/media` |
| `GLOWDERMA_MEDIA_ALLOW_LOCAL` | unset | unset |

`GLOWDERMA_MEDIA_HOSTS` carries the `/media` prefix (same origin): the image optimiser then fetches only
`/media/**`. `GLOWDERMA_MEDIA_ALLOW_LOCAL=true` lifts the optimiser's private-IP guard and is for local
development only. The values must agree with `SITE_DOMAIN` in this repository's `environments/<env>/stack.env`.

Environment settings: no required reviewers (production is gated by this repository's Promote workflow; a
reviewer here would hold every production *build*). Deployment branches: `main` only is safe, pull requests
build with placeholders and attach no environment. The `staging` environment also hosts the `deploy` job.

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
the package, which the cleanup job needs). Then, in each package's settings (**Manage Actions access**), grant
the `infra` repository **Read**: the pre-deploy scan, the promote workflow and the deploy itself all pull with
infra's `GITHUB_TOKEN`. The packages stay **private**.

Servers hold **no registry credential**. The deploy job passes its own `GITHUB_TOKEN` (`packages: read`) to the
server over the SSH session's stdin; the server logs in to `ghcr.io` with it into a throwaway `DOCKER_CONFIG`
directory, pulls, and deletes that directory when the deploy ends. The token itself expires when the job ends.
GHCR accepts only classic PATs and `GITHUB_TOKEN` (no fine-grained PATs, no GitHub App tokens), and a
long-lived classic PAT on a server is exactly what this avoids.

Consequences:

- Run deploys through the workflows (`workflow_dispatch` re-runs one). Running `scripts/deploy.sh` by hand on
  the server (as root, `su deploy -c ...`) only works when every image is already pulled; `--restart` is fine,
  it pulls nothing.
- A server that was set up with a stored login should drop it: `docker logout ghcr.io` as the `deploy` user,
  then check that `~/.docker/config.json` has no `ghcr.io` entry. Revoke that PAT on GitHub.
