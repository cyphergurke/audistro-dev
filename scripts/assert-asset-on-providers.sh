#!/usr/bin/env bash
set -euo pipefail

ASSET_ID="${ASSET_ID:-}"
PROVIDER_EU_1_URL="${PROVIDER_EU_1_URL:-http://localhost:18082}"
PROVIDER_EU_2_URL="${PROVIDER_EU_2_URL:-http://localhost:18083}"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<'USAGE'
Usage: ASSET_ID=<assetId> ./scripts/assert-asset-on-providers.sh

Checks that eu_1 and eu_2 both serve master.m3u8 for the given asset.
USAGE
      exit 0
      ;;
    *)
      printf '[assert-asset-on-providers] FAIL: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

[ -n "$ASSET_ID" ] || {
  printf '[assert-asset-on-providers] FAIL: ASSET_ID is required\n' >&2
  exit 1
}

check_provider() {
  local name="$1"
  local base_url="$2"
  local url="${base_url%/}/assets/${ASSET_ID}/master.m3u8"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  if [ "$code" != "200" ]; then
    printf '[assert-asset-on-providers] FAIL: %s missing asset %s (master.m3u8 code=%s)\n' "$name" "$ASSET_ID" "$code" >&2
    exit 1
  fi
  printf '[assert-asset-on-providers] PASS: %s serves %s\n' "$name" "$url"
}

check_provider "eu_1" "$PROVIDER_EU_1_URL"
check_provider "eu_2" "$PROVIDER_EU_2_URL"
