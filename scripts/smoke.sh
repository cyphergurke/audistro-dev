#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

compose() {
  docker compose "$@"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

http_post_json_expect() {
  local url="$1"
  local body="$2"
  local expected="$3"
  local tmp
  tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X POST -H "Content-Type: application/json" --data "$body" "$url" || true)"
  if [[ "$code" != "$expected" ]]; then
    echo "request failed: POST $url (expected $expected got $code)" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

http_get_expect() {
  local url="$1"
  local expected="$2"
  local tmp
  tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w "%{http_code}" "$url" || true)"
  if [[ "$code" != "$expected" ]]; then
    echo "request failed: GET $url (expected $expected got $code)" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

wait_http_200() {
  local name="$1"
  local url="$2"
  local attempts="${3:-90}"
  local sleep_sec="${4:-1}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_sec"
  done

  echo "timeout waiting for $name at $url" >&2
  return 1
}

need_cmd docker
need_cmd curl
need_cmd python3

echo "[smoke] starting compose stack"
compose up -d --build

echo "[smoke] waiting for audistro-catalog"
if ! wait_http_200 "audistro-catalog /readyz" "http://localhost:18080/readyz" 5 1; then
  wait_http_200 "audistro-catalog /healthz" "http://localhost:18080/healthz" 90 1
fi

echo "[smoke] waiting for audistro-provider /readyz"
wait_http_200 "audistro-provider /readyz" "http://localhost:18082/readyz" 120 1

echo "[smoke] waiting for audistro-fap /healthz"
wait_http_200 "audistro-fap /healthz" "http://localhost:18081/healthz" 90 1

stamp="$(date +%s)"
rand="$(printf '%04d' $((RANDOM % 10000)))"
asset_id="${ASSET_ID:-smoke_asset_${stamp}_${rand}}"
artist_handle="smk${stamp: -6}_${rand}"
pubkey_seed="$(tr -d '-' </proc/sys/kernel/random/uuid)"
pubkey_hex="${pubkey_seed}${pubkey_seed}"

echo "[smoke] seeding audistro-catalog data for asset_id=${asset_id}"
artist_payload="$(cat <<JSON
{"pubkey_hex":"${pubkey_hex}","handle":"${artist_handle}","display_name":"Smoke Artist"}
JSON
)"
http_post_json_expect "http://localhost:18080/v1/artists" "$artist_payload" "201" >/dev/null

payee_payload="$(cat <<JSON
{"artist_handle":"${artist_handle}","fap_public_base_url":"http://localhost:18081","fap_payee_id":"fap_${asset_id}"}
JSON
)"
payee_resp="$(http_post_json_expect "http://localhost:18080/v1/payees" "$payee_payload" "201")"
payee_id="$(printf '%s' "$payee_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["payee"]["payee_id"])')"

asset_payload="$(cat <<JSON
{"asset_id":"${asset_id}","artist_handle":"${artist_handle}","payee_id":"${payee_id}","title":"Smoke Asset","duration_ms":120000,"content_id":"cid-${asset_id}","hls_master_url":"http://localhost:18082/assets/${asset_id}/master.m3u8","price_msat":0,"provider_hints":[]}
JSON
)"
http_post_json_expect "http://localhost:18080/v1/assets" "$asset_payload" "201" >/dev/null

echo "[smoke] writing provider fixture files inside audistro-provider container"
compose exec -T -e ASSET_ID="$asset_id" audistro-provider sh -lc '
set -eu
asset_dir="${PROVIDER_DATA_PATH:-/var/lib/audistro-provider}/assets/${ASSET_ID}"
mkdir -p "$asset_dir"
cat > "$asset_dir/master.m3u8" <<"M3U8"
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.0,
seg_0001.ts
#EXT-X-ENDLIST
M3U8
printf "FAKE-TS-DATA\n" > "$asset_dir/seg_0001.ts"
'

echo "[smoke] ensuring provider registration in catalog"
provider_health="$(http_get_expect "http://localhost:18082/healthz" "200")"
provider_id="$(printf '%s' "$provider_health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["provider_id"])')"
provider_key="$(printf '%s' "$provider_health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')"
provider_base_url="$(printf '%s' "$provider_health" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_base_url"])')"
register_payload="$(python3 - "$provider_id" "$provider_key" "$provider_base_url" <<'PY'
import json
import sys
provider_id = sys.argv[1]
public_key = sys.argv[2]
base_url = sys.argv[3]
print(json.dumps({
    "provider_id": provider_id,
    "public_key": public_key,
    "transport": "https",
    "base_url": base_url,
    "region": "dev"
}))
PY
)"
http_post_json_expect "http://localhost:18080/v1/providers" "$register_payload" "200" >/dev/null

echo "[smoke] triggering rescan and announce from inside audistro-provider (loopback-only internal endpoints)"
compose exec -T audistro-provider sh -lc 'curl -fsS -X POST http://127.0.0.1:8080/internal/rescan >/dev/null'
announce_json="$(compose exec -T -e ASSET_ID="$asset_id" audistro-provider sh -lc 'curl -fsS -H "Content-Type: application/json" -d "{\"asset_id\":\"${ASSET_ID}\"}" http://127.0.0.1:8080/internal/announce')"
printf '%s' "$announce_json" | python3 -c '
import json, sys
resp = json.load(sys.stdin)
if resp.get("ok", 0) < 1:
    raise SystemExit(f"announce did not succeed: {resp}")
'

echo "[smoke] validating playback bootstrap"
playback_json="$(http_get_expect "http://localhost:18080/v1/playback/${asset_id}" "200")"
printf '%s' "$playback_json" | python3 -c '
import json, sys
resp = json.load(sys.stdin)
providers = resp.get("providers", [])
if not providers:
    raise SystemExit("providers list is empty")
if not any("localhost:18082" in p.get("base_url", "") for p in providers):
    raise SystemExit(f"provider base_url is not mapped to localhost:18082: {providers}")
'

echo "[smoke] validating provider asset fetches"
http_get_expect "http://localhost:18082/assets/${asset_id}/master.m3u8" "200" >/dev/null
http_get_expect "http://localhost:18082/assets/${asset_id}/seg_0001.ts" "200" >/dev/null

echo "[smoke] success: compose e2e passed for asset_id=${asset_id}"
