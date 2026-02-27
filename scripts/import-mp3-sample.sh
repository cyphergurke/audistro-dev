#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  cat <<'USAGE'
Usage:
  ./scripts/import-mp3-sample.sh <asset-id> <path-to-audio-file> [title]

Examples:
  ./scripts/import-mp3-sample.sh asset_mp3_1 ~/Music/demo.mp3
  ./scripts/import-mp3-sample.sh asset_mp3_2 ./samples/song.mp3 "Song Debug Build"
USAGE
  exit 1
fi

ASSET_ID="$1"
SOURCE_AUDIO_FILE="$2"
TITLE="${3:-$(basename "$SOURCE_AUDIO_FILE")}"

ASSET_ID="$ASSET_ID" \
  TITLE="$TITLE" \
  SOURCE_AUDIO_FILE="$SOURCE_AUDIO_FILE" \
  ./scripts/create-debug-sample.sh
