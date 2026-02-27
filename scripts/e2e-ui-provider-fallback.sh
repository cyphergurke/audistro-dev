#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ASSET_ID="${ASSET_ID:-asset1}"
WEB_BASE="${WEB_BASE:-http://localhost:3000}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-8}"
START_BUFFER_SECONDS="${START_BUFFER_SECONDS:-2.0}"
EXPECT_PROVIDER_ID="${EXPECT_PROVIDER_ID:-}"

TMP_DIR="$(mktemp -d)"
PLAYLIST_FILE="$TMP_DIR/playlist.m3u8"
SEGMENTS_FILE="$TMP_DIR/segments.tsv"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '[e2e-ui-fallback] %s\n' "$*"
}

fail() {
  printf '[e2e-ui-fallback] FAIL: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
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
obj = json.loads(os.environ["JSON_PAYLOAD"])

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

provider_lines() {
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
    print(f'{provider.get("provider_id","")}|{provider.get("base_url","")}')
PY
    return 0
  fi

  fail "jq or python3 is required to parse providers"
}

first_segment_url() {
  local playlist_file="$1"
  awk '/^[^#[:space:]]/ {print; exit}' "$playlist_file"
}

float_gt() {
  local a="$1"
  local b="$2"
  awk -v av="$a" -v bv="$b" 'BEGIN { exit !(av > bv) }'
}

need_cmd curl
need_cmd awk
need_cmd date

log "asset_id=${ASSET_ID}"
log "web_base=${WEB_BASE}"
log "request_timeout_seconds=${REQUEST_TIMEOUT_SECONDS}"
log "start_buffer_seconds=${START_BUFFER_SECONDS}"

access_payload="$(curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${WEB_BASE}/api/access/${ASSET_ID}")"
token="$(json_get '.access_token' "$access_payload")"
[ -n "$token" ] || fail "access token missing"

playback_payload="$(curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" "${WEB_BASE}/api/playback/${ASSET_ID}")"
mapfile -t providers < <(provider_lines "$playback_payload")
[ "${#providers[@]}" -gt 0 ] || fail "no providers returned by playback API"

selected_provider_id=""
selected_provider_base=""

log "provider preflight attempts:"
for line in "${providers[@]}"; do
  provider_id="${line%%|*}"
  provider_base="${line#*|}"

  playlist_status="$(
    curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" --get \
      --data-urlencode "providerId=${provider_id}" \
      --data-urlencode "token=${token}" \
      -o "$PLAYLIST_FILE" \
      -w '%{http_code}' \
      "${WEB_BASE}/api/playlist/${ASSET_ID}" || true
  )"

  if [ "$playlist_status" != "200" ]; then
    log "  provider=${provider_id} base=${provider_base} -> skip (playlist status=${playlist_status})"
    continue
  fi

  seg0_url="$(first_segment_url "$PLAYLIST_FILE")"
  if [ -z "$seg0_url" ]; then
    log "  provider=${provider_id} base=${provider_base} -> skip (no media segment in playlist)"
    continue
  fi

  seg0_stat="$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -o /dev/null -w '%{http_code}\t%{time_total}' "$seg0_url" 2>/dev/null || true)"
  IFS=$'\t' read -r seg0_status seg0_time <<<"$seg0_stat"
  if [ "$seg0_status" != "200" ]; then
    log "  provider=${provider_id} base=${provider_base} -> skip (seg0 status=${seg0_status} time=${seg0_time}s)"
    continue
  fi

  selected_provider_id="$provider_id"
  selected_provider_base="$provider_base"
  log "  provider=${provider_id} base=${provider_base} -> SELECTED (seg0 status=200 time=${seg0_time}s)"
  break
done

[ -n "$selected_provider_id" ] || fail "no healthy provider candidate after preflight"

if [ -n "$EXPECT_PROVIDER_ID" ] && [ "$selected_provider_id" != "$EXPECT_PROVIDER_ID" ]; then
  fail "selected provider ${selected_provider_id} != expected ${EXPECT_PROVIDER_ID}"
fi

log "running sequential fetch budget on selected provider=${selected_provider_id}"

awk '
  BEGIN { dur=""; idx=0 }
  /^#EXTINF:/ {
    line=$0
    sub(/^#EXTINF:/, "", line)
    sub(/,.*/, "", line)
    dur=line+0
    next
  }
  /^#/ { next }
  NF {
    print idx "\t" dur "\t" $0
    idx++
  }
' "$PLAYLIST_FILE" >"$SEGMENTS_FILE"
[ -s "$SEGMENTS_FILE" ] || fail "selected playlist has no media segments"

suite_start_ms="$(date +%s%3N)"
running_extinf="0"
late_count=0
error_count=0
segment_count=0

while IFS=$'\t' read -r idx extinf url; do
  segment_count=$((segment_count + 1))
  stat_line="$(
    curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
      -o /dev/null \
      -w '%{http_code}\t%{time_total}\t%{size_download}' \
      "$url" 2>/dev/null || true
  )"
  IFS=$'\t' read -r status fetch_seconds size_download <<<"$stat_line"
  now_ms="$(date +%s%3N)"

  elapsed_seconds="$(awk -v s="$suite_start_ms" -v e="$now_ms" 'BEGIN { printf("%.6f", (e-s)/1000) }')"
  deadline_seconds="$(awk -v b="$START_BUFFER_SECONDS" -v d="$running_extinf" 'BEGIN { printf("%.6f", b + d) }')"
  slack_seconds="$(awk -v dl="$deadline_seconds" -v el="$elapsed_seconds" 'BEGIN { printf("%.6f", dl - el) }')"

  verdict="OK"
  if [ "$status" != "200" ]; then
    verdict="ERR"
    error_count=$((error_count + 1))
  elif float_gt "$elapsed_seconds" "$deadline_seconds"; then
    verdict="LATE"
    late_count=$((late_count + 1))
  fi

  printf '[e2e-ui-fallback] seg_%02d status=%s extinf=%.3fs fetch=%ss elapsed=%ss deadline=%ss slack=%ss size=%s %s\n' \
    "$idx" "$status" "$extinf" "$fetch_seconds" "$elapsed_seconds" "$deadline_seconds" "$slack_seconds" "$size_download" "$verdict"

  running_extinf="$(awk -v cur="$running_extinf" -v add="$extinf" 'BEGIN { printf("%.6f", cur + add) }')"
done <"$SEGMENTS_FILE"

log "summary selected_provider=${selected_provider_id} segments=${segment_count} errors=${error_count} late=${late_count}"

if [ "$error_count" -gt 0 ]; then
  fail "sequential segment fetch had HTTP errors"
fi
if [ "$late_count" -gt 0 ]; then
  fail "sequential fetch exceeded playback budget"
fi

log "PASS: UI-style provider fallback preflight and sequential fetch budget are healthy"
