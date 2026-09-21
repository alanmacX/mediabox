#!/bin/bash
# build_ffmpeg_extras.sh — 重建带完整编码器的 FFmpeg（OHOS arm64-v8a）
#
# 目的：当前 @prq/ffmpeg-tools 2.2.6 随包二进制缺少 libmp3lame / libvpx / libwebp，
# MediaBox 通过运行时探测（FFmpegCapability）对编码器可用性做了动态适配——
# 用本脚本重建并替换二进制后，MP3 / WebM / 动态 WebP 功能自动点亮，无需改代码。
#
# 用法：
#   1. 准备 OpenHarmony Native SDK（aarch64-linux-ohos-clang 工具链），
#      路径传入 OHOS_SDK_NATIVE，例如：
#      /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
#   2. 准备第三方库（见 REPRODUCIBLE_BUILD.md）：libmp3lame、libvpx、libwebp、libopus，
#      头文件与 .a 安装到 $PREFIX。
#   3. ./build_ffmpeg_extras.sh
#   4. 产物 libs/arm64-v8a/libffmpegutils.so 替换
#      oh_modules/.ohpm/@prq+ffmpeg-tools@2.2.6/.../libs/arm64-v8a/libffmpegutils.so
#      并在 LICENSE_AUDIT.md 更新许可清单（libvpx BSD、libwebp BSD、libmp3lame LGPL-2.1）。
set -euo pipefail

: "${OHOS_SDK_NATIVE:?请设置 OHOS_SDK_NATIVE 指向 OpenHarmony native SDK 目录}"
FFMPEG_REF="${FFMPEG_REF:-n6.1.2}"
PREFIX="${PREFIX:-$(pwd)/third_party/install}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/build_ffmpeg}"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

CLANG="$OHOS_SDK_NATIVE/llvm/bin/aarch64-linux-ohos-clang"
STRIP="$OHOS_SDK_NATIVE/llvm/bin/llvm-strip"
SYSROOT="$OHOS_SDK_NATIVE/sysroot"

[ -x "$CLANG" ] || { echo "找不到 $CLANG"; exit 1; }

mkdir -p "$BUILD_DIR" "$PREFIX"
cd "$BUILD_DIR"
if [ ! -d ffmpeg ]; then
  git clone --depth 1 --branch "$FFMPEG_REF" https://git.ffmpeg.org/ffmpeg.git
  cd ffmpeg
  # OHOS 编解码接入补丁：与上游 @prq/ffmpeg-tools 保持同一能力面
  # （h264_ohosavcodec 编解码器）。补丁文件与本脚本同目录维护。
  if [ -f ../../patches/ohos-avcodec.patch ]; then
    git apply ../../patches/ohos-avcodec.patch
  fi
else
  cd ffmpeg
fi

./configure \
  --prefix="$PREFIX" \
  --target-os=linux --arch=aarch64 --enable-cross-compile \
  --cc="$CLANG" --strip="$STRIP" --sysroot="$SYSROOT" \
  --extra-cflags="-fPIC" \
  --disable-neon --disable-asm --disable-x86asm --disable-vulkan \
  --enable-network --enable-protocols \
  --enable-ohosavcodecdecoder --enable-ohosavcodecencoder \
  --enable-openssl --enable-librtmp \
  --enable-libmp3lame --enable-libvpx --enable-libwebp --enable-libopus \
  --enable-gpl \
  --enable-static --enable-pic --disable-shared \
  --disable-doc --disable-htmlpages --disable-programs

make -j"$CORES"
make install

echo "完成。产物位于 $PREFIX"
echo "注意：--enable-gpl 使产物整体转为 GPL 许可；若需保持 LGPL，"
echo "去掉 --enable-gpl 并确认 libvpx/libwebp 以 BSD 许可静态链接即可（libvpx 支持非 GPL）。"
