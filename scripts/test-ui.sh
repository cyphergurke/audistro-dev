#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WAIT_SECONDS="${WAIT_SECONDS:-120}"

log() {
  printf '[test-ui] %s\n' "$*"
}

fail() {
  printf '[test-ui] FAIL: %s\n' "$*" >&2
  exit 1
}

wait_http_200() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))

  while :; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    if [ "$code" = "200" ]; then
      log "PASS: ${name}"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "timeout waiting for ${name} at ${url} (last code=${code})"
    fi
    sleep 1
  done
}

log "Running playback smoke setup (seeds asset1 and validates backend flow)"
./scripts/smoke-e2e-playback.sh

log "Starting audistro-web service"
docker compose up -d --build audistro-web

wait_http_200 "audistro-web index" "http://localhost:3000/"
wait_http_200 "audistro-web playback proxy" "http://localhost:3000/api/playback/asset1"

log "PASS: UI smoke checks succeeded"
