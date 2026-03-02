#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CI_MODE="${CI:-0}"
SKIP_BOOT="${SKIP_BOOT:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-1}"
KEEP_BACKUP="${KEEP_BACKUP:-1}"
BACKUP_ROOT="${BACKUP_ROOT:-/tmp/audistro-restore-drill-$(date +%Y%m%d%H%M%S)}"
DEFAULT_WAIT_SECONDS=180
if [ "$CI_MODE" = "1" ]; then
  DEFAULT_WAIT_SECONDS=120
fi
WAIT_SECONDS="${WAIT_SECONDS:-$DEFAULT_WAIT_SECONDS}"
CATALOG_URL="${CATALOG_URL:-http://localhost:18080}"
FAP_URL="${FAP_URL:-http://localhost:18081}"
PROVIDER_URL="${PROVIDER_URL:-http://localhost:18082}"
LNBITS_URL="${LNBITS_URL:-http://localhost:18090}"
PAID_SMOKE_LOG="$(mktemp)"

log() {
  printf '[backup-restore-drill] %s\n' "$*"
}

fail() {
  printf '[backup-restore-drill] FAIL: %s\n' "$*" >&2
  exit 1
}

skip() {
  printf '[backup-restore-drill] SKIP: %s\n' "$*"
  exit 0
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

compose() {
  docker compose "$@"
}

wait_http_200() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while :; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    if [ "$code" = "200" ]; then
      log "PASS: ${name} is ready"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "timeout waiting for ${name} at ${url} (last code=${code})"
    fi
    sleep 1
  done
}

service_cid() {
  local service="$1"
  local cid
  cid="$(compose ps -q "$service" | head -n1)"
  [ -n "$cid" ] || fail "container not found for service: $service"
  printf '%s' "$cid"
}

service_volume() {
  local service="$1"
  local destination="$2"
  local cid
  cid="$(service_cid "$service")"
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$destination"'"}}{{.Name}}{{end}}{{end}}' "$cid"
}

copy_volume_to_dir() {
  local volume_name="$1"
  local dest_dir="$2"
  mkdir -p "$dest_dir"
  docker run --rm \
    -v "${volume_name}:/from:ro" \
    -v "${dest_dir}:/to" \
    alpine:3.20 \
    sh -lc 'cd /from && tar cf - . | tar xf - -C /to'
}

restore_dir_to_volume() {
  local src_dir="$1"
  local volume_name="$2"
  docker run --rm \
    -v "${src_dir}:/from:ro" \
    -v "${volume_name}:/to" \
    alpine:3.20 \
    sh -lc 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cd /from && tar cf - . | tar xf - -C /to'
}

read_env_file_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

relative_to_mount() {
  local full_path="$1"
  local mount_path="$2"
  python3 - "$full_path" "$mount_path" <<'PY'
import os
import sys
full_path = sys.argv[1]
mount_path = sys.argv[2]
print(os.path.relpath(full_path, mount_path))
PY
}

sqlite_scalar() {
  local db_path="$1"
  local sql="$2"
  python3 - "$db_path" "$sql" <<'PY'
import sqlite3
import sys

db_path = sys.argv[1]
sql = sys.argv[2]
con = sqlite3.connect(db_path)
try:
    row = con.execute(sql).fetchone()
    value = row[0] if row else 0
    print(value)
finally:
    con.close()
PY
}

provider_asset_count() {
  local provider_dir="$1"
  python3 - "$provider_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / 'assets'
if not root.exists():
    print(0)
else:
    print(sum(1 for p in root.iterdir() if p.is_dir()))
PY
}

stop_services() {
  compose stop audistro-web audistro-catalog-worker audistro-catalog audistro-fap audistro-provider_eu_1 audistro-provider_eu_2 audistro-provider_us_1 lnbits >/dev/null
}

start_stack_if_needed() {
  if [ "$SKIP_BOOT" != "1" ]; then
    log 'Starting compose stack'
    compose up -d --build
  fi
  wait_http_200 'audistro-catalog /healthz' "${CATALOG_URL%/}/healthz"
  wait_http_200 'audistro-fap /healthz' "${FAP_URL%/}/healthz"
  wait_http_200 'audistro-provider /readyz' "${PROVIDER_URL%/}/readyz"
  wait_http_200 'lnbits /' "${LNBITS_URL%/}/"
}

