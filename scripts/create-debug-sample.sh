#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ASSET_ID="${ASSET_ID:-asset2}"
ARTIST_ID="${ARTIST_ID:-artist_debug_${ASSET_ID}}"
ARTIST_HANDLE="${ARTIST_HANDLE:-debug_${ASSET_ID}}"
PAYEE_ID="${PAYEE_ID:-payee_debug_${ASSET_ID}}"
FAP_PAYEE_ID="${FAP_PAYEE_ID:-fap_${ASSET_ID}}"
TITLE="${TITLE:-Debug Asset 2}"
DURATION_SECONDS="${DURATION_SECONDS:-10}"
SINE_FREQUENCY="${SINE_FREQUENCY:-880}"
SOURCE_AUDIO_FILE="${SOURCE_AUDIO_FILE:-}"
PROVIDER_SERVICE="${PROVIDER_SERVICE:-audistro-provider_eu_1}"
PROVIDER_PUBLIC_URL="${PROVIDER_PUBLIC_URL:-http://localhost:18082}"
CATALOG_URL="${CATALOG_URL:-http://localhost:18080}"
FAP_PUBLIC_BASE_URL="${FAP_PUBLIC_BASE_URL:-http://localhost:18081}"
FFMPEG_IMAGE="${FFMPEG_IMAGE:-jrottenberg/ffmpeg:6.0-alpine}"

log() {
  printf '[create-debug-sample] %s\n' "$*"
}

