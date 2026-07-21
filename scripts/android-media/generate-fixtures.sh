#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 64
fi

output_dir=$1
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null
command -v sha256sum >/dev/null
mkdir -p "$output_dir"

common_input=(
  -f lavfi -i testsrc2=size=320x180:rate=30
  -f lavfi -i sine=frequency=440:sample_rate=48000
  -t 2 -shortest -map_metadata -1 -threads 1 -fflags +bitexact
)

ffmpeg -hide_banner -loglevel error -nostdin -y \
  "${common_input[@]}" \
  -c:v libx264 -profile:v baseline -level:v 3.0 -pix_fmt yuv420p \
  -preset veryfast -g 30 -keyint_min 30 -sc_threshold 0 \
  -c:a aac -b:a 96k -movflags +faststart \
  "$output_dir/h264-aac.mp4"

ffmpeg -hide_banner -loglevel error -nostdin -y \
  -i "$output_dir/h264-aac.mp4" -map 0 -c copy \
  -movflags +frag_keyframe+empty_moov+default_base_moof \
  "$output_dir/h264-aac-fragmented.mp4"

ffmpeg -hide_banner -loglevel error -nostdin -y \
  "${common_input[@]}" \
  -c:v libvpx-vp9 -deadline good -cpu-used 4 -row-mt 0 -g 30 -pix_fmt yuv420p \
  -b:v 400k -c:a libopus -b:a 64k -flags:v +bitexact -flags:a +bitexact \
  "$output_dir/vp9-opus.webm"

(
  cd "$output_dir"
  sha256sum h264-aac.mp4 h264-aac-fragmented.mp4 vp9-opus.webm > SHA256SUMS
  ffprobe -v error -show_entries stream=index,codec_name,codec_type,profile,width,height,sample_rate,channels \
    -of json h264-aac.mp4 > h264-aac.ffprobe.json
  ffprobe -v error -show_entries stream=index,codec_name,codec_type,profile,width,height,sample_rate,channels \
    -of json vp9-opus.webm > vp9-opus.ffprobe.json
  ffmpeg -hide_banner -version | head -1 > FFMPEG_VERSION
)