capture_baseline() {
  mkdir -p "$BACKUP_ROOT/original" "$BACKUP_ROOT/restored"

  local catalog_volume fap_volume eu1_volume eu2_volume us1_volume lnbits_volume
  catalog_volume="$(service_volume audistro-catalog /var/lib/audistro-catalog)"
  fap_volume="$(service_volume audistro-fap /var/lib/fap)"
  eu1_volume="$(service_volume audistro-provider_eu_1 /var/lib/audistro-provider)"
  eu2_volume="$(service_volume audistro-provider_eu_2 /var/lib/audistro-provider)"
  us1_volume="$(service_volume audistro-provider_us_1 /var/lib/audistro-provider)"
  lnbits_volume="$(service_volume lnbits /data)"

  [ -n "$catalog_volume" ] || fail 'missing catalog volume'
  [ -n "$fap_volume" ] || fail 'missing fap volume'
  [ -n "$eu1_volume" ] || fail 'missing provider eu_1 volume'
  [ -n "$eu2_volume" ] || fail 'missing provider eu_2 volume'
  [ -n "$us1_volume" ] || fail 'missing provider us_1 volume'
  [ -n "$lnbits_volume" ] || fail 'missing lnbits volume'

  log 'Stopping stack for a quiesced backup snapshot'
  stop_services

  log 'Copying volumes into backup workspace'
  copy_volume_to_dir "$catalog_volume" "$BACKUP_ROOT/original/catalog"
  copy_volume_to_dir "$fap_volume" "$BACKUP_ROOT/original/fap"
  copy_volume_to_dir "$eu1_volume" "$BACKUP_ROOT/original/provider_eu_1"
  copy_volume_to_dir "$eu2_volume" "$BACKUP_ROOT/original/provider_eu_2"
  copy_volume_to_dir "$us1_volume" "$BACKUP_ROOT/original/provider_us_1"
  copy_volume_to_dir "$lnbits_volume" "$BACKUP_ROOT/original/lnbits"

  local catalog_db_path fap_db_path
  catalog_db_path="$(read_env_file_value "$ROOT_DIR/env/audistro-catalog.env" 'AUDICATALOG_DB_PATH')"
  fap_db_path="$(read_env_file_value "$ROOT_DIR/env/fap.env" 'FAP_DB_PATH')"
  [ -n "$catalog_db_path" ] || fail 'AUDICATALOG_DB_PATH missing'
  [ -n "$fap_db_path" ] || fail 'FAP_DB_PATH missing'

  local catalog_db_rel fap_db_rel
  catalog_db_rel="$(relative_to_mount "$catalog_db_path" '/var/lib/audistro-catalog')"
  fap_db_rel="$(relative_to_mount "$fap_db_path" '/var/lib/fap')"

  BASELINE_FAP_PAID_COUNT="$(sqlite_scalar "$BACKUP_ROOT/original/fap/$fap_db_rel" "select count(*) from ledger_entries where status='paid';")"
  BASELINE_CATALOG_ASSET_COUNT="$(sqlite_scalar "$BACKUP_ROOT/original/catalog/$catalog_db_rel" "select count(*) from assets;")"
  BASELINE_CATALOG_INGEST_COUNT="$(sqlite_scalar "$BACKUP_ROOT/original/catalog/$catalog_db_rel" "select count(*) from ingest_jobs;")"
  BASELINE_PROVIDER_EU1_ASSET_DIRS="$(provider_asset_count "$BACKUP_ROOT/original/provider_eu_1")"
  BASELINE_PROVIDER_EU2_ASSET_DIRS="$(provider_asset_count "$BACKUP_ROOT/original/provider_eu_2")"

  [ "$BASELINE_FAP_PAID_COUNT" -gt 0 ] || fail 'baseline has no paid ledger entries; restore drill needs at least one paid entry'

  log "Baseline counts: fap_paid=${BASELINE_FAP_PAID_COUNT} catalog_assets=${BASELINE_CATALOG_ASSET_COUNT} ingest_jobs=${BASELINE_CATALOG_INGEST_COUNT} eu1_assets=${BASELINE_PROVIDER_EU1_ASSET_DIRS} eu2_assets=${BASELINE_PROVIDER_EU2_ASSET_DIRS}"

  printf '%s\n' "$catalog_db_rel" > "$BACKUP_ROOT/catalog_db_rel.txt"
  printf '%s\n' "$fap_db_rel" > "$BACKUP_ROOT/fap_db_rel.txt"
}

