# audistro-dev

Orchestrator workspace for local development of:

- `audistro-catalog`
- `audistro-fap`
- `audistro-provider`
- `audistro-web`

This repository keeps compose/env/scripts/docs in one place. Service source code lives under `services/` and is synced via GitHub.

## Layout

```text
audistro-dev/
  docker-compose.yml
  env/
  secrets/
  scripts/
  versions/services.lock
  docs/
  services/
    audistro-catalog/
    audistro-fap/
    audistro-provider/
    audistro-web/
```

## Bootstrap

```bash
cd /home/goku/code/audistro-dev
./scripts/setup-dev.sh
```

Then start stack:

```bash
docker compose up -d --build
```

## Update Service Repos

```bash
./scripts/update-dev.sh
```

## Lock File

Service sources are controlled by:

- [`versions/services.lock`](/home/goku/code/audistro-dev/versions/services.lock)

Format:

```text
service|repo_url|ref
```

`ref` can be branch, tag, or commit.

If a repo URL is private or unavailable, `setup-dev.sh` keeps the existing local folder (if present) and prints a warning. Update the URL in `services.lock` to your accessible GitHub origin.

## Notes

- If a service folder exists but is not a git repo, `setup-dev.sh` moves it to a timestamped backup and re-clones from the lock file.
