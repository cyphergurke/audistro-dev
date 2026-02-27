#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ASSET_ID="${ASSET_ID:-asset1}"
ARTIST_ID="${ARTIST_ID:-artist_smoke_asset1}"
ARTIST_HANDLE="${ARTIST_HANDLE:-smokeasset1}"
PAYEE_ID="${PAYEE_ID:-payee_smoke_asset1}"
FAP_PAYEE_ID="${FAP_PAYEE_ID:-fap_asset1}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

CATALOG_URL="http://localhost:18080"
FAP_URL="http://localhost:18081"
PROVIDER_EU_1_URL="http://localhost:18082"
PROVIDER_EU_2_URL="http://localhost:18083"
PROVIDER_US_1_URL="http://localhost:18084"

PROVIDER_EU_1_SERVICE="audistro-provider_eu_1"
PROVIDER_EU_2_SERVICE="audistro-provider_eu_2"
PROVIDER_US_1_SERVICE="audistro-provider_us_1"

PROVIDER_EU_1_PRIORITY=10
PROVIDER_EU_2_PRIORITY=20

BROKEN_PROVIDER_BASE_URL="${PROVIDER_EU_2_URL}/assets/${ASSET_ID}"

log() {
  printf '[smoke-e2e] %s\n' "$*"
}

