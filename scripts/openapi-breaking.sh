#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"
ERR_IGNORE_FILE="$ROOT_DIR/config/oasdiff/err-ignore.txt"
OASDIFF_VERSION="v1.11.10"
ENTRIES=(
  "services/audistro-fap|api/openapi.v1.yaml"
  "services/audistro-catalog|api/openapi.v1.yaml"
  "services/audistro-provider|api/openapi.v1.yaml"
)

run_oasdiff() {
  if command -v oasdiff >/dev/null 2>&1; then
    oasdiff "$@"
    return
  fi
  if command -v go >/dev/null 2>&1; then
    go run "github.com/oasdiff/oasdiff@${OASDIFF_VERSION}" "$@"
    return
  fi

  echo "openapi-breaking: oasdiff is required. Install github.com/oasdiff/oasdiff@${OASDIFF_VERSION} or ensure Go is available." >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

skipped=0
compared=0

for entry in "${ENTRIES[@]}"; do
  service_dir="${entry%%|*}"
  spec_rel="${entry#*|}"
  repo_dir="$ROOT_DIR/$service_dir"
  current="$repo_dir/$spec_rel"
  base="$TMP_DIR/$(basename "$service_dir")-$(basename "$spec_rel")"

  if [ ! -d "$repo_dir/.git" ]; then
    echo "openapi-breaking: expected nested git repo at $repo_dir" >&2
    exit 1
  fi
  if [ ! -f "$current" ]; then
    echo "openapi-breaking: current spec missing at $current" >&2
    exit 1
  fi

  if ! git -C "$repo_dir" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "openapi-breaking: baseline ref $BASE_REF not found in $service_dir" >&2
    exit 1
  fi

  if ! git -C "$repo_dir" cat-file -e "$BASE_REF:$spec_rel" 2>/dev/null; then
    echo "Skipping $service_dir/$spec_rel: no baseline spec in $BASE_REF"
    skipped=$((skipped + 1))
    continue
  fi

  git -C "$repo_dir" show "$BASE_REF:$spec_rel" > "$base"
  echo "Comparing $service_dir/$spec_rel against $BASE_REF"
  args=(breaking --fail-on WARN)
  if [ -f "$ERR_IGNORE_FILE" ]; then
    args+=(--err-ignore "$ERR_IGNORE_FILE")
  fi
  args+=("$base" "$current")
  run_oasdiff "${args[@]}"
  compared=$((compared + 1))
done

echo "openapi-breaking: compared=$compared skipped=$skipped"
