#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

create() {
  local asset_id="$1"
  local duration="$2"
  local frequency="$3"
  printf '[create-more-debug-samples] creating %s (duration=%ss freq=%sHz)\n' "$asset_id" "$duration" "$frequency"
  ASSET_ID="$asset_id" \
    TITLE="Debug ${asset_id}" \
    DURATION_SECONDS="$duration" \
    SINE_FREQUENCY="$frequency" \
    ./scripts/create-debug-sample.sh
}

create "asset3" "12" "523"
create "asset4" "9" "659"
create "asset5" "15" "784"

printf '[create-more-debug-samples] done. test urls:\n'
printf '  - http://localhost:3000/asset/asset3\n'
printf '  - http://localhost:3000/asset/asset4\n'
printf '  - http://localhost:3000/asset/asset5\n'
