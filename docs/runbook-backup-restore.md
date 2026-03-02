# Runbook: Backup And Restore

This runbook covers the current SQLite-backed audistro stack:
- `audistro-catalog`
- `audistro-fap`
- `audistro-provider_*`
- `lnbits`

The source of truth for remaining production gaps stays in [`docs/prod-todos.md`](./prod-todos.md).

## Scope

Back up all persistent data together:
- Catalog: `/var/lib/audistro-catalog`
- FAP: `/var/lib/fap`
- Provider volumes: `/var/lib/audistro-provider`
- LNbits: `/data`
- Secret files used by the deployment:
  - `secrets/fap_token_secret`
  - `secrets/origin_hmac_secret`
  - deployment-managed admin tokens and webhook secrets

## Preconditions

- Stop writes or take an atomic snapshot before calling a backup valid.
- Keep the service env files and secret values that match the backed-up volumes.
- Treat provider assets and provider identity state as part of the same restore unit.

## Local Drill

Preferred local drill:

```bash
cd /home/goku/code/audistro-dev
LNBITS_PAYER_ADMIN_KEY=... \
LNBITS_INVOICE_KEY=... \
LNBITS_READ_KEY=... \
./scripts/backup-restore-drill.sh
```

What it does:
1. Starts the dev compose stack.
2. Creates a paid ledger baseline through `smoke-paid-access.sh`.
3. Stops writes and copies the Catalog, FAP, Provider, and LNbits volumes into a host backup directory.
4. Destroys the live volumes.
5. Recreates empty volumes and restores the copied data.
6. Verifies that the restored stack still contains the same paid-ledger count, catalog asset count, ingest-job count, and provider asset-directory counts.

Useful flags:
- `SKIP_BOOT=1`: use an already running stack.
- `KEEP_BACKUP=0`: delete the temporary backup directory after success.
- `BACKUP_ROOT=/tmp/my-drill`: choose an explicit output path.

## Manual Backup Procedure

1. Quiesce the stack.

```bash
cd /home/goku/code/audistro-dev
docker compose stop audistro-web audistro-catalog-worker audistro-catalog audistro-fap audistro-provider_eu_1 audistro-provider_eu_2 audistro-provider_us_1 lnbits
```

2. Copy the persistent volumes.

```bash
mkdir -p /tmp/audistro-backup/{catalog,fap,provider_eu_1,provider_eu_2,provider_us_1,lnbits}

docker run --rm -v audistro-dev_audistro-catalog_data:/from:ro -v /tmp/audistro-backup/catalog:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v audistro-dev_fap_data:/from:ro -v /tmp/audistro-backup/fap:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v audistro-dev_audistro-provider_eu_1_data:/from:ro -v /tmp/audistro-backup/provider_eu_1:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v audistro-dev_audistro-provider_eu_2_data:/from:ro -v /tmp/audistro-backup/provider_eu_2:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v audistro-dev_audistro-provider_us_1_data:/from:ro -v /tmp/audistro-backup/provider_us_1:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v audistro-dev_lnbits_data:/from:ro -v /tmp/audistro-backup/lnbits:/to alpine:3.20 sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
```

3. Back up the matching secrets and env files outside git.

## Manual Restore Procedure

1. Tear down the stack and remove the target volumes.

```bash
cd /home/goku/code/audistro-dev
docker compose down -v
```

2. Recreate empty target volumes.

```bash
docker compose up -d --build
docker compose stop audistro-web audistro-catalog-worker audistro-catalog audistro-fap audistro-provider_eu_1 audistro-provider_eu_2 audistro-provider_us_1 lnbits
```

3. Restore the copied volume contents.

```bash
docker run --rm -v /tmp/audistro-backup/catalog:/from:ro -v audistro-dev_audistro-catalog_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v /tmp/audistro-backup/fap:/from:ro -v audistro-dev_fap_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v /tmp/audistro-backup/provider_eu_1:/from:ro -v audistro-dev_audistro-provider_eu_1_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v /tmp/audistro-backup/provider_eu_2:/from:ro -v audistro-dev_audistro-provider_eu_2_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v /tmp/audistro-backup/provider_us_1:/from:ro -v audistro-dev_audistro-provider_us_1_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
docker run --rm -v /tmp/audistro-backup/lnbits:/from:ro -v audistro-dev_lnbits_data:/to alpine:3.20 sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
```

4. Restore the exact matching secret files.
5. Bring the stack back.

```bash
docker compose up -d
```

## Restore Drill Checklist

After restore, verify at minimum:
- `curl -fsS http://localhost:18080/healthz`
- `curl -fsS http://localhost:18081/healthz`
- `curl -fsS http://localhost:18082/readyz`
- known paid ledger entries still exist in FAP
- known assets still exist in Catalog
- provider asset directories still exist on `eu_1` and `eu_2`
- the original secret files are still the ones the services expect

## Failure Notes

- If the restored stack is healthy but counts differ, treat the restore as failed.
- If provider assets restore but provider identity changes, treat the restore as failed.
- If FAP secrets differ from the backup epoch, existing token/key behavior may become invalid even when `/healthz` is green.
