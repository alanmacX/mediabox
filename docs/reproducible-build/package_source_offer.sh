#!/bin/bash
# Assemble the exact upstream source inputs and build instructions.
# This is a technical source kit, not a legal-compliance certification.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$ROOT/build_ffmpeg_encoders}"
OUT="${OUT:-$WORK/MediaBox-FFmpeg-source-and-relink.tar.gz}"
STAGE="$(mktemp -d)"
KIT="$STAGE/MediaBox-FFmpeg-source-and-relink"
mkdir -p "$KIT/upstream"

test "$(git -C "$WORK/openharmony_ffmpeg_6" rev-parse HEAD)" = 085ae3bceb7a576e7c4aff68d7be36d2145023f9
test "$(git -C "$WORK/upstream_ffmpeg_tools" rev-parse HEAD)" = 0680a973c0452137718fa22dcd09c2f158f7e1af

git -C "$WORK/openharmony_ffmpeg_6" archive --format=tar.gz -o "$KIT/upstream/openharmony-ffmpeg-ohos-n6.1.2.tar.gz" HEAD
git -C "$WORK/upstream_ffmpeg_tools" archive --format=tar.gz \
  -o "$KIT/upstream/ffmpeg-tools-wrapper-2.2.6.tar.gz" HEAD \
  LICENSE src/main/cpp/fftools src/main/cpp/napi_ffmpeg.cpp
cp "$WORK/lame-3.100.tar.gz" "$KIT/upstream/"
cp "$WORK/libvpx-1.14.1.tar.gz" "$KIT/upstream/"
cp "$WORK/libwebp-1.3.2-src.tar.gz" "$KIT/upstream/"
cp "$WORK/libaom-3.8.0.tar.gz" "$KIT/upstream/"
cp "$ROOT/docs/reproducible-build/rebuild_ffmpeg_encoders.sh" "$KIT/"
cp "$ROOT/docs/reproducible-build/CMakeLists.ffmpeg-wrapper.txt" "$KIT/"
cp "$ROOT/docs/reproducible-build/SOURCE_OFFER_README.md" "$KIT/README.md"
cp "$ROOT/docs/LICENSE_AUDIT.md" "$KIT/"
cp "$ROOT/entry/src/main/resources/rawfile/open_source_notices.md" "$KIT/"

(
  cd "$KIT"
  shasum -a 256 upstream/* > SHA256SUMS
  shasum -a 256 "$WORK/libffmpegutils-lgpl3.so" | awk '{print $1 "  libffmpegutils.so"}' > REFERENCE_BINARY_SHA256.txt
)

tar -czf "$OUT" -C "$STAGE" MediaBox-FFmpeg-source-and-relink
shasum -a 256 "$OUT"
echo "Source kit: $OUT"
echo 'Publish this exact-version source kit and provide a tested relink path before release; see LICENSE_AUDIT.md.'
