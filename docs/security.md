# Security

## Boundaries

| Actor | Can | Cannot |
|---|---|---|
| App repo workflows | build/push their own image, commit `environments/staging/<app>/image.env` | reach a server, read any secret, write production |
| Promote workflow | commit `environments/production/*/image.env` (verified digests only) | deploy without a reviewer |
| Deploy workflows | SSH as `deploy`, run `scripts/deploy.sh` at a given infra commit | read Vault secrets (they are rendered on the server) |
| `deploy` user | Docker (root-equivalent on that host) | anything on the other environment's server |
| Application containers | read their own rendered secret files | reach Vault's token, AppRole files, the Docker socket |

The `deploy` user is in the `docker` group, which is root-equivalent on that server: protect `VPS_SSH_KEY`
accordingly (environment secret, production behind reviewers).

## Container hardening (enforced by `scripts/validate.sh`)

- images pinned by digest (`name:tag@sha256:…`), never `latest`
- explicit non-root user for every service, read-only root filesystem with explicit tmpfs/volumes
- `cap_drop: [ALL]`, `no-new-privileges`, no `privileged`, no `cap_add`, no Docker socket
- only the edge publishes ports (80/tcp, 443/tcp, 443/udp); PostgreSQL and Redis on an internal network
- memory and PID limits, health checks, log rotation
- no Vault variable or AppRole mount in any application container

## Supply chain

- every GitHub Action pinned to a full commit SHA (tags are mutable: the trivy-action tag hijack of March
  2026 is the reason); every scanner runs from an image pinned by digest
- app images carry SBOM + SLSA provenance attestations; Promote verifies the attestation was produced by the
  app's `ci.yml` on `main` before production can use the image
- servers pull by digest only

## Scanners

| Where | Scanner | Target | Blocks on |
|---|---|---|---|
| app, stage 1 | gitleaks | full git history | any secret |
| app, stage 1 | semgrep | source (SAST) | ERROR findings |
| app, stage 1 | CodeQL `security-extended` | source (dataflow SAST) | high/critical alerts |
| app, stage 1 | trivy fs | lockfiles, source | fixable HIGH/CRITICAL CVE, secret |
| app, stage 1 | pip-audit / npm audit | runtime dependencies | fixable vulnerability |
| app, stage 1 | hadolint, zizmor, trivy config | Dockerfile, workflows | warning / medium+ / HIGH |
| app, image-scan | trivy image | pushed digest | fixable HIGH/CRITICAL CVE, secret |
| app, image-scan | grype | pushed digest | fixable HIGH/CRITICAL CVE |
| app, image-scan | dockle | pushed digest | CIS image FATAL/WARN |
| infra, validate | actionlint, zizmor, shellcheck, gitleaks, semgrep, trivy config, structural rules | this repository | any |
| infra, validate | Vault end-to-end test | policies and templates | any wrong allow/deny |
| infra, pre-deploy | trivy image, fresh database | both digests of the target environment | fixable HIGH/CRITICAL (`report` for rollbacks) |
| infra, weekly | trivy image | what both environments run | opens an issue |

Results go to each repository's Security tab (SARIF, one category per scanner and target). An ignore entry
(`.trivyignore`, `.semgrepignore`, `# nosemgrep`) needs a comment with the reason and a review date.

## Vault

TLS always on and always verified (own CA); no published port; administration from the host only; Raft
storage; audit device enabled; one AppRole per consumer group with read-only policies on exact paths; no
token sink; unseal keys and root token never stored on a server or in GitHub. A shared Vault would be a single
security and availability boundary for both environments: that is why each environment has its own.

## Network

Caddy: TLS 1.2+ (ACME), HSTS, HTTP/3, request size limits, header/body timeouts, X-Forwarded-For overwritten,
query strings and token headers redacted from logs. ufw allows 22, 80, 443/tcp, 443/udp. SSH: keys only,
fail2ban. Note: Docker programs its own firewall rules for published ports; only the edge publishes any.

## Accepted risks (documented, not fixed)

- `deploy` in the `docker` group is root-equivalent on its server.
- The GitOps App private key does not expire and is stored as a secret in three repositories; the tokens
  minted from it live one hour and can only write contents of `infra`.
- `/api/revalidate` (Next) is reachable from the internet; it is protected by a bearer secret.
- The ops console CSP needs `'unsafe-eval'` (Alpine.js in django-unfold).
