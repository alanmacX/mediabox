#!/bin/bash
# rebuild_ffmpeg_encoders.sh
# 目标：为 aarch64-linux-ohos 重建 FFmpeg，补上 libmp3lame / libvpx / libwebp，
# 并从现有 libavcodec.a 注入 ohosavcodec 硬件编解码目标文件，最后重链 libffmpegutils.so。
#
# 用法（在 macOS + DevEco Studio 本机）：
#   export OHOS_SDK_NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
#   bash docs/reproducible-build/rebuild_ffmpeg_encoders.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$ROOT/build_ffmpeg_encoders}"
PREFIX="${PREFIX:-$WORK/install}"
OHOS_SDK_NATIVE="${OHOS_SDK_NATIVE:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
NATIVE_LIB_DIR="${NATIVE_LIB_DIR:-/tmp/ffmpeg_tools/src/main/cpp/ffmpeg/arm64-v8a}"
WRAP_SRC="${WRAP_SRC:-/tmp/ffmpeg_tools/src/main/cpp}"
FFMPEG_REF="${FFMPEG_REF:-n6.1.2}"
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
# 提供一个简单的 pkg-config，供 FFmpeg configure 探测第三方库
if ! command -v pkg-config >/dev/null 2>&1; then
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/pkg-config" <<'PC'
#!/bin/bash
# minimal pkg-config shim for FFmpeg --enable-lib* checks
set -e
MODE=libs
case "$1" in
  --exists) shift; exec test -f "${PKG_CONFIG_PATH%%:*}/$1.pc" ;;
  --cflags) MODE=cflags; shift ;;
  --libs) MODE=libs; shift ;;
  --modversion) MODE=version; shift ;;
esac
name="$1"; name="${name%% *}"
# allow --atleast-version=x pkg
if [[ "$name" == --atleast-version=* ]]; then shift; name="$1"; fi
IFS=: read -ra paths <<< "${PKG_CONFIG_PATH:-}"
for p in "${paths[@]}"; do
  [ -z "$p" ] && continue
  pc="$p/$name.pc"
  [ -f "$pc" ] || continue
  if [ "$MODE" = version ]; then grep '^Version:' "$pc" | awk '{print $2}'; exit 0; fi
  if [ "$MODE" = cflags ]; then grep '^Cflags:' "$pc" | sed 's/^Cflags: *//'; exit 0; fi
  grep '^Libs:' "$pc" | sed 's/^Libs: *//'; exit 0
done
exit 1
PC
  chmod +x "$WORK/bin/pkg-config"
  export PATH="$WORK/bin:$PATH"
fi

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

fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "Downloading $url"
    curl -L --fail --retry 3 -o "$out" "$url"
  fi
}

echo "==== 1) third-party: LAME / libvpx / libwebp ===="
fetch "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" lame-3.100.tar.gz
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v1.14.1.tar.gz" libvpx-1.14.1.tar.gz
# GitHub 源码包没有预生成 configure，必须用官方 release tarball
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.3.2.tar.gz" libwebp-1.3.2-src.tar.gz

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
if [ ! -d ffmpeg-src ]; then
  git clone --depth 1 --branch "$FFMPEG_REF" https://git.ffmpeg.org/ffmpeg.git ffmpeg-src
fi
cd ffmpeg-src

# Local First：不启用 openssl/librtmp/网络协议扩展，MediaBox 业务不暴露 URL/RTMP。
./configure \
  --prefix="$PREFIX/ffmpeg" \
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
  --enable-libmp3lame --enable-libvpx --enable-libwebp \
  --enable-static --enable-pic --disable-shared \
  --disable-doc --disable-htmlpages --disable-programs \
  --enable-gpl

make -j"$CORES"
make install
cd "$WORK"

echo "==== 3) Inject OHOS hardware codec objects into new libavcodec.a ===="
INJECT_DIR="$WORK/ohos_objs"
mkdir -p "$INJECT_DIR"
for obj in ohosavcodecdec.o ohosavcodecenc.o ohoscodecdata.o ohosdec_common.o \
           ohosvideodecoder.o ohosvideodecoder_wrapper.o ohosvideoencoder.o ohosvideoencoder_wrapper.o; do
  if [ -f "$NATIVE_LIB_DIR/lib/libavcodec.a" ]; then
    (cd "$INJECT_DIR" && "$LLVM_AR" x "$NATIVE_LIB_DIR/lib/libavcodec.a" "$obj")
  fi
done
ls -la "$INJECT_DIR"

