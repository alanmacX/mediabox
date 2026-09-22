#!/bin/bash
# rebuild_ffmpeg_encoders.sh
# 目标：为 aarch64-linux-ohos 重建 FFmpeg，补上 libmp3lame / libvpx / libwebp，
# 使用带 OHOS 硬件编解码源码的 FFmpeg 分支，以 LGPLv3+ 构建并重链 libffmpegutils.so。
#
# 用法（在 macOS + DevEco Studio 本机）：
#   export OHOS_SDK_NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
#   bash docs/reproducible-build/rebuild_ffmpeg_encoders.sh
set -euo pipefail

ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="${WORK:-$ROOT/build_ffmpeg_encoders}"
PREFIX="${PREFIX:-$WORK/install}"
SOURCE_KIT_DIR="${SOURCE_KIT_DIR:-}"
PACKAGE_OUTPUT="${PACKAGE_OUTPUT:-$ROOT/vendor/ffmpeg-tools-lgpl3-2.2.6.har}"
WRAPPER_CMAKE="${WRAPPER_CMAKE:-$ROOT/docs/reproducible-build/CMakeLists.ffmpeg-wrapper.txt}"
if [ -n "$SOURCE_KIT_DIR" ]; then
  WRAPPER_CMAKE="$SOURCE_KIT_DIR/CMakeLists.ffmpeg-wrapper.txt"
fi
OHOS_SDK_NATIVE="${OHOS_SDK_NATIVE:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
UPSTREAM_REF="0680a973c0452137718fa22dcd09c2f158f7e1af"
UPSTREAM_DIR="$WORK/upstream_ffmpeg_tools"
WRAP_SRC="${WRAP_SRC:-$WORK/wrapper-src}"
FFMPEG_REF="085ae3bceb7a576e7c4aff68d7be36d2145023f9"
FFMPEG_SRC="$WORK/openharmony_ffmpeg_6"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

CLANG="$OHOS_SDK_NATIVE/llvm/bin/aarch64-linux-ohos-clang"
CLANGXX="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
# toolchain may use aarch64-unknown-linux-ohos-clang
if [ ! -x "$CLANG" ]; then
  CLANG="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
fi
if [ ! -x "$CLANGXX" ]; then
  CLANGXX="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
fi
STRIP="$OHOS_SDK_NATIVE/llvm/bin/llvm-strip"
LLVM_AR="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
SYSROOT="$OHOS_SDK_NATIVE/sysroot"
CMAKE="$OHOS_SDK_NATIVE/build-tools/cmake/bin/cmake"

[ -x "$CLANG" ] || { echo "missing clang: $CLANG"; exit 1; }
[ -x "$LLVM_AR" ] || { echo "missing llvm-ar"; exit 1; }

export PATH="$(dirname "$CLANG"):$(dirname "$CMAKE"):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
command -v pkg-config >/dev/null || { echo 'pkg-config/pkgconf is required' >&2; exit 1; }

HOST_TRIPLE="aarch64-linux-ohos"
export CC="$CLANG"
export CXX="$CLANGXX"
export AR="$LLVM_AR"
export RANLIB="$OHOS_SDK_NATIVE/llvm/bin/llvm-ranlib"
export STRIP="$STRIP"
export CFLAGS="-fPIC -O2"
export CXXFLAGS="-fPIC -O2"
export LDFLAGS="-fPIC --sysroot=$SYSROOT"

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

if [ -n "$SOURCE_KIT_DIR" ]; then
  test -f "$SOURCE_KIT_DIR/upstream/ffmpeg-tools-wrapper-2.2.6.tar.gz"
  mkdir -p "$UPSTREAM_DIR"
  tar xzf "$SOURCE_KIT_DIR/upstream/ffmpeg-tools-wrapper-2.2.6.tar.gz" -C "$UPSTREAM_DIR"
  for source in lame-3.100.tar.gz libvpx-1.14.1.tar.gz libwebp-1.3.2-src.tar.gz libaom-3.8.0.tar.gz; do
    cp "$SOURCE_KIT_DIR/upstream/$source" "$WORK/$source"
  done
else
  if [ ! -d "$UPSTREAM_DIR/.git" ]; then
    git clone https://github.com/jjjjjjava/ffmpeg_tools.git "$UPSTREAM_DIR"
  fi
  git -C "$UPSTREAM_DIR" checkout --detach "$UPSTREAM_REF"
fi
if [ ! -d "$WRAP_SRC" ]; then
  mkdir -p "$WRAP_SRC"
  cp -R "$UPSTREAM_DIR/src/main/cpp/fftools" "$WRAP_SRC/"
  cp "$UPSTREAM_DIR/src/main/cpp/napi_ffmpeg.cpp" "$WRAP_SRC/"
