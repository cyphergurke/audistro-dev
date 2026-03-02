# Decentralization V1: Primary + Read-Only Catalog Mirrors

This v1 model keeps exactly one writable catalog and adds read-only mirrors for browse/playback continuity.

## Model

- `audistro-catalog` is the single writer.
- `audistro-catalog-mirror` is read-only.
- provider registration and provider announce writes still go only to the primary catalog.
- web GET requests can fall back from primary to mirror for catalog reads.

## Why Not Multi-Writer

v1 intentionally avoids:
- conflict resolution between concurrent catalog writers
- distributed migrations
- provider registry write ordering across regions
- asset/payee/admin mutation consensus

The goal is continuity for read traffic, not distributed writes.

## Replication

Current replication is snapshot-based:
- `audicatalog-snapshot export` creates a consistent SQLite snapshot.
- `audicatalog-snapshot import` replaces a mirror DB file atomically for offline restore.
- `audicatalog-snapshot sync` copies the live primary DB into the mirror DB in place for periodic dev replication.

In dev compose:
- primary DB volume: `audistro-catalog_data`
- mirror DB volume: `audistro-catalog_mirror_data`
- `audistro-catalog-replicator` syncs primary -> mirror every `CATALOG_REPLICATION_INTERVAL_SECONDS`

## Caveats

- mirror freshness is bounded by the replication interval
- mirror is for browse/playback reads only
- admin and mutation routes stay primary-only
- if the primary is down, playback can continue from mirror, but new writes and provider announces cannot

## Dev Verification

Start the stack:

```bash
cd /home/goku/code/audistro-dev
docker compose up -d --build
```

Catalog ports:
- primary: `http://localhost:18080`
- mirror: `http://localhost:18091`

Verify mirror playback data:

```bash
curl -fsS http://localhost:18080/v1/playback/<assetId>
curl -fsS http://localhost:18091/v1/playback/<assetId>
```

Kill the primary and confirm playback still resolves through the mirror-backed web fallback:

```bash
docker compose stop audistro-catalog
curl -fsS http://localhost:3000/api/playback/<assetId>
```