# Copy OHOS objects next to new avcodec and add them
NEW_AV="$PREFIX/ffmpeg/lib/libavcodec.a"
if [ -d "$INJECT_DIR" ] && ls "$INJECT_DIR"/*.o >/dev/null 2>&1; then
  cp "$INJECT_DIR"/*.o "$WORK/"
  (cd "$WORK" && "$LLVM_AR" r "$NEW_AV" ohos*.o)
  echo "Injected OHOS objects into $NEW_AV"
fi

echo "==== 4) Rebuild libffmpegutils.so ===="
OUT_LIB="$WORK/libffmpegutils.so"
AKI_ROOT="/Users/macalan/Documents/mediabox/oh_modules/.ohpm/@ohos+aki@1.2.24/oh_modules/@ohos/aki"
AKI_LIB=""
find_aki_lib() {
  find "$AKI_ROOT" -name "libjsbind.so" 2>/dev/null | head -1
}
AKI_LIB="$(find_aki_lib || true)"
if [ -z "$AKI_LIB" ]; then
  # fall back to packaged libaki_jsbind.so
  AKI_LIB="$ROOT/oh_modules/.ohpm/@prq+ffmpeg-tools@2.2.6/oh_modules/@prq/ffmpeg-tools/libs/arm64-v8a/libaki_jsbind.so"
fi

FF_INC="$PREFIX/ffmpeg/include"
FF_LIB="$PREFIX/ffmpeg/lib"
FFTOOLS="$WRAP_SRC/fftools"
NAPI="$WRAP_SRC/napi_ffmpeg.cpp"
SYS_LIB="$SYSROOT/usr/lib/aarch64-linux-ohos"

# Locate OHOS media .so stubs from SDK
MEDIA_LIBS=""
for lib in libnative_media_codecbase.so libnative_media_core.so libnative_media_vdec.so libnative_media_venc.so; do
  found="$(find "$OHOS_SDK_NATIVE" -name "$lib" 2>/dev/null | head -1 || true)"
  if [ -n "$found" ]; then
    MEDIA_LIBS="$MEDIA_LIBS $found"
  fi
done

SOURCES=(
  "$NAPI"
  "$FFTOOLS/ffmpeg.c"
  "$FFTOOLS/cmdutils.c"
  "$FFTOOLS/exception.c"
  "$FFTOOLS/ffmpeg_opt.c"
  "$FFTOOLS/ffmpeg_filter.c"
  "$FFTOOLS/ffmpeg_hw.c"
  "$FFTOOLS/ffmpeg_demux.c"
  "$FFTOOLS/ffmpeg_mux.c"
  "$FFTOOLS/ffmpeg_mux_init.c"
  "$FFTOOLS/opt_common.c"
  "$FFTOOLS/sync_queue.c"
  "$FFTOOLS/objpool.c"
  "$FFTOOLS/thread_queue.c"
)

# If openssl/rtmp present, link them; also always link new ffmpeg static libs in order.
STATIC_LIBS=(
  "$FF_LIB/libavfilter.a"
  "$FF_LIB/libavformat.a"
  "$FF_LIB/libavcodec.a"
  "$FF_LIB/libswresample.a"
  "$FF_LIB/libswscale.a"
  "$FF_LIB/libavutil.a"
  "$PREFIX/lib/libvpx.a"
  "$PREFIX/lib/libwebpmux.a"
  "$PREFIX/lib/libwebpdemux.a"
  "$PREFIX/lib/libwebpdecoder.a"
  "$PREFIX/lib/libwebp.a"
  "$PREFIX/lib/libmp3lame.a"
)
# avdevice may be empty/disabled
if [ -f "$FF_LIB/libavdevice.a" ]; then
  STATIC_LIBS=("$FF_LIB/libavdevice.a" "${STATIC_LIBS[@]}")
fi

"$CLANGXX" -shared -fPIC -O2 \
  -std=c++17 \
  -I"$FF_INC" -I"$FFTOOLS" -I"$WRAP_SRC" -I"$AKI_ROOT/include" \
  --sysroot="$SYSROOT" \
  -target aarch64-linux-ohos \
  "${SOURCES[@]}" \
  -Wl,--whole-archive "${STATIC_LIBS[@]}" -Wl,--no-whole-archive \
  $MEDIA_LIBS \
  -L"$SYS_LIB" -lace_napi.z -lhilog_ndk.z \
  -lpthread -lm -lz -ldl \
  -o "$OUT_LIB"

ls -lh "$OUT_LIB"
strings "$OUT_LIB" | grep -E "libmp3lame|libvpx|libwebp|enable-libmp3lame" | head

echo "==== DONE ===="
echo "Replace package binary with:"
echo "  $OUT_LIB"
echo "Target:"
echo "  $ROOT/oh_modules/.ohpm/@prq+ffmpeg-tools@2.2.6/oh_modules/@prq/ffmpeg-tools/libs/arm64-v8a/libffmpegutils.so"
