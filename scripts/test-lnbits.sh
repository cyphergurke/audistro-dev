#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '[test-lnbits] %s\n' "$*"
}

fail() {
  printf '[test-lnbits] FAIL: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

need_cmd docker
need_cmd curl

log "starting lnbits service"
docker compose up -d lnbits >/dev/null

lnbits_url="http://localhost:18090/"
deadline=$((SECONDS + 90))

log "waiting for LNbits at ${lnbits_url}"
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS "$lnbits_url" >/dev/null 2>&1; then
    log "PASS lnbits is reachable"
    log "open: ${lnbits_url}"
    exit 0
  fi
  sleep 2
done

docker compose logs --no-color --tail=80 lnbits || true
fail "lnbits did not become reachable within timeout"
