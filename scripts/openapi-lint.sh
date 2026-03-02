#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPECTRAL_VERSION="6.15.0"
SPECS=(
  "$ROOT_DIR/services/audistro-fap/api/openapi.v1.yaml"
  "$ROOT_DIR/services/audistro-catalog/api/openapi.v1.yaml"
  "$ROOT_DIR/services/audistro-provider/api/openapi.v1.yaml"
)

run_spectral() {
  if [ -x "$ROOT_DIR/node_modules/.bin/spectral" ]; then
    "$ROOT_DIR/node_modules/.bin/spectral" "$@"
    return
  fi
  if command -v npm >/dev/null 2>&1; then
    if [ -d "$ROOT_DIR/node_modules" ]; then
      (cd "$ROOT_DIR" && npm exec -- spectral "$@")
      return
    fi
    npx -y "@stoplight/spectral-cli@${SPECTRAL_VERSION}" "$@"
    return
  fi

  echo "openapi-lint: spectral is required. Run 'npm install' at repo root or install @stoplight/spectral-cli ${SPECTRAL_VERSION}." >&2
  exit 1
}

run_spectral lint --ruleset "$ROOT_DIR/.spectral.yaml" "${SPECS[@]}"
