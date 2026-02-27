#!/usr/bin/env bash
set -euo pipefail

PROVIDER_BASE="${1:-http://localhost:18082/assets/asset1}"
PLAYLIST_URL="${2:-${PROVIDER_BASE%/}/master.m3u8}"
REQUEST_TIMEOUT_SECONDS="${REQUEST_TIMEOUT_SECONDS:-8}"

TMP_DIR="$(mktemp -d)"
PLAYLIST_FILE="$TMP_DIR/master.m3u8"
SEGMENTS_FILE="$TMP_DIR/segments.tsv"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

now_ms() {
  date +%s%3N
}

fetch_stat() {
  local url="$1"
  local out
  if out="$(curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" -o /dev/null -w '%{http_code}\t%{time_total}\t%{size_download}' "$url" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '000\t0\t0\n'
  return 1
}

printf 'Provider base: %s\n' "$PROVIDER_BASE"
printf 'Playlist URL : %s\n' "$PLAYLIST_URL"
printf 'Timeout      : %ss\n' "$REQUEST_TIMEOUT_SECONDS"
printf '\n'

curl -sS --max-time "$REQUEST_TIMEOUT_SECONDS" "$PLAYLIST_URL" -o "$PLAYLIST_FILE"

awk -v base="$PROVIDER_BASE" '
  BEGIN { dur = ""; idx = 0 }
  /^#EXTINF:/ {
    line = $0
    sub(/^#EXTINF:/, "", line)
    sub(/,.*/, "", line)
    dur = line + 0
    next
  }
  /^#/ { next }
  NF {
    url = $0
    if (url !~ /^https?:\/\//) {
      sep = (base ~ /\/$/) ? "" : "/"
      url = base sep url
    }
    printf("%d\t%.6f\t%s\n", idx, dur, url)
    idx++
  }
' "$PLAYLIST_FILE" >"$SEGMENTS_FILE"

if [[ ! -s "$SEGMENTS_FILE" ]]; then
  printf 'No segments found in playlist.\n' >&2
  exit 1
fi

printf 'Segments from playlist:\n'
awk -F '\t' '{ printf("  seg_%02d extinf=%.3fs %s\n", $1, $2, $3) }' "$SEGMENTS_FILE"
printf '\n'

printf '=== Sequential Fetch (one-by-one) ===\n'
seq_wall_start="$(now_ms)"
while IFS=$'\t' read -r idx extinf url; do
  seg_start="$(now_ms)"
  stat="$(fetch_stat "$url")"
  IFS=$'\t' read -r status time_total size_download <<<"$stat"
  offset_ms=$((seg_start - seq_wall_start))
  verdict="OK"
  awk_check="$(awk -v s="$status" -v t="$time_total" -v e="$extinf" 'BEGIN { if (s != 200 || t > e) print 1; else print 0 }')"
  if [[ "$awk_check" == "1" ]]; then
    verdict="LATE/ERR"
  fi
  printf '  +%5dms seg_%02d status=%s extinf=%.3fs fetch=%ss size=%s %s\n' \
    "$offset_ms" "$idx" "$status" "$extinf" "$time_total" "$size_download" "$verdict"
done <"$SEGMENTS_FILE"
seq_wall_end="$(now_ms)"
printf '  sequential wall-clock: %.3fs\n' "$(awk -v a="$seq_wall_start" -v b="$seq_wall_end" 'BEGIN { printf("%.3f", (b-a)/1000) }')"
printf '\n'

printf '=== Parallel Fetch (all segments in parallel) ===\n'
par_wall_start="$(now_ms)"
while IFS=$'\t' read -r idx extinf url; do
  (
    seg_start="$(now_ms)"
    stat="$(fetch_stat "$url")"
    IFS=$'\t' read -r status time_total size_download <<<"$stat"
    seg_end="$(now_ms)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$idx" "$extinf" "$url" "$seg_start" "$seg_end" "$status" "$time_total" "$size_download" \
      >"$TMP_DIR/par_${idx}.tsv"
  ) &
done <"$SEGMENTS_FILE"
wait
par_wall_end="$(now_ms)"

find "$TMP_DIR" -maxdepth 1 -name 'par_*.tsv' -print0 | sort -z | while IFS= read -r -d '' file; do
  IFS=$'\t' read -r idx extinf url seg_start seg_end status time_total size_download <"$file"
  start_offset_ms=$((seg_start - par_wall_start))
  end_offset_ms=$((seg_end - par_wall_start))
  verdict="OK"
  if [[ "$status" != "200" ]]; then
    verdict="ERR"
  fi
  printf '  +%5dms..+%5dms seg_%02d status=%s extinf=%.3fs fetch=%ss size=%s %s\n' \
    "$start_offset_ms" "$end_offset_ms" "$idx" "$status" "$extinf" "$time_total" "$size_download" "$verdict"
done

printf '  parallel wall-clock: %.3fs\n' "$(awk -v a="$par_wall_start" -v b="$par_wall_end" 'BEGIN { printf("%.3f", (b-a)/1000) }')"
printf '\n'
printf 'Interpretation:\n'
printf '  - If parallel and sequential fetch times are tiny, provider is fast.\n'
printf '  - HLS clients usually fetch fragments mostly sequentially (with buffer-ahead), not fully in parallel.\n'
printf '  - 404/timeout on early segments indicates provider/data issue, not browser performance.\n'