fail() {
  printf '[create-debug-sample] FAIL: %s\n' "$*" >&2
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

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

artist_pubkey_for_asset() {
  local asset_id="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    local hash
    hash="$(printf '%s' "$asset_id" | sha256sum | awk '{print $1}')"
    printf '02%s' "$hash"
    return
  fi
  fail "sha256sum is required to derive deterministic artist pubkeys"
}

resolve_abs_path() {
  local path="$1"
  if [ -z "$path" ]; then
    printf ''
    return
  fi
  if [ ! -f "$path" ]; then
    fail "SOURCE_AUDIO_FILE does not exist: $path"
  fi
  local dir
  local file
  dir="$(cd "$(dirname "$path")" && pwd)"
  file="$(basename "$path")"
  printf '%s/%s' "$dir" "$file"
}

need_cmd docker
need_cmd curl

log "ensuring stack is up"
compose up -d audistro-catalog audistro-fap audistro-provider_eu_1 audistro-provider_eu_2 audistro-provider_us_1 >/dev/null

CATALOG_CID="$(service_cid audistro-catalog)"
PROVIDER_CID="$(service_cid "$PROVIDER_SERVICE")"
PROVIDER_EU2_CID="$(compose ps -q audistro-provider_eu_2 | head -n1 || true)"
PROVIDER_US1_CID="$(compose ps -q audistro-provider_us_1 | head -n1 || true)"

PROVIDER_DATA_PATH="$(grep '^PROVIDER_DATA_PATH=' env/audistro-provider_eu_1.env | head -n1 | cut -d= -f2- || true)"
if [ -z "$PROVIDER_DATA_PATH" ]; then
  PROVIDER_DATA_PATH="$(exec_in "$PROVIDER_CID" 'printenv PROVIDER_DATA_PATH' || true)"
fi
[ -n "$PROVIDER_DATA_PATH" ] || fail "PROVIDER_DATA_PATH is empty"

AUDICATALOG_DB_PATH="$(grep '^AUDICATALOG_DB_PATH=' env/audistro-catalog.env | head -n1 | cut -d= -f2- || true)"
if [ -z "$AUDICATALOG_DB_PATH" ]; then
  AUDICATALOG_DB_PATH="$(exec_in "$CATALOG_CID" 'printenv AUDICATALOG_DB_PATH' || true)"
fi
[ -n "$AUDICATALOG_DB_PATH" ] || fail "AUDICATALOG_DB_PATH is empty"

exec_in "$CATALOG_CID" 'command -v sqlite3 >/dev/null 2>&1' || fail "sqlite3 missing in audistro-catalog container"

health_payload="$(curl -fsS "${PROVIDER_PUBLIC_URL}/healthz")"
provider_id="$(json_get '.provider_id' "$health_payload")"
provider_public_key="$(json_get '.public_key' "$health_payload")"
provider_public_base_url="$(json_get '.public_base_url' "$health_payload")"
provider_region="$(json_get '.region' "$health_payload")"

[ -n "$provider_id" ] || fail "provider_id missing in provider health payload"
[ -n "$provider_public_key" ] || fail "public_key missing in provider health payload"
[ -n "$provider_public_base_url" ] || fail "public_base_url missing in provider health payload"
[ -n "$provider_region" ] || fail "region missing in provider health payload"

source_audio_abs_path="$(resolve_abs_path "$SOURCE_AUDIO_FILE")"
if [ -n "$source_audio_abs_path" ]; then
  log "generating HLS fixture from source audio (asset=${ASSET_ID}, source=${source_audio_abs_path})"
else
  log "generating synthetic HLS fixture (asset=${ASSET_ID}, duration=${DURATION_SECONDS}s, freq=${SINE_FREQUENCY}Hz)"
fi

tmp_dir="$(mktemp -d)"
cleanup_tmp() {
  rm -rf "$tmp_dir"
}
trap cleanup_tmp EXIT

if [ -n "$source_audio_abs_path" ]; then
  source_audio_dir="$(dirname "$source_audio_abs_path")"
  source_audio_file="$(basename "$source_audio_abs_path")"
  docker run --rm \
    -v "${source_audio_dir}:/in:ro" \
    -v "${tmp_dir}:/out" \
    "${FFMPEG_IMAGE}" \
    -y -i "/in/${source_audio_file}" \
    -map 0:a:0 -vn -ac 2 -ar 48000 \
    -c:a aac -b:a 128k \
    -f hls -hls_time 2 -hls_playlist_type vod -hls_flags independent_segments \
    -hls_segment_filename /out/seg_%04d.ts \
    /out/master.m3u8 >/dev/null 2>&1 || fail "ffmpeg conversion from SOURCE_AUDIO_FILE failed"
else
  docker run --rm -v "${tmp_dir}:/out" "${FFMPEG_IMAGE}" \
    -y -f lavfi -i "sine=frequency=${SINE_FREQUENCY}:duration=${DURATION_SECONDS}:sample_rate=48000" \
    -c:a aac -b:a 128k \
    -f hls -hls_time 2 -hls_playlist_type vod -hls_flags independent_segments \
    -hls_segment_filename /out/seg_%04d.ts \
    /out/master.m3u8 >/dev/null 2>&1 || fail "ffmpeg fixture generation failed"
fi

[ -s "${tmp_dir}/master.m3u8" ] || fail "generated master.m3u8 missing"
ls "${tmp_dir}"/seg_*.ts >/dev/null 2>&1 || fail "no TS segments generated"

asset_dir="${PROVIDER_DATA_PATH}/assets/${ASSET_ID}"
exec_in "$PROVIDER_CID" "mkdir -p \"$asset_dir\" && rm -f \"$asset_dir\"/master.m3u8 \"$asset_dir\"/seg_*.ts"
docker cp "${tmp_dir}/." "${PROVIDER_CID}:${asset_dir}/"

if [ -n "$PROVIDER_EU2_CID" ]; then
  exec_in "$PROVIDER_EU2_CID" "rm -rf \"${PROVIDER_DATA_PATH}/assets/${ASSET_ID}\"" || true
fi
if [ -n "$PROVIDER_US1_CID" ]; then
  exec_in "$PROVIDER_US1_CID" "rm -rf \"${PROVIDER_DATA_PATH}/assets/${ASSET_ID}\"" || true
fi

now="$(date +%s)"
expires_at="$((now + 86400))"
duration_ms="$(awk -F: '/^#EXTINF:/{sub(/,.*/,"",$2); sum+=$2} END {printf("%d\n", sum*1000)}' "${tmp_dir}/master.m3u8")"
if ! printf '%s' "$duration_ms" | grep -Eq '^[0-9]+$' || [ "$duration_ms" -le 0 ]; then
  duration_ms="$((DURATION_SECONDS * 1000))"
fi
nonce="$(printf 'debug%08x' "$now")"

e_artist_id="$(sql_escape "$ARTIST_ID")"
e_artist_handle="$(sql_escape "$ARTIST_HANDLE")"
artist_pubkey="$(artist_pubkey_for_asset "$ASSET_ID")"
e_artist_pubkey="$(sql_escape "$artist_pubkey")"
e_payee_id="$(sql_escape "$PAYEE_ID")"
e_fap_payee_id="$(sql_escape "$FAP_PAYEE_ID")"
e_asset_id="$(sql_escape "$ASSET_ID")"
e_title="$(sql_escape "$TITLE")"
e_provider_id="$(sql_escape "$provider_id")"
e_provider_public_key="$(sql_escape "$provider_public_key")"
e_provider_public_base_url="$(sql_escape "$provider_public_base_url")"
e_provider_region="$(sql_escape "$provider_region")"
e_nonce="$(sql_escape "$nonce")"
e_fap_public_base_url="$(sql_escape "$FAP_PUBLIC_BASE_URL")"

log "seeding audistro-catalog metadata and provider mapping"
docker exec -i "$CATALOG_CID" sh -lc "sqlite3 \"$AUDICATALOG_DB_PATH\"" <<SQL
PRAGMA foreign_keys = ON;
BEGIN;
INSERT OR REPLACE INTO artists (
  artist_id, pubkey_hex, handle, display_name, bio, avatar_url, created_at, updated_at
) VALUES (
  '${e_artist_id}',
  '${e_artist_pubkey}',
  '${e_artist_handle}',
  'Debug Artist',
  '',
  '',
  ${now},
  ${now}
);

INSERT OR REPLACE INTO payees (
  payee_id, artist_id, fap_public_base_url, fap_payee_id, created_at, updated_at
) VALUES (
  '${e_payee_id}',
  '${e_artist_id}',
  '${e_fap_public_base_url}',
  '${e_fap_payee_id}',
  ${now},
  ${now}
);

INSERT OR REPLACE INTO assets (
  asset_id, artist_id, payee_id, title, duration_ms, content_id, hls_master_url, preview_hls_url, price_msat, created_at, updated_at
) VALUES (
  '${e_asset_id}',
  '${e_artist_id}',
  '${e_payee_id}',
  '${e_title}',
  ${duration_ms},
  'cid-${e_asset_id}',
  '${PROVIDER_PUBLIC_URL}/assets/${e_asset_id}/master.m3u8',
  '${FAP_PUBLIC_BASE_URL}/hls/{asset_id}/key',
  0,
  ${now},
  ${now}
);

INSERT INTO providers (
  provider_id, public_key, transport, base_url, region, status, created_at, updated_at
) VALUES (
  '${e_provider_id}',
  '${e_provider_public_key}',
  'http',
  '${e_provider_public_base_url}',
  '${e_provider_region}',
  'active',
  ${now},
  ${now}
)
ON CONFLICT(provider_id) DO UPDATE SET
  public_key = excluded.public_key,
  transport = excluded.transport,
  base_url = excluded.base_url,
  region = excluded.region,
  status = excluded.status,
  updated_at = excluded.updated_at;

DELETE FROM provider_assets WHERE asset_id='${e_asset_id}';

INSERT INTO provider_assets (
  provider_id, asset_id, transport, base_url, priority, expires_at, last_seen_at, nonce, created_at, updated_at
) VALUES (
  '${e_provider_id}',
  '${e_asset_id}',
  'http',
  '${PROVIDER_PUBLIC_URL}/assets/${e_asset_id}',
  10,
  ${expires_at},
  ${now},
  '${e_nonce}',
  ${now},
  ${now}
);
COMMIT;
SQL

playback_json="$(curl -fsS "${CATALOG_URL}/v1/playback/${ASSET_ID}")"
providers_count="$(json_get '.providers | length' "$playback_json")"

log "PASS sample created"
log "asset_id=${ASSET_ID}"
log "provider=${PROVIDER_PUBLIC_URL}/assets/${ASSET_ID}"
log "catalog playback providers=${providers_count}"
log "test in UI: http://localhost:3000/asset/${ASSET_ID}"