fail() {
  printf '[smoke-e2e] FAIL: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
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

json_get() {
  local field="$1"
  local payload="$2"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r "$field"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_FIELD="$field" JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os

field = os.environ["JSON_FIELD"]
payload = os.environ["JSON_PAYLOAD"]
obj = json.loads(payload)

if field.startswith("."):
    field = field[1:]
parts = [p for p in field.split(".") if p]
value = obj
for part in parts:
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
    return 0
  fi

  fail "jq or python3 is required to parse JSON"
}

playback_provider_lines() {
  local payload="$1"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r '.providers[]? | "\(.provider_id)|\(.base_url)"'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_PAYLOAD"])
for provider in payload.get("providers") or []:
    pid = provider.get("provider_id", "")
    base = provider.get("base_url", "")
    print(f"{pid}|{base}")
PY
    return 0
  fi

  fail "jq or python3 is required to parse provider list"
}

playback_provider_count() {
  local payload="$1"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq '.providers | length'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="$payload" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_PAYLOAD"])
print(len(payload.get("providers") or []))
PY
    return 0
  fi

  fail "jq or python3 is required to parse provider count"
}

service_cid() {
  local service="$1"
  local cid
  cid="$(compose ps -q "$service" | head -n1)"
  if [ -z "$cid" ]; then
    fail "container not found for service: $service"
  fi
  printf '%s' "$cid"
}

exec_in() {
  local cid="$1"
  shift
  docker exec -i "$cid" sh -lc "$*"
}

catalog_sql() {
  local sql="$1"
  exec_in "$CATALOG_CID" "sqlite3 \"$AUDICATALOG_DB_PATH\" \"$sql\""
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

require_table() {
  local table="$1"
  printf '%s\n' "$CATALOG_TABLES" | tr ' ' '\n' | grep -Fx "$table" >/dev/null 2>&1 || fail "required table missing in audistro-catalog DB: $table"
}

require_column() {
  local table="$1"
  local column="$2"
  local cols
  cols="$(catalog_sql "PRAGMA table_info(${table});")"
  printf '%s\n' "$cols" | awk -F'|' '{print $2}' | grep -Fx "$column" >/dev/null 2>&1 || fail "required column missing: ${table}.${column}"
}

resolve_playlist_url() {
  local provider_base_url="$1"
  local asset_id="$2"
  local trimmed
  trimmed="${provider_base_url%/}"

  if [[ "$trimmed" == */assets/${asset_id} ]]; then
    printf '%s/master.m3u8' "$trimmed"
  else
    printf '%s/assets/%s/master.m3u8' "$trimmed" "$asset_id"
  fi
}

first_segment_ref_from_playlist() {
  local playlist_file="$1"
  awk '/^[^#[:space:]]/ {print; exit}' "$playlist_file"
}

ref_to_absolute_url() {
  local playlist_url="$1"
  local ref="$2"

  case "$ref" in
    http://*|https://*)
      printf '%s' "$ref"
      return 0
      ;;
    /*)
      local origin
      origin="$(printf '%s' "$playlist_url" | sed -E 's#(https?://[^/]+).*#\1#')"
      printf '%s%s' "$origin" "$ref"
      return 0
      ;;
    *)
      local dir
      dir="${playlist_url%/*}"
      printf '%s/%s' "$dir" "$ref"
      return 0
      ;;
  esac
}

generate_hls_fixture() {
  local asset_id="$1"
  local provider_cid="$2"
  local provider_data_path="$3"
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  if ! docker run --rm -v "${tmp_dir}:/out" jrottenberg/ffmpeg:6.0-alpine \
    -y -f lavfi -i 'sine=frequency=440:duration=8' \
    -c:a aac -b:a 128k \
    -f hls -hls_time 2 -hls_playlist_type vod \
    -hls_segment_filename /out/seg_%04d.ts \
    /out/master.m3u8 >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    fail "failed to generate HLS fixture via ffmpeg container"
  fi

  [ -s "${tmp_dir}/master.m3u8" ] || {
    rm -rf "$tmp_dir"
    fail "generated master.m3u8 is missing"
  }

  ls "${tmp_dir}"/seg_*.ts >/dev/null 2>&1 || {
    rm -rf "$tmp_dir"
    fail "generated HLS fixture has no .ts segments"
  }

  local asset_dir="${provider_data_path}/assets/${asset_id}"
  docker exec -i "$provider_cid" sh -lc "mkdir -p \"$asset_dir\" && rm -f \"$asset_dir\"/master.m3u8 \"$asset_dir\"/seg_*.ts"
  docker cp "${tmp_dir}/." "${provider_cid}:${asset_dir}/"
  rm -rf "$tmp_dir"
}

inject_broken_segment() {
  local asset_id="$1"
  local provider_cid="$2"
  local provider_data_path="$3"

  local master_file
  master_file="$(mktemp)"
  docker exec "$provider_cid" sh -lc "cat \"${provider_data_path}/assets/${asset_id}/master.m3u8\"" >"$master_file"

  local seg_ref
  seg_ref="$(first_segment_ref_from_playlist "$master_file")"
  rm -f "$master_file"

  [ -n "$seg_ref" ] || fail "broken-provider master playlist has no segment reference"
  local seg_name
  seg_name="$(basename "$seg_ref")"

  docker exec "$provider_cid" sh -lc "rm -f \"${provider_data_path}/assets/${asset_id}/${seg_name}\""
  log "Injected deterministic failure on ${PROVIDER_EU_2_SERVICE}: removed segment ${seg_name}"
}

trigger_rescan_announce() {
  local provider_service="$1"
  local provider_cid="$2"
  local asset_id="$3"
  local require_attempt="$4"

  local rescan_json
  rescan_json="$(docker exec -i "$provider_cid" sh -lc '
if command -v curl >/dev/null 2>&1; then
  curl -fsS -X POST http://127.0.0.1:8080/internal/rescan
elif command -v wget >/dev/null 2>&1; then
  wget -qO- --method=POST http://127.0.0.1:8080/internal/rescan
else
  echo "missing curl/wget in provider container" >&2
  exit 1
fi
')"

  local scanned_assets
  scanned_assets="$(json_get '.scanned_assets' "$rescan_json")"
  [ -n "$scanned_assets" ] && [ "$scanned_assets" != "null" ] || fail "unexpected rescan response from ${provider_service}: ${rescan_json}"
  log "PASS: ${provider_service} rescan triggered (scanned_assets=${scanned_assets})"

  local announce_json
  announce_json="$(docker exec -e ASSET_ID="$asset_id" -i "$provider_cid" sh -lc '
if command -v curl >/dev/null 2>&1; then
  curl -fsS -H "Content-Type: application/json" -d "{\"asset_id\":\"${ASSET_ID}\"}" http://127.0.0.1:8080/internal/announce
elif command -v wget >/dev/null 2>&1; then
  wget -qO- --header="Content-Type: application/json" --post-data="{\"asset_id\":\"${ASSET_ID}\"}" http://127.0.0.1:8080/internal/announce
else
  echo "missing curl/wget in provider container" >&2
  exit 1
fi
')"

  local attempted
  attempted="$(json_get '.attempted' "$announce_json")"
  [ -n "$attempted" ] && [ "$attempted" != "null" ] || fail "unexpected announce response from ${provider_service}: ${announce_json}"

  if [ "$require_attempt" = "yes" ] && [ "$attempted" -lt 1 ]; then
    fail "announce attempted=0 for required provider ${provider_service}: ${announce_json}"
  fi

  log "PASS: ${provider_service} announce triggered (attempted=${attempted})"
}

upsert_provider_registry_rows() {
  local provider_id="$1"
  local public_key="$2"
  local public_base_url="$3"
  local region="$4"
  local priority="$5"

  local now_unix expires_at nonce base_url
  now_unix="$(date +%s)"
  expires_at="$((now_unix + 600))"
  nonce="$(printf 'smoke%08x' "$now_unix")"
  base_url="${public_base_url%/}/assets/${ASSET_ID}"

  local e_provider_id e_public_key e_public_base_url e_region e_base_url e_nonce
  e_provider_id="$(sql_escape "$provider_id")"
  e_public_key="$(sql_escape "$public_key")"
  e_public_base_url="$(sql_escape "$public_base_url")"
  e_region="$(sql_escape "$region")"
  e_base_url="$(sql_escape "$base_url")"
  e_nonce="$(sql_escape "$nonce")"

  docker exec -i "$CATALOG_CID" sh -lc "sqlite3 \"$AUDICATALOG_DB_PATH\"" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT INTO providers (
  provider_id, public_key, transport, base_url, region, status, created_at, updated_at
) VALUES (
  '${e_provider_id}', '${e_public_key}', 'https', '${e_public_base_url}', '${e_region}', 'active', ${now_unix}, ${now_unix}
)
ON CONFLICT(provider_id) DO UPDATE SET
  public_key = excluded.public_key,
  transport = excluded.transport,
  base_url = excluded.base_url,
  region = excluded.region,
  status = excluded.status,
  updated_at = excluded.updated_at;

INSERT INTO provider_assets (
  provider_id, asset_id, transport, base_url, priority, expires_at, last_seen_at, nonce, created_at, updated_at
) VALUES (
  '${e_provider_id}', '${ASSET_ID}', 'https', '${e_base_url}', ${priority}, ${expires_at}, ${now_unix}, '${e_nonce}', ${now_unix}, ${now_unix}
)
ON CONFLICT(provider_id, asset_id) DO UPDATE SET
  transport = excluded.transport,
  base_url = excluded.base_url,
  priority = excluded.priority,
  expires_at = excluded.expires_at,
  last_seen_at = excluded.last_seen_at,
  nonce = excluded.nonce,
  updated_at = excluded.updated_at;
COMMIT;
SQL
}

assert_master_and_segment() {
  local provider_base_url="$1"
  local expected_segment_code="$2"

  local playlist_url
  playlist_url="$(resolve_playlist_url "$provider_base_url" "$ASSET_ID")"

  local master_file
  master_file="$(mktemp)"
  local master_code
  master_code="$(curl -sS -o "$master_file" -w '%{http_code}' "$playlist_url" || true)"
  [ "$master_code" = "200" ] || {
    rm -f "$master_file"
    fail "master playlist expected 200 at ${playlist_url}, got ${master_code}"
  }

  local seg_ref
  seg_ref="$(first_segment_ref_from_playlist "$master_file")"
  rm -f "$master_file"
  [ -n "$seg_ref" ] || fail "playlist at ${playlist_url} has no segment reference"

  local seg_url
  seg_url="$(ref_to_absolute_url "$playlist_url" "$seg_ref")"

  local seg_code
  seg_code="$(curl -sS -o /dev/null -w '%{http_code}' "$seg_url" || true)"

  if [ "$expected_segment_code" = "200" ]; then
    [ "$seg_code" = "200" ] || fail "segment expected 200 at ${seg_url}, got ${seg_code}"
  else
    [ "$seg_code" != "200" ] || fail "segment expected failure at ${seg_url}, got 200"
  fi

  log "provider=${provider_base_url} master=200 segment=${seg_code} (${seg_url})"
}

need_cmd docker
need_cmd curl

log "Starting compose stack"
compose up -d --build

wait_http_200 "audistro-catalog /healthz" "${CATALOG_URL}/healthz"
wait_http_200 "audistro-fap /healthz" "${FAP_URL}/healthz"
wait_http_200 "${PROVIDER_EU_1_SERVICE} /readyz" "${PROVIDER_EU_1_URL}/readyz"
wait_http_200 "${PROVIDER_EU_2_SERVICE} /readyz" "${PROVIDER_EU_2_URL}/readyz"
wait_http_200 "${PROVIDER_US_1_SERVICE} /readyz" "${PROVIDER_US_1_URL}/readyz"

CATALOG_CID="$(service_cid audistro-catalog)"
FAP_CID="$(service_cid audistro-fap)"
PROVIDER_EU_1_CID="$(service_cid ${PROVIDER_EU_1_SERVICE})"
PROVIDER_EU_2_CID="$(service_cid ${PROVIDER_EU_2_SERVICE})"
PROVIDER_US_1_CID="$(service_cid ${PROVIDER_US_1_SERVICE})"

log "Resolved containers: audistro-catalog=${CATALOG_CID} audistro-fap=${FAP_CID} eu_1=${PROVIDER_EU_1_CID} eu_2=${PROVIDER_EU_2_CID} us_1=${PROVIDER_US_1_CID}"

PROVIDER_DATA_PATH="$(grep '^PROVIDER_DATA_PATH=' env/audistro-provider_eu_1.env | head -n1 | cut -d= -f2- || true)"
if [ -z "$PROVIDER_DATA_PATH" ]; then
  PROVIDER_DATA_PATH="$(exec_in "$PROVIDER_EU_1_CID" 'printenv PROVIDER_DATA_PATH' || true)"
fi
[ -n "$PROVIDER_DATA_PATH" ] || fail "PROVIDER_DATA_PATH is empty"
log "audistro-provider data path: ${PROVIDER_DATA_PATH}"

AUDICATALOG_DB_PATH="$(grep '^AUDICATALOG_DB_PATH=' env/audistro-catalog.env | head -n1 | cut -d= -f2- || true)"
if [ -z "$AUDICATALOG_DB_PATH" ]; then
  AUDICATALOG_DB_PATH="$(exec_in "$CATALOG_CID" 'printenv AUDICATALOG_DB_PATH' || true)"
fi
[ -n "$AUDICATALOG_DB_PATH" ] || fail "AUDICATALOG_DB_PATH is empty"
log "audistro-catalog DB path: ${AUDICATALOG_DB_PATH}"

exec_in "$CATALOG_CID" 'command -v sqlite3 >/dev/null 2>&1' || fail "sqlite3 CLI missing in audistro-catalog container"

CATALOG_TABLES="$(catalog_sql '.tables')"
log "audistro-catalog tables: ${CATALOG_TABLES}"

require_table "artists"
require_table "payees"
require_table "assets"
require_table "providers"
require_table "provider_assets"

for table in artists payees assets providers provider_assets; do
  log "Schema for ${table}:"
  exec_in "$CATALOG_CID" "sqlite3 \"$AUDICATALOG_DB_PATH\" \".schema ${table}\""
done

require_column "artists" "artist_id"
require_column "artists" "pubkey_hex"
require_column "artists" "handle"
require_column "payees" "payee_id"
require_column "payees" "artist_id"
require_column "payees" "fap_public_base_url"
require_column "assets" "asset_id"
require_column "assets" "artist_id"
require_column "assets" "payee_id"
require_column "assets" "hls_master_url"
require_column "providers" "provider_id"
require_column "providers" "public_key"
require_column "provider_assets" "provider_id"
require_column "provider_assets" "asset_id"

log "Collecting provider identities"
provider_eu_1_health="$(curl -fsS "${PROVIDER_EU_1_URL}/healthz")"
provider_eu_2_health="$(curl -fsS "${PROVIDER_EU_2_URL}/healthz")"
provider_us_1_health="$(curl -fsS "${PROVIDER_US_1_URL}/healthz")"

provider_eu_1_id="$(json_get '.provider_id' "$provider_eu_1_health")"
provider_eu_2_id="$(json_get '.provider_id' "$provider_eu_2_health")"
provider_us_1_id="$(json_get '.provider_id' "$provider_us_1_health")"
provider_eu_1_public_key="$(json_get '.public_key' "$provider_eu_1_health")"
provider_eu_2_public_key="$(json_get '.public_key' "$provider_eu_2_health")"
provider_us_1_public_key="$(json_get '.public_key' "$provider_us_1_health")"
provider_eu_1_public_base_url="$(json_get '.public_base_url' "$provider_eu_1_health")"
provider_eu_2_public_base_url="$(json_get '.public_base_url' "$provider_eu_2_health")"
provider_us_1_public_base_url="$(json_get '.public_base_url' "$provider_us_1_health")"
provider_eu_1_region="$(json_get '.region' "$provider_eu_1_health")"
provider_eu_2_region="$(json_get '.region' "$provider_eu_2_health")"
provider_us_1_region="$(json_get '.region' "$provider_us_1_health")"

[ -n "$provider_eu_1_id" ] || fail "provider_id missing for ${PROVIDER_EU_1_SERVICE}"
[ -n "$provider_eu_2_id" ] || fail "provider_id missing for ${PROVIDER_EU_2_SERVICE}"
[ -n "$provider_us_1_id" ] || fail "provider_id missing for ${PROVIDER_US_1_SERVICE}"
[ -n "$provider_eu_1_public_key" ] || fail "public_key missing for ${PROVIDER_EU_1_SERVICE}"
[ -n "$provider_eu_2_public_key" ] || fail "public_key missing for ${PROVIDER_EU_2_SERVICE}"
[ -n "$provider_us_1_public_key" ] || fail "public_key missing for ${PROVIDER_US_1_SERVICE}"
[ -n "$provider_eu_1_public_base_url" ] || fail "public_base_url missing for ${PROVIDER_EU_1_SERVICE}"
[ -n "$provider_eu_2_public_base_url" ] || fail "public_base_url missing for ${PROVIDER_EU_2_SERVICE}"
[ -n "$provider_us_1_public_base_url" ] || fail "public_base_url missing for ${PROVIDER_US_1_SERVICE}"
[ -n "$provider_eu_1_region" ] || fail "region missing for ${PROVIDER_EU_1_SERVICE}"
[ -n "$provider_eu_2_region" ] || fail "region missing for ${PROVIDER_EU_2_SERVICE}"
[ -n "$provider_us_1_region" ] || fail "region missing for ${PROVIDER_US_1_SERVICE}"

log "Provider IDs: eu_1=${provider_eu_1_id} eu_2=${provider_eu_2_id} us_1=${provider_us_1_id}"

now="$(date +%s)"
artist_pubkey_hex="031111111111111111111111111111111111111111111111111111111111111111"

log "Seeding audistro-catalog SQLite metadata for asset=${ASSET_ID}"
docker exec -i "$CATALOG_CID" sh -lc "sqlite3 \"$AUDICATALOG_DB_PATH\"" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT OR REPLACE INTO artists (
  artist_id, pubkey_hex, handle, display_name, bio, avatar_url, created_at, updated_at
) VALUES (
  '${ARTIST_ID}', '${artist_pubkey_hex}', '${ARTIST_HANDLE}', 'Smoke Artist', '', '', ${now}, ${now}
);

INSERT OR REPLACE INTO payees (
  payee_id, artist_id, fap_public_base_url, fap_payee_id, created_at, updated_at
) VALUES (
  '${PAYEE_ID}', '${ARTIST_ID}', 'http://localhost:18081', '${FAP_PAYEE_ID}', ${now}, ${now}
);

INSERT OR REPLACE INTO assets (
  asset_id, artist_id, payee_id, title, duration_ms, content_id, hls_master_url, preview_hls_url, price_msat, created_at, updated_at
) VALUES (
  '${ASSET_ID}', '${ARTIST_ID}', '${PAYEE_ID}', 'Smoke Asset', 8000, 'cid-${ASSET_ID}',
  'http://localhost:18082/assets/${ASSET_ID}/master.m3u8',
  'http://localhost:18081/hls/{asset_id}/key',
  0, ${now}, ${now}
);
DELETE FROM provider_assets WHERE asset_id='${ASSET_ID}';
COMMIT;
SQL
log "PASS: audistro-catalog SQLite seeded"

log "Generating valid HLS fixture on ${PROVIDER_EU_1_SERVICE} and ${PROVIDER_EU_2_SERVICE}"
generate_hls_fixture "$ASSET_ID" "$PROVIDER_EU_1_CID" "$PROVIDER_DATA_PATH"
generate_hls_fixture "$ASSET_ID" "$PROVIDER_EU_2_CID" "$PROVIDER_DATA_PATH"

log "Ensuring ${PROVIDER_US_1_SERVICE} does not host ${ASSET_ID}"
docker exec -i "$PROVIDER_US_1_CID" sh -lc "rm -rf \"${PROVIDER_DATA_PATH}/assets/${ASSET_ID}\""

trigger_rescan_announce "$PROVIDER_EU_1_SERVICE" "$PROVIDER_EU_1_CID" "$ASSET_ID" "yes"
trigger_rescan_announce "$PROVIDER_EU_2_SERVICE" "$PROVIDER_EU_2_CID" "$ASSET_ID" "yes"
trigger_rescan_announce "$PROVIDER_US_1_SERVICE" "$PROVIDER_US_1_CID" "$ASSET_ID" "no"

inject_broken_segment "$ASSET_ID" "$PROVIDER_EU_2_CID" "$PROVIDER_DATA_PATH"

log "Validating playback bootstrap with multiple providers"
playback_json_file="$(mktemp)"
playback_code="$(curl -sS -o "$playback_json_file" -w '%{http_code}' "${CATALOG_URL}/v1/playback/${ASSET_ID}" || true)"
playback_json="$(cat "$playback_json_file")"
rm -f "$playback_json_file"

[ "$playback_code" = "200" ] || fail "GET /v1/playback/${ASSET_ID} expected 200, got ${playback_code}: ${playback_json}"

providers_count="$(playback_provider_count "$playback_json")"
[ "$providers_count" -ge 2 ] || fail "playback providers length expected >=2, got ${providers_count}"

mapfile -t provider_lines < <(playback_provider_lines "$playback_json")
[ "${#provider_lines[@]}" -ge 2 ] || fail "provider lines parse returned < 2"

providers_base_file="$(mktemp)"
printf '%s\n' "${provider_lines[@]}" | cut -d'|' -f2 >"$providers_base_file"

present_count=0
for candidate in \
  "${PROVIDER_EU_1_URL}/assets/${ASSET_ID}" \
  "${PROVIDER_EU_2_URL}/assets/${ASSET_ID}" \
  "${PROVIDER_US_1_URL}/assets/${ASSET_ID}"; do
  if grep -Fx "$candidate" "$providers_base_file" >/dev/null 2>&1; then
    present_count=$((present_count + 1))
  fi
done
[ "$present_count" -ge 2 ] || fail "expected at least 2 provider base_urls among :18082/:18083/:18084, got ${present_count}"

first_provider_base="$(printf '%s' "${provider_lines[0]}" | cut -d'|' -f2)"

healthy_provider_base=""
broken_index=-1
for i in "${!provider_lines[@]}"; do
  base="$(printf '%s' "${provider_lines[$i]}" | cut -d'|' -f2)"
  if [ "$base" = "$BROKEN_PROVIDER_BASE_URL" ]; then
    broken_index="$i"
    continue
  fi
  playlist_url="$(resolve_playlist_url "$base" "$ASSET_ID")"
  master_tmp="$(mktemp)"
  master_code="$(curl -sS -o "$master_tmp" -w '%{http_code}' "$playlist_url" || true)"
  if [ "$master_code" != "200" ]; then
    rm -f "$master_tmp"
    continue
  fi
  seg_ref="$(first_segment_ref_from_playlist "$master_tmp")"
  rm -f "$master_tmp"
  [ -n "$seg_ref" ] || continue
  seg_url="$(ref_to_absolute_url "$playlist_url" "$seg_ref")"
  seg_code="$(curl -sS -o /dev/null -w '%{http_code}' "$seg_url" || true)"
  if [ "$seg_code" = "200" ]; then
    healthy_provider_base="$base"
    break
  fi
done

[ "$broken_index" -ge 0 ] || fail "broken provider base_url not found in playback providers: ${BROKEN_PROVIDER_BASE_URL}"
[ -n "$healthy_provider_base" ] || fail "no healthy provider candidate found in playback providers"

if [ "$first_provider_base" = "$BROKEN_PROVIDER_BASE_URL" ]; then
  if [ "${#provider_lines[@]}" -lt 2 ]; then
    fail "cannot test fallback next-provider path: only one provider returned"
  fi
  next_provider_base="$(printf '%s' "${provider_lines[1]}" | cut -d'|' -f2)"
  log "Fallback test path A: catalog first provider is broken (${first_provider_base}), next provider is ${next_provider_base}"
  assert_master_and_segment "$first_provider_base" "non200"
  assert_master_and_segment "$next_provider_base" "200"
  log "PASS: provider fallback tested (first provider failed segment fetch, second succeeded)"
else
  log "Fallback test path B: catalog first provider is ${first_provider_base}; using injected-broken provider ${BROKEN_PROVIDER_BASE_URL} for deterministic fallback simulation"
  assert_master_and_segment "$BROKEN_PROVIDER_BASE_URL" "non200"
  assert_master_and_segment "$healthy_provider_base" "200"
  log "PASS: provider fallback tested (broken provider failed segment fetch, healthy provider succeeded)"
fi

rm -f "$providers_base_file"

log "Validating FAP access + key flow"
access_json_file="$(mktemp)"
access_code="$(curl -sS -o "$access_json_file" -w '%{http_code}' -X POST "${FAP_URL}/v1/access/${ASSET_ID}" || true)"
access_json="$(cat "$access_json_file")"
rm -f "$access_json_file"
[ "$access_code" = "200" ] || fail "POST /v1/access/${ASSET_ID} expected 200, got ${access_code}: ${access_json}"
access_token="$(json_get '.access_token' "$access_json")"
[ -n "$access_token" ] && [ "$access_token" != "null" ] || fail "access_token missing from /v1/access response: ${access_json}"

key_bin="$(mktemp)"
key_code="$(curl -sS -o "$key_bin" -w '%{http_code}' -H "Authorization: Bearer ${access_token}" "${FAP_URL}/hls/${ASSET_ID}/key" || true)"
[ "$key_code" = "200" ] || fail "GET /hls/${ASSET_ID}/key with token expected 200, got ${key_code}"
key_len="$(wc -c < "$key_bin" | tr -d '[:space:]')"
rm -f "$key_bin"
[ "$key_len" = "16" ] || fail "GET /hls/${ASSET_ID}/key expected 16 bytes, got ${key_len}"
log "PASS: FAP returned 16-byte key for tokenized request"

log "PASS: e2e playback smoke test succeeded for asset=${ASSET_ID}"