fi
cp "$WRAPPER_CMAKE" "$WRAP_SRC/CMakeLists.txt"

fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "Downloading $url"
    curl -L --fail --retry 3 -o "$out" "$url"
  fi
}
verify_sha256() {
  local expected="$1" file="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || { echo "SHA-256 mismatch: $file" >&2; exit 1; }
}

echo "==== 1) third-party: LAME / libvpx / libwebp / libaom ===="
fetch "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" lame-3.100.tar.gz
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz" libvpx-1.14.1.tar.gz
# GitHub 源码包没有预生成 configure，必须用官方 release tarball
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2.tar.gz" libwebp-1.3.2-src.tar.gz
fetch "https://aomedia.googlesource.com/aom/+archive/v3.8.0.tar.gz" libaom-3.8.0.tar.gz
verify_sha256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e lame-3.100.tar.gz
verify_sha256 901747254d80a7937c933d03bd7c5d41e8e6c883e0665fadcb172542167c7977 libvpx-1.14.1.tar.gz
verify_sha256 2a499607df669e40258e53d0ade8035ba4ec0175244869d1025d460562aa09b4 libwebp-1.3.2-src.tar.gz
verify_sha256 cbf7bfeeb189751d9439022db95677a661faabcc0bf12b75c14711486882c022 libaom-3.8.0.tar.gz

# LAME — config.sub 不识别 ohos 三元组，用 aarch64-linux-gnu + OHOS clang 覆盖
if [ ! -f "$PREFIX/lib/libmp3lame.a" ]; then
  rm -rf lame-3.100
  tar xzf lame-3.100.tar.gz
  cd lame-3.100
  ./configure --host=aarch64-linux-gnu --prefix="$PREFIX" --disable-frontend --disable-shared --enable-static \
    --with-pic CC="$CLANG" CFLAGS="$CFLAGS --target=aarch64-linux-ohos" \
    LDFLAGS="$LDFLAGS --target=aarch64-linux-ohos"
  make -j"$CORES"
  make install
  cd "$WORK"
fi

if [ ! -f "$PREFIX/lib/libaom.a" ]; then
  mkdir -p libaom-src
  tar xzf libaom-3.8.0.tar.gz -C libaom-src
  "$CMAKE" -S libaom-src -B libaom-build \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK_NATIVE/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 \
    -DENABLE_DOCS=0 -DCONFIG_AV1_DECODER=0 -DCONFIG_AV1_ENCODER=1
  "$CMAKE" --build libaom-build -j "$CORES"
  "$CMAKE" --install libaom-build
fi

# libvpx
if [ ! -f "$PREFIX/lib/libvpx.a" ]; then
  rm -rf libvpx-1.14.1
  tar xzf libvpx-1.14.1.tar.gz
  cd libvpx-1.14.1
  # libvpx configure 不接受 CC= 参数，必须通过环境变量传入
  CC="$CLANG" CXX="$CLANGXX" \
  CFLAGS="$CFLAGS --target=aarch64-linux-ohos" \
  CXXFLAGS="$CXXFLAGS --target=aarch64-linux-ohos" \
  LDFLAGS="$LDFLAGS --target=aarch64-linux-ohos" \
  ./configure --target=arm64-linux-gcc --prefix="$PREFIX" --disable-examples --disable-tools --disable-docs \
    --disable-unit-tests --enable-vp8 --enable-vp9 --enable-static --disable-shared --enable-pic \
    --as=auto --disable-werror
  make -j"$CORES"
  make install
  cd "$WORK"
fi

# libwebp
if [ ! -f "$PREFIX/lib/libwebp.a" ]; then
  rm -rf libwebp-1.3.2
  tar xzf libwebp-1.3.2-src.tar.gz
  cd libwebp-1.3.2
  ./configure --host=aarch64-linux-gnu --prefix="$PREFIX" --disable-shared --enable-static --enable-libwebpmux \
    --disable-gl --disable-sdl --disable-tiff --disable-jpeg --disable-png --disable-gif \
    CC="$CLANG" CFLAGS="$CFLAGS --target=aarch64-linux-ohos" \
    LDFLAGS="$LDFLAGS --target=aarch64-linux-ohos"
  make -j"$CORES"
  make install
  cd "$WORK"
fi

echo "==== 2) FFmpeg $FFMPEG_REF ===="
if [ -n "$SOURCE_KIT_DIR" ]; then
  test -f "$SOURCE_KIT_DIR/upstream/openharmony-ffmpeg-ohos-n6.1.2.tar.gz"
  mkdir -p "$FFMPEG_SRC"
  tar xzf "$SOURCE_KIT_DIR/upstream/openharmony-ffmpeg-ohos-n6.1.2.tar.gz" -C "$FFMPEG_SRC"
