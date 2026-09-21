#!/usr/bin/env bash
set -euo pipefail

# Build-time only. Never regenerate fixtures while the benchmark is running.
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/entry/src/main/resources/rawfile/fixtures"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=1280x720:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -t 4 -c:v libx264 -preset fast -profile:v baseline -pix_fmt yuv420p \
  -b:v 1800k -maxrate 2200k -bufsize 4400k \
  -c:a aac -b:a 96k -movflags +faststart -shortest \
  "$out/benchmark_h264_aac_720p.mp4"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=2048x1152:rate=1' \
  -frames:v 1 -q:v 2 -update 1 "$out/benchmark_image_2048.jpg"

ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 "$out/benchmark_h264_aac_720p.mp4"
ffprobe -v error -show_entries stream=width,height \
  -of default=noprint_wrappers=1 "$out/benchmark_image_2048.jpg"
