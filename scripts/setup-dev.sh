#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/versions/services.lock"
SERVICES_DIR="${ROOT_DIR}/services"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/setup-dev.sh [--update-only]

Behavior:
  - Reads versions/services.lock
  - Clones missing services into ./services
  - Updates existing git services to the configured ref
  - If a service folder exists without .git, it is moved to a timestamped backup and re-cloned
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

ensure_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[setup-dev] missing required tool: $tool" >&2
    exit 1
  fi
}

sync_service() {
  local name="$1"
  local repo="$2"
  local ref="$3"
  local path="${SERVICES_DIR}/${name}"
  local backup_path=""

  if [[ -z "$repo" ]]; then
    if [[ -d "$path" ]]; then
      echo "[setup-dev] WARN: repo URL empty for ${name}; using existing folder ${path}"
      return
    fi
    echo "[setup-dev] ERROR: repo URL empty for ${name} and folder missing: ${path}" >&2
    exit 1
  fi

  if [[ ! -d "$path" ]]; then
    echo "[setup-dev] cloning ${name} from ${repo}"
    if ! git clone "$repo" "$path"; then
      echo "[setup-dev] ERROR: clone failed for ${name} (${repo})" >&2
      exit 1
    fi
  elif [[ ! -d "$path/.git" ]]; then
    backup_path="${path}.backup-$(date +%Y%m%d%H%M%S)"
    mv "$path" "$backup_path"
    echo "[setup-dev] moved non-git folder ${path} -> ${backup_path}"
    echo "[setup-dev] cloning ${name} from ${repo}"
    if ! git clone "$repo" "$path"; then
      echo "[setup-dev] WARN: clone failed for ${name}; restoring local copy from ${backup_path}"
      mv "$backup_path" "$path"
      return
    fi
  else
    echo "[setup-dev] updating ${name}"
    git -C "$path" remote set-url origin "$repo"
    git -C "$path" fetch --tags origin
  fi

  if [[ -z "$ref" ]]; then
    ref="main"
  fi

  if ! git -C "$path" show-ref --head --quiet; then
    echo "[setup-dev] WARN: ${name} repository has no commits yet; skipping ref checkout"
    return
  fi

  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
    git -C "$path" checkout -B "$ref" "origin/${ref}"
  else
    git -C "$path" checkout "$ref"
  fi
}

main() {
  local mode="${1:-}"
  if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
    usage
    exit 0
  fi
  if [[ -n "$mode" && "$mode" != "--update-only" ]]; then
    echo "[setup-dev] unknown argument: $mode" >&2
    usage
    exit 1
  fi

  ensure_tool git
  ensure_tool docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "[setup-dev] docker compose is required" >&2
    exit 1
  fi

  if [[ ! -f "$LOCK_FILE" ]]; then
    echo "[setup-dev] lock file not found: $LOCK_FILE" >&2
    exit 1
  fi

  mkdir -p "$SERVICES_DIR"

  while IFS='|' read -r raw_name raw_repo raw_ref; do
    local_name="$(trim "${raw_name:-}")"
    local_repo="$(trim "${raw_repo:-}")"
    local_ref="$(trim "${raw_ref:-}")"
    if [[ -z "$local_name" || "${local_name:0:1}" == "#" ]]; then
      continue
    fi
    sync_service "$local_name" "$local_repo" "$local_ref"
  done <"$LOCK_FILE"

  echo "[setup-dev] done"
  if [[ "$mode" != "--update-only" ]]; then
    echo "[setup-dev] next: docker compose up -d --build"
  fi
}

main "$@"
