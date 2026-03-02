#!/usr/bin/env bash
set -euo pipefail

ASSET_ID="${ASSET_ID:?ASSET_ID is required}"
PROVIDER_URL="${PROVIDER_URL:-http://localhost:18082}"
FAP_PUBLIC_BASE_URL="${FAP_PUBLIC_BASE_URL:-http://localhost:18081}"

playlist_url="${PROVIDER_URL%/}/assets/${ASSET_ID}/master.m3u8"
expected_uri="${FAP_PUBLIC_BASE_URL%/}/hls/${ASSET_ID}/key"

payload="$(curl -fsS "$playlist_url")"
printf '%s\n' "$payload" | grep -q '#EXT-X-KEY:METHOD=AES-128' || {
  printf 'FAIL: playlist missing AES-128 key line: %s\n' "$playlist_url" >&2
  exit 1
}
printf '%s\n' "$payload" | grep -q "$expected_uri" || {
  printf 'FAIL: playlist missing expected key URI %s\n' "$expected_uri" >&2
  exit 1
}
printf 'PASS: encrypted playlist verified for asset=%s\n' "$ASSET_ID"