restore_and_verify() {
  log 'Tearing down stack and deleting live volumes'
  compose down -v

  log 'Recreating empty stack for restore targets'
  compose up -d --build
  sleep 3
  stop_services

  local catalog_volume fap_volume eu1_volume eu2_volume us1_volume lnbits_volume
  catalog_volume="$(service_volume audistro-catalog /var/lib/audistro-catalog)"
  fap_volume="$(service_volume audistro-fap /var/lib/fap)"
  eu1_volume="$(service_volume audistro-provider_eu_1 /var/lib/audistro-provider)"
  eu2_volume="$(service_volume audistro-provider_eu_2 /var/lib/audistro-provider)"
  us1_volume="$(service_volume audistro-provider_us_1 /var/lib/audistro-provider)"
  lnbits_volume="$(service_volume lnbits /data)"

  log 'Restoring backup into fresh volumes'
  restore_dir_to_volume "$BACKUP_ROOT/original/catalog" "$catalog_volume"
  restore_dir_to_volume "$BACKUP_ROOT/original/fap" "$fap_volume"
  restore_dir_to_volume "$BACKUP_ROOT/original/provider_eu_1" "$eu1_volume"
  restore_dir_to_volume "$BACKUP_ROOT/original/provider_eu_2" "$eu2_volume"
  restore_dir_to_volume "$BACKUP_ROOT/original/provider_us_1" "$us1_volume"
  restore_dir_to_volume "$BACKUP_ROOT/original/lnbits" "$lnbits_volume"

  log 'Booting restored stack'
  compose up -d
  wait_http_200 'restored audistro-catalog /healthz' "${CATALOG_URL%/}/healthz"
  wait_http_200 'restored audistro-fap /healthz' "${FAP_URL%/}/healthz"
  wait_http_200 'restored audistro-provider /readyz' "${PROVIDER_URL%/}/readyz"

  stop_services

  log 'Capturing restored volumes for integrity comparison'
  copy_volume_to_dir "$catalog_volume" "$BACKUP_ROOT/restored/catalog"
  copy_volume_to_dir "$fap_volume" "$BACKUP_ROOT/restored/fap"
  copy_volume_to_dir "$eu1_volume" "$BACKUP_ROOT/restored/provider_eu_1"
  copy_volume_to_dir "$eu2_volume" "$BACKUP_ROOT/restored/provider_eu_2"

  local catalog_db_rel fap_db_rel
  catalog_db_rel="$(cat "$BACKUP_ROOT/catalog_db_rel.txt")"
  fap_db_rel="$(cat "$BACKUP_ROOT/fap_db_rel.txt")"

  local restored_fap_paid restored_catalog_assets restored_catalog_ingest restored_eu1_assets restored_eu2_assets
  restored_fap_paid="$(sqlite_scalar "$BACKUP_ROOT/restored/fap/$fap_db_rel" "select count(*) from ledger_entries where status='paid';")"
  restored_catalog_assets="$(sqlite_scalar "$BACKUP_ROOT/restored/catalog/$catalog_db_rel" "select count(*) from assets;")"
  restored_catalog_ingest="$(sqlite_scalar "$BACKUP_ROOT/restored/catalog/$catalog_db_rel" "select count(*) from ingest_jobs;")"
  restored_eu1_assets="$(provider_asset_count "$BACKUP_ROOT/restored/provider_eu_1")"
  restored_eu2_assets="$(provider_asset_count "$BACKUP_ROOT/restored/provider_eu_2")"

  [ "$restored_fap_paid" = "$BASELINE_FAP_PAID_COUNT" ] || fail "restored paid ledger count mismatch: expected ${BASELINE_FAP_PAID_COUNT}, got ${restored_fap_paid}"
  [ "$restored_catalog_assets" = "$BASELINE_CATALOG_ASSET_COUNT" ] || fail "restored catalog asset count mismatch: expected ${BASELINE_CATALOG_ASSET_COUNT}, got ${restored_catalog_assets}"
  [ "$restored_catalog_ingest" = "$BASELINE_CATALOG_INGEST_COUNT" ] || fail "restored ingest count mismatch: expected ${BASELINE_CATALOG_INGEST_COUNT}, got ${restored_catalog_ingest}"
  [ "$restored_eu1_assets" = "$BASELINE_PROVIDER_EU1_ASSET_DIRS" ] || fail "restored provider eu_1 asset dir count mismatch: expected ${BASELINE_PROVIDER_EU1_ASSET_DIRS}, got ${restored_eu1_assets}"
  [ "$restored_eu2_assets" = "$BASELINE_PROVIDER_EU2_ASSET_DIRS" ] || fail "restored provider eu_2 asset dir count mismatch: expected ${BASELINE_PROVIDER_EU2_ASSET_DIRS}, got ${restored_eu2_assets}"

  log 'PASS: restore drill validated ledger, catalog, and provider counts'
  compose up -d >/dev/null
}

cleanup() {
  rm -f "$PAID_SMOKE_LOG"
  if [ "$KEEP_BACKUP" != '1' ] && [ -d "$BACKUP_ROOT" ]; then
    rm -rf "$BACKUP_ROOT"
  fi
}
trap cleanup EXIT

need_cmd docker
need_cmd curl
need_cmd python3
need_cmd tar

start_stack_if_needed

log 'Creating a paid ledger baseline via smoke-paid-access.sh'
if ! env CI="$CI_MODE" SKIP_MANUAL="$SKIP_MANUAL" ./scripts/smoke-paid-access.sh >"$PAID_SMOKE_LOG" 2>&1; then
  cat "$PAID_SMOKE_LOG" >&2
  fail 'smoke-paid-access.sh failed; restore drill baseline was not created'
fi
if grep -q '^\[smoke-paid-access\] SKIP:' "$PAID_SMOKE_LOG"; then
  cat "$PAID_SMOKE_LOG"
  skip 'paid baseline could not be created because required LNbits secrets are unavailable'
fi
log 'PASS: paid ledger baseline created'

capture_baseline
restore_and_verify

log "Artifacts kept in ${BACKUP_ROOT}"
log 'PASS: backup/restore drill completed'
