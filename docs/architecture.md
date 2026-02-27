# Architecture

`audistro-dev` is the orchestration layer for local integration.

## Responsibilities of this repo

- Docker Compose topology for all services.
- Shared env and secrets wiring.
- Cross-service smoke scripts.
- Service source synchronization from GitHub via lock file.

## Responsibilities of service repos

- `services/audistro-catalog`: catalog APIs, provider hints, playback metadata.
- `services/audistro-fap`: access payments, boosts, ledger, key gating.
- `services/audistro-provider`: HLS serving and announcements.
- `services/audistro-web`: fan UI and server routes.

## Source of truth

- Compose + env/secrets in `audistro-dev`.
- Per-service code in each service repo.
- Service refs pinned in `versions/services.lock`.
