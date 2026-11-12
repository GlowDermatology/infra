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

### The deploy gate (what the deploy key can do)

`VPS_SSH_KEY` opens no shell. Bootstrap pins it in `~deploy/.ssh/authorized_keys` with
`restrict,command="/usr/local/sbin/glowderma-deploy-gate"`, a root-owned copy of
[scripts/deploy-gate.sh](../scripts/deploy-gate.sh), and removes it from root's `authorized_keys`. Whatever a
client sends, sshd runs the gate, which accepts two requests: `deploy <env> <40-hex commit> <ghcr-user>`, only
for a commit already on `origin/main`, and `restart <env> <backend|frontend|all>` (below). A leaked deploy key
can therefore only redeploy something on `main` or restart the apps.
Root access needs `VPS_BOOTSTRAP_SSH_KEY`, which only the Bootstrap workflow uses; you can remove that secret
between bootstraps and add it back when you need one.

Consequences: deploys run from `main` only (a `workflow_dispatch` from another branch is refused by the gate),
and a change to the gate takes effect on a server after **Bootstrap server** runs again (it installs the gate
from `origin/main`).

### Restart: reload settings and secrets from Vault

After changing `secret/<env>/django` or `secret/<env>/frontend` (Vault UI, `vault kv patch`): Actions →
**Restart** → environment + target (`backend`, `frontend`, `all`). Through the gate it runs
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