else
  if [ ! -d "$FFMPEG_SRC/.git" ]; then
    git clone --branch ohos-n6.1.2 https://gitee.com/openharmony-tpc-incubate/FFmpeg.git "$FFMPEG_SRC"
  fi
  git -C "$FFMPEG_SRC" checkout --detach "$FFMPEG_REF"
fi
cd "$FFMPEG_SRC"
if [ -f ffbuild/config.mak ]; then
  make distclean
fi

# Local First：不启用 openssl/librtmp/网络协议扩展，MediaBox 业务不暴露 URL/RTMP。
./configure \
  --prefix="$PREFIX/ffmpeg" \
  --pkg-config="$(command -v pkg-config)" \
  --pkg-config-flags="--static" \
  --target-os=linux --arch=aarch64 --enable-cross-compile \
  --cc="$CLANG" --cxx="$CLANGXX" --ar="$LLVM_AR" --ranlib="$RANLIB" --strip="$STRIP" \
  --sysroot="$SYSROOT" \
  --extra-cflags="-fPIC -I$PREFIX/include" \
  --extra-ldflags="-fPIC -L$PREFIX/lib" \
  --extra-libs="-lm -lz" \
  --disable-neon --disable-asm --disable-x86asm --disable-vulkan \
  --disable-network \
  --enable-protocol=file --enable-protocol=pipe --enable-protocol=data \
  --enable-protocol=cache --enable-protocol=crypto --enable-protocol=subfile \
  --enable-libmp3lame --enable-libvpx --enable-libwebp --enable-libaom \
  --enable-version3 --enable-ohosavcodecdecoder --enable-ohosavcodecencoder \
  --disable-decoder=libaom_av1 \
  --enable-static --enable-pic --disable-shared \
  --disable-doc --disable-htmlpages --disable-programs

grep -q '#define CONFIG_GPL 0' config.h
grep -q '#define CONFIG_POSTPROC 0' config.h
grep -q '#define CONFIG_VERSION3 1' config.h
grep -q '^CONFIG_H264_OHOSAVCODEC_ENCODER=yes' ffbuild/config.mak
grep -q '^CONFIG_H264_OHOSAVCODEC_DECODER=yes' ffbuild/config.mak
grep -q 'ff_h264_ohosavcodec_decoder' libavcodec/codec_list.c

make -j"$CORES"
make install
cd "$WORK"

echo "==== 3) Rebuild libffmpegutils.so ===="
AKI_ROOT="$ROOT/oh_modules/.ohpm/@ohos+aki@1.2.24/oh_modules/@ohos/aki"
test -d "$AKI_ROOT"
"$CMAKE" -S "$WRAP_SRC" -B "$WORK/wrapper-out" \
  -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK_NATIVE/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release \
  -DFFMPEG_ROOT="$PREFIX/ffmpeg" -DFFMPEG_SOURCE_ROOT="$FFMPEG_SRC" \
  -DTHIRD_PARTY_ROOT="$PREFIX" -DAKI_ROOT="$AKI_ROOT"
"$CMAKE" --build "$WORK/wrapper-out" -j "$CORES"
OUT_LIB="$WORK/wrapper-out/libffmpegutils.so"
"$STRIP" --strip-debug -o "$WORK/libffmpegutils-lgpl3.so" "$OUT_LIB"
strings "$WORK/libffmpegutils-lgpl3.so" > "$WORK/libffmpegutils-strings.txt"
grep -q 'libavcodec license: LGPL version 3 or later' "$WORK/libffmpegutils-strings.txt"
if grep -q -- '--enable-gpl' "$WORK/libffmpegutils-strings.txt"; then
  echo 'GPL FFmpeg configuration detected; refusing to package' >&2
  exit 1
fi

echo "==== 4) Package pinned local OHPM dependency ===="
fetch "https://ohpm.openharmony.cn/ohpm/@prq/ffmpeg-tools/-/ffmpeg-tools-2.2.6.har" \
  ffmpeg-tools-original.har
verify_sha256 4d5c7ed00ebab1a1afce55164540d9a04c61c9b36fa396a1928fab69768b9f2a ffmpeg-tools-original.har
PKG_STAGE="$(mktemp -d)"
tar xzf ffmpeg-tools-original.har -C "$PKG_STAGE"
cp "$WORK/libffmpegutils-lgpl3.so" "$PKG_STAGE/package/libs/arm64-v8a/libffmpegutils.so"
tar -czf "$PACKAGE_OUTPUT" -C "$PKG_STAGE" package
shasum -a 256 "$PACKAGE_OUTPUT"
