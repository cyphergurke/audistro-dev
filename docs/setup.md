# Setup

## 1) Sync services from GitHub

```bash
cd /home/goku/code/audistro-dev
./scripts/setup-dev.sh
```

## 2) Configure env/secrets

- Edit files in `env/`.
- Ensure required files exist in `secrets/`:
  - `fap_token_secret`
  - `origin_hmac_secret`
  - optional LNbits/OpenNode files depending on your mode.

## 3) Start stack

```bash
docker compose up -d --build
```

## 4) Verify

```bash
docker compose ps
./scripts/ci-gates.sh unit
CI=1 SKIP_MANUAL=1 ./scripts/ci-gates.sh smoke
```

If you want to force a manual payment path locally:

```bash
./scripts/smoke-paid-access.sh --wait-manual
./scripts/smoke-upload-encrypt-pay.sh --wait-manual
```
