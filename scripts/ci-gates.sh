#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-all}"
CI_MODE="${CI:-0}"
SKIP_MANUAL="${SKIP_MANUAL:-0}"

log() {
  printf '[ci-gates] %s\n' "$*"
}

fail() {
  printf '[ci-gates] FAIL: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

run() {
  log "RUN: $*"
  "$@"
}

write_if_missing() {
  local path="$1"
  shift
  if [ -f "$path" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
}

ensure_dev_inputs() {
  mkdir -p env secrets

  write_if_missing "secrets/fap_token_secret" <<'EOT'
ci-fap-token-secret-0123456789abcdef
EOT
  chmod 600 secrets/fap_token_secret

  write_if_missing "secrets/origin_hmac_secret" <<'EOT'
ci-origin-hmac-secret-0123456789abcdef
EOT
  chmod 600 secrets/origin_hmac_secret

  write_if_missing "env/audistro-catalog.env" <<'EOT'
AUDICATALOG_HTTP_ADDR=:8080
AUDICATALOG_DB_PATH=/var/lib/audistro-catalog/audistro-catalog.db
CATALOG_ENV=dev
CATALOG_ADMIN_TOKEN=dev-admin-token
CATALOG_PROVIDER_PUBLIC_BASE_URL=http://localhost:18082
CATALOG_PROVIDER_INTERNAL_BASE_URL=http://audistro-provider_eu_1:8080
CATALOG_STORAGE_PATH=/var/lib/audistro-catalog
CATALOG_FAP_INTERNAL_BASE_URL=http://audistro-fap:8080
FAP_PUBLIC_BASE_URL=http://localhost:18081
FAP_ADMIN_TOKEN=dev-admin-token
EOT

  write_if_missing "env/fap.env" <<'EOT'
FAP_HTTP_ADDR=:8080
FAP_DB_PATH=/var/lib/fap/fap.db
FAP_LNBITS_BASE_URL=http://localhost:18090
FAP_LNBITS_INVOICE_API_KEY=
FAP_LNBITS_READONLY_API_KEY=
FAP_ISSUER_PRIVKEY_HEX=1111111111111111111111111111111111111111111111111111111111111111
FAP_MASTER_KEY_HEX=2222222222222222222222222222222222222222222222222222222222222222
FAP_WEBHOOK_SECRET=dev-webhook-secret
FAP_TOKEN_SECRET_PATH=/run/secrets/fap_token_secret
FAP_ADMIN_TOKEN=dev-admin-token
FAP_INTERNAL_ALLOWED_CIDRS=127.0.0.1/32,172.16.0.0/12
FAP_DEV_MODE=false
FAP_EXPOSE_BOLT11_IN_LIST=false
FAP_TOKEN_TTL_SECONDS=900
FAP_INVOICE_EXPIRY_SECONDS=900
FAP_MAX_ACCESS_AMOUNT_MSAT=50000000
FAP_ACCESS_MINUTES_PER_PAYMENT=10
FAP_WEBHOOK_EVENT_RETENTION_SECONDS=604800
FAP_WEBHOOK_EVENT_PRUNE_INTERVAL_SECONDS=300
FAP_DEVICE_COOKIE_SECURE=false
FAP_ENABLE_CORS=true
FAP_CORS_ALLOWED_ORIGINS=http://localhost:3000
FAP_CORS_ALLOW_CREDENTIALS=false
EOT

  write_if_missing "env/audistro-provider.env" <<'EOT'
PROVIDER_HTTP_ADDR=:8080
PROVIDER_DATA_PATH=/var/lib/audistro-provider
PROVIDER_STORAGE_MODE=filesystem
PROVIDER_CATALOG_BASE_URL=http://audistro-catalog:8080
PROVIDER_PUBLIC_BASE_URL=http://localhost:18082
PROVIDER_ALLOW_INSECURE_PUBLIC_URL=true
PROVIDER_TRANSPORT=http
PROVIDER_INTERNAL_ENABLE=true
PROVIDER_INTERNAL_ALLOWED_CIDRS=127.0.0.1/32,::1/128,172.16.0.0/12
PROVIDER_ORIGIN_AUTH_MODE=none
PROVIDER_ORIGIN_HMAC_SECRET_PATH=/run/secrets/origin_hmac_secret
PROVIDER_ENABLE_CORS=true
PROVIDER_CORS_ALLOWED_ORIGINS=http://localhost:3000
EOT

  write_if_missing "env/audistro-provider_eu_1.env" <<'EOT'
PROVIDER_HTTP_ADDR=:8080
PROVIDER_DATA_PATH=/var/lib/audistro-provider
PROVIDER_STORAGE_MODE=filesystem
PROVIDER_CATALOG_BASE_URL=http://audistro-catalog:8080
PROVIDER_PUBLIC_BASE_URL=http://localhost:18082
PROVIDER_ALLOW_INSECURE_PUBLIC_URL=true
PROVIDER_TRANSPORT=http
PROVIDER_INTERNAL_ENABLE=true
PROVIDER_INTERNAL_ALLOWED_CIDRS=127.0.0.1/32,::1/128,172.16.0.0/12
PROVIDER_ORIGIN_AUTH_MODE=none
PROVIDER_ORIGIN_HMAC_SECRET_PATH=/run/secrets/origin_hmac_secret
PROVIDER_ENABLE_CORS=true
PROVIDER_CORS_ALLOWED_ORIGINS=http://localhost:3000
PROVIDER_REGION=eu-central
PROVIDER_ANNOUNCE_PRIORITY=10
EOT

  write_if_missing "env/audistro-provider_eu_2.env" <<'EOT'
PROVIDER_HTTP_ADDR=:8080
PROVIDER_DATA_PATH=/var/lib/audistro-provider
PROVIDER_STORAGE_MODE=filesystem
PROVIDER_CATALOG_BASE_URL=http://audistro-catalog:8080
PROVIDER_PUBLIC_BASE_URL=http://localhost:18083
PROVIDER_ALLOW_INSECURE_PUBLIC_URL=true
PROVIDER_TRANSPORT=http
PROVIDER_INTERNAL_ENABLE=true
PROVIDER_INTERNAL_ALLOWED_CIDRS=127.0.0.1/32,::1/128,172.16.0.0/12
PROVIDER_ORIGIN_AUTH_MODE=none
PROVIDER_ORIGIN_HMAC_SECRET_PATH=/run/secrets/origin_hmac_secret
PROVIDER_ENABLE_CORS=true
PROVIDER_CORS_ALLOWED_ORIGINS=http://localhost:3000
PROVIDER_REGION=eu-central
PROVIDER_ANNOUNCE_PRIORITY=20
EOT

  write_if_missing "env/audistro-provider_us_1.env" <<'EOT'
PROVIDER_HTTP_ADDR=:8080
PROVIDER_DATA_PATH=/var/lib/audistro-provider
PROVIDER_STORAGE_MODE=filesystem
PROVIDER_CATALOG_BASE_URL=http://audistro-catalog:8080
PROVIDER_PUBLIC_BASE_URL=http://localhost:18084
PROVIDER_ALLOW_INSECURE_PUBLIC_URL=true
PROVIDER_TRANSPORT=http
PROVIDER_INTERNAL_ENABLE=true
PROVIDER_INTERNAL_ALLOWED_CIDRS=127.0.0.1/32,::1/128,172.16.0.0/12
PROVIDER_ORIGIN_AUTH_MODE=none
PROVIDER_ORIGIN_HMAC_SECRET_PATH=/run/secrets/origin_hmac_secret
PROVIDER_ENABLE_CORS=true
PROVIDER_CORS_ALLOWED_ORIGINS=http://localhost:3000
PROVIDER_REGION=us-east
PROVIDER_ANNOUNCE_PRIORITY=5
EOT

  write_if_missing "env/lnbits.env" <<'EOT'
LNBITS_HOST=0.0.0.0
LNBITS_PORT=5000
LNBITS_DATA_FOLDER=/data
LNBITS_DEBUG=true
LNBITS_ALLOWED_HOSTS=*
LNBITS_ADMIN_UI=true
OPENNODE_KEY=dev-opennode-key
OPENNODE_API_ENDPOINT=https://api.opennode.com/
LNBITS_BACKEND_WALLET_CLASS=OpenNodeWallet
EOT
}

run_go_tests() {
  run bash -lc 'cd services/audistro-fap && go test ./...'
  run bash -lc 'cd services/audistro-catalog && go test ./...'
  run bash -lc 'cd services/audistro-provider && go test ./...'
}

run_web_checks() {
  run bash -lc 'cd services/audistro-web && pnpm install --frozen-lockfile'
  run bash -lc 'cd services/audistro-web && pnpm gen:openapi'
  run git diff --exit-code -- services/audistro-web/src/gen/fap.ts services/audistro-web/src/gen/catalog.ts services/audistro-web/src/gen/provider.ts
  run bash -lc 'cd services/audistro-web && CI=1 pnpm test'
  run bash -lc 'cd services/audistro-web && CI=1 pnpm typecheck'
  run bash -lc 'cd services/audistro-web && CI=1 pnpm build'
}

run_smokes() {
  run env CI=1 SKIP_MANUAL="$SKIP_MANUAL" ./scripts/smoke-e2e-playback.sh
  run env CI=1 SKIP_MANUAL="$SKIP_MANUAL" SKIP_BOOT=1 ./scripts/smoke-openapi-conformance.sh
  run env CI=1 SKIP_MANUAL="$SKIP_MANUAL" ./scripts/smoke-paid-access.sh
  run env CI=1 SKIP_MANUAL="$SKIP_MANUAL" ./scripts/smoke-upload-encrypt-pay.sh
  run env CI=1 SKIP_MANUAL="$SKIP_MANUAL" ./scripts/smoke-encrypted-failover.sh
}

need_cmd bash
need_cmd docker
need_cmd curl
need_cmd go
need_cmd python3
if ! command -v pnpm >/dev/null 2>&1; then
  if command -v corepack >/dev/null 2>&1; then
    log "pnpm not found; enabling via corepack"
    corepack enable
  fi
fi
need_cmd pnpm
ensure_dev_inputs

case "$MODE" in
  unit)
    run_go_tests
    run_web_checks
    ;;
  smoke)
    run_smokes
    ;;
  all)
    run_go_tests
    run_web_checks
    run_smokes
    ;;
  *)
    fail "usage: ./scripts/ci-gates.sh [unit|smoke|all]"
    ;;
esac

log "PASS: mode=${MODE}"
