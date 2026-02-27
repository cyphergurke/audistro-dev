#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ASSET_ID="${ASSET_ID:-asset1}"
WEB_BASE="${WEB_BASE:-http://localhost:3000}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-8}"
START_BUFFER_SECONDS="${START_BUFFER_SECONDS:-2.0}"
PROVIDER_ID="${PROVIDER_ID:-}"
PREFERRED_PROVIDER_BASE="${PREFERRED_PROVIDER_BASE:-http://localhost:18082/assets/${ASSET_ID}}"

TMP_DIR="$(mktemp -d)"
PLAYLIST_FILE="$TMP_DIR/playlist.m3u8"
SEGMENTS_FILE="$TMP_DIR/segments.tsv"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '[e2e-seq] %s\n' "$*"
}

fail() {
  printf '[e2e-seq] FAIL: %s\n' "$*" >&2
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
payload = json.loads(os.environ["JSON_PAYLOAD"])

if field.startswith("."):
    field = field[1:]
parts = [p for p in field.split(".") if p]
value = payload
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

select_provider() {
  local playback_payload="$1"
  local explicit_provider_id="$2"
  local preferred_base="$3"

  if command -v jq >/dev/null 2>&1; then
    if [ -n "$explicit_provider_id" ]; then
      printf '%s' "$playback_payload" | jq -r --arg pid "$explicit_provider_id" '
        .providers[]? | select(.provider_id == $pid) | "\(.provider_id)|\(.base_url)"' | head -n1
      return 0
    fi

    if [ -n "$preferred_base" ]; then
      local preferred_line
      preferred_line="$(printf '%s' "$playback_payload" | jq -r --arg base "$preferred_base" '
        .providers[]? | select(.base_url == $base) | "\(.provider_id)|\(.base_url)"' | head -n1)"
      if [ -n "$preferred_line" ]; then
        printf '%s\n' "$preferred_line"
        return 0
      fi
    fi

    printf '%s' "$playback_payload" | jq -r '.providers[0] | "\(.provider_id)|\(.base_url)"'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_PAYLOAD="$playback_payload" EXPLICIT_ID="$explicit_provider_id" PREFERRED_BASE="$preferred_base" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["JSON_PAYLOAD"])
providers = payload.get("providers") or []
explicit_id = os.environ["EXPLICIT_ID"]
preferred_base = os.environ["PREFERRED_BASE"]

picked = None
if explicit_id:
    for provider in providers:
        if provider.get("provider_id") == explicit_id:
            picked = provider
            break

if picked is None and preferred_base:
    for provider in providers:
        if provider.get("base_url") == preferred_base:
            picked = provider
            break

if picked is None and providers:
    picked = providers[0]

if picked is None:
    print("")
    sys.exit(0)

print(f'{picked.get("provider_id","")}|{picked.get("base_url","")}')
PY
    return 0
  fi

  fail "jq or python3 is required to select provider"
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
log "start_buffer_seconds=${START_BUFFER_SECONDS}"
log "request_timeout_seconds=${REQUEST_TIMEOUT_SECONDS}"

access_payload="$(curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" -X POST "${WEB_BASE}/api/access/${ASSET_ID}")"
token="$(json_get '.access_token' "$access_payload")"
expires_at="$(json_get '.expires_at' "$access_payload")"
[ -n "$token" ] || fail "access token is empty: ${access_payload}"
log "access token acquired (expires_at=${expires_at})"

playback_payload="$(curl -fsS --max-time "$REQUEST_TIMEOUT_SECONDS" "${WEB_BASE}/api/playback/${ASSET_ID}")"
provider_line="$(select_provider "$playback_payload" "$PROVIDER_ID" "$PREFERRED_PROVIDER_BASE")"
[ -n "$provider_line" ] || fail "no provider found in playback payload"
selected_provider_id="${provider_line%%|*}"
selected_provider_base="${provider_line#*|}"
[ -n "$selected_provider_id" ] || fail "selected provider id is empty"
[ -n "$selected_provider_base" ] || fail "selected provider base_url is empty"

log "selected_provider_id=${selected_provider_id}"
log "selected_provider_base=${selected_provider_base}"

playlist_status="$(
  curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" --get \
    --data-urlencode "providerId=${selected_provider_id}" \
    --data-urlencode "token=${token}" \
    -o "$PLAYLIST_FILE" \
    -w '%{http_code}' \
    "${WEB_BASE}/api/playlist/${ASSET_ID}" || true
)"
[ "$playlist_status" = "200" ] || fail "playlist fetch failed with status=${playlist_status}"

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

[ -s "$SEGMENTS_FILE" ] || fail "playlist has no media segments"

log "playlist segments:"
awk -F '\t' '{ printf("  seg_%02d extinf=%.3fs %s\n", $1, $2, $3) }' "$SEGMENTS_FILE"

log "running sequential fetch timing check"
suite_start_ms="$(date +%s%3N)"
running_extinf="0"
late_count=0
error_count=0
segment_count=0

while IFS=$'\t' read -r idx extinf url; do
  segment_count=$((segment_count + 1))
  fetch_start_ms="$(date +%s%3N)"
  stat_line="$(
    curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" \
      -o /dev/null \
      -w '%{http_code}\t%{time_total}\t%{size_download}' \
      "$url" || true
  )"
  IFS=$'\t' read -r status fetch_seconds size_download <<<"$stat_line"
  fetch_end_ms="$(date +%s%3N)"

  elapsed_seconds="$(awk -v s="$suite_start_ms" -v e="$fetch_end_ms" 'BEGIN { printf("%.6f", (e-s)/1000) }')"
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

  printf '[e2e-seq] seg_%02d status=%s extinf=%.3fs fetch=%ss elapsed=%ss deadline=%ss slack=%ss size=%s %s\n' \
    "$idx" "$status" "$extinf" "$fetch_seconds" "$elapsed_seconds" "$deadline_seconds" "$slack_seconds" "$size_download" "$verdict"

  running_extinf="$(awk -v cur="$running_extinf" -v add="$extinf" 'BEGIN { printf("%.6f", cur + add) }')"
  _unused="$fetch_start_ms"
done <"$SEGMENTS_FILE"

log "summary: segments=${segment_count} errors=${error_count} late=${late_count}"

if [ "$error_count" -gt 0 ]; then
  fail "segment fetch had HTTP errors"
fi

if [ "$late_count" -gt 0 ]; then
  fail "sequential fetching missed playback deadlines (increase START_BUFFER_SECONDS or fix provider)"
fi

log "PASS: sequential fetch stays ahead of playback budget"
