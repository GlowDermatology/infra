# Disaster recovery

Recovery objectives are **your decision**, not a guarantee of this setup. With the defaults below the
recovery point is at most 24 hours (nightly backup) plus whatever happened since the last pre-deploy dump,
and a full rebuild on a new server takes roughly an hour. Write the RPO/RTO you need here, then adjust the
backup frequency (the cron line in `/etc/cron.d/glowderma-backup`).

## What is backed up

`scripts/backup.sh <env> nightly` (cron, 02:15 Tashkent) writes into `/opt/glowderma/runtime/backups/`:

| File | Content | Restore with |
|---|---|---|
| `<env>-db-nightly-<time>.dump` | full PostgreSQL dump (custom format, verified) | `scripts/restore-postgres.sh` |
| `<env>-db-pre-deploy-<time>.dump` | dump taken before every backend release (kept 3 days) | same |
| `<env>-media-<time>.tar.gz` | uploaded media: the disk folder, or a mirror of the object storage bucket. Not written when media is on an external S3 provider (the job prints `media: external provider, not backed up here`) | by mode, below |
| `<env>-vault-<time>.snap` | Vault Raft snapshot (encrypted by Vault itself) | `vault operator raft snapshot restore` |

**Media by mode.**

- `USE_S3=false`: `tar -xzf <env>-media-<time>.tar.gz -C /opt/glowderma/runtime/media` (owned by 10001).
- The stack's own object storage (`OBJECT_STORAGE_ENABLED=true` and `USE_S3=true`): the nightly job first runs
  `aws s3 sync s3://glowderma-media/<S3_LOCATION> /mirror --delete` with the admin keys (read from the rendered
  secret files inside the container, never on a command line) into `/opt/glowderma/runtime/media-mirror`, then tars
  that mirror. Because of `--delete` the mirror equals the bucket at the last run; the older tarballs are the
  history. Restore: deploy first (it creates the object storage and the bucket), untar into a **separate**
  directory `runtime/media-restore` (owned by 999), never into `media-mirror`: a nightly backup running before the
  push would `sync --delete` the empty bucket over it. Then push it back (`media` is `S3_LOCATION` in
  `stack.env`) and remove the directory:

  ```bash
  sudo install -d -o 999 -g 999 -m 0700 /opt/glowderma/runtime/media-restore
  sudo tar -xzf <env>-media-<time>.tar.gz -C /opt/glowderma/runtime/media-restore
  sudo chown -R 999:999 /opt/glowderma/runtime/media-restore
  scripts/manage.sh <env> --profile object-storage-tools run --rm --no-deps -T \
    -v /opt/glowderma/runtime/media-restore:/restore:ro --entrypoint sh object-storage-init -c '
    export AWS_ACCESS_KEY_ID="$(cat /run/secrets/object_storage_admin_access_key)" \
           AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/object_storage_admin_secret_key)" AWS_DEFAULT_REGION=us-east-1
    aws --endpoint-url http://object-storage:8333 s3 sync /restore s3://glowderma-media/media'
  sudo rm -rf /opt/glowderma/runtime/media-restore
  ```

- An external S3 provider keeps its own copies (enable versioning there); nothing on this server restores it.

Local copies are kept 14 days (`GLOWDERMA_BACKUP_KEEP_DAYS`). Redis is not backed up: it holds cache and
in-flight Celery messages only.

## Off-host copies (required for real disaster recovery)

A backup on the same server is not a backup. In `/opt/glowderma/runtime/local.env`:

```
BACKUP_AGE_RECIPIENT=age1...                 # public key; generate with `age-keygen` on YOUR machine
BACKUP_RCLONE_REMOTE=offsite:glowderma/<env>  # an rclone remote on storage off this server
```

Configure the remote for the `deploy` user: `su deploy -c 'rclone config'`. With both set, every file is
encrypted with age before it leaves the server; plaintext is never copied off-host (the script refuses a remote
without a recipient). Keep the age private key in the password manager, never on the server.

## The offline kit (keep it outside every server)

- 3+ Vault unseal key shares (different people) and the way to generate a root token
- the age private key for the backups
- `vault/tls/ca.key` and `ca.crt` of each environment (optional: new ones can be generated)
- access to the DNS provider, the VPS provider and the GitHub organization

## Restore drills (do one per quarter, on staging)

1. `scripts/restore-postgres.sh staging <latest nightly dump>`; check the site.
2. Decrypt a production off-host copy on your machine (`age -d -i key.txt file.age > file`) and
   `pg_restore --list file` to prove it reads.
3. Record the date and the time it took here.

## Rebuilding a lost server

1. New VPS, same environment: run [first-server-runbook.md](first-server-runbook.md) steps 0–3.
2. Vault: `gen-tls.sh`, then **do not run init.sh**. Start Vault (`scripts/vault/unseal.sh <env>` starts it),
   run `vault operator init` only if you have no snapshot; otherwise initialise a temporary Vault, unseal it,
   and restore the snapshot:
   ```bash
   docker compose -p glowderma-<env>-vault -f compose/vault.yaml --env-file environments/<env>/stack.env \
     exec -T -e VAULT_TOKEN vault sh -c 'cat > /tmp/r.snap && vault operator raft snapshot restore -force /tmp/r.snap' \
     < <env>-vault-<time>.snap
   ```
   After a forced restore the ORIGINAL unseal keys apply again: unseal with them.
3. `scripts/vault/configure.sh <env>` (as root): it writes fresh AppRole credentials for this server (the
   previous server's secret_ids can be revoked: `rotate-approle-secret-id.sh`).
4. Restore media by mode (above): into `/opt/glowderma/runtime/media` (owned by 10001) for the disk; for the object
   storage, into `runtime/media-restore` now and push it into the bucket after step 5.
5. Deploy (workflow). The database starts empty, then `scripts/restore-postgres.sh <env> <dump>`.
6. Move DNS. Run `scripts/healthcheck.sh <env>`.

If the Vault snapshot is lost too: initialise a new Vault, run `generate-app-secrets.sh`, then put back every
provider credential from their dashboards. Note that the old `SECRETBOX_KEY`, `JWT_SIGNING_KEYS` and HMAC keys
are then gone: encrypted fields become unreadable, sessions and QR tokens are invalidated. That is why the Vault
snapshot is part of every nightly backup.

## Recovery checklist

- [ ] `scripts/healthcheck.sh <env>` all ok
- [ ] staff can sign in to `/admin`; the ops console opens from an allowed IP
- [ ] a customer page shows products and images (`/media/`)
- [ ] `scripts/manage.sh <env> django consistency_report` clean
- [ ] next nightly backup ran and was copied off-host (`backups/backup.log`)
