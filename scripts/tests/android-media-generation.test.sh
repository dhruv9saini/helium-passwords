#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-media-generation.XXXXXX")
cleanup() { find "$fixture_dir" -depth -delete; }
trap cleanup EXIT

"$repo_root/scripts/android-media/generate-fixtures.sh" "$fixture_dir"
(
  cd "$fixture_dir"
  sha256sum -c SHA256SUMS
)

grep -Fq '"profile": "High"' "$fixture_dir/h264-high-aac.ffprobe.json"
grep -Fq '"codec_name": "av1"' "$fixture_dir/av1-opus.ffprobe.json"
grep -Fqx '#EXT-X-MAP:URI="init.mp4"' "$fixture_dir/hls/stream.m3u8"
grep -Fqx 'segment-000.m4s' "$fixture_dir/hls/stream.m3u8"
grep -Fqx 'segment-001.m4s' "$fixture_dir/hls/stream.m3u8"
grep -Fq '<BaseURL>h264-aac-fragmented.mp4</BaseURL>' \
  "$fixture_dir/dash/stream.mpd"

mapfile -t hls_segments < <(
  find "$fixture_dir/hls" -maxdepth 1 -type f -name 'segment-*.m4s' \
    -printf '%f\n' | sort
)
[[ "${hls_segments[*]}" == 'segment-000.m4s segment-001.m4s' ]]

printf 'android_media_generation=passed\n'
