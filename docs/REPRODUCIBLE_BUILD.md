# FFmpeg 原生库构建与打包

`@prq/ffmpeg-tools` 2.2.6 原始包缺少 MediaBox 需要的 MP3、WebM、WebP 编码器，且启用了 GPL。项目使用带 OHOS H.264 硬件编解码源码的 FFmpeg `ohos-n6.1.2`，启用 LAME 3.100、libvpx 1.14.1、libwebp 1.3.2、libaom 3.8.0。Apache-2.0 适配源码要求 FFmpeg 使用 LGPLv3+，并关闭 GPL、nonfree、postproc 和网络功能。

## 本机构建

依赖：DevEco Studio OpenHarmony Native SDK、`pkg-config`/`pkgconf`、Git、curl、make、CMake。macOS 可安装 `brew install pkgconf`。在仓库根目录运行：

```sh
OHOS_SDK_NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native \
  bash docs/reproducible-build/rebuild_ffmpeg_encoders.sh
cd entry && /Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
```

脚本固定 OpenHarmony FFmpeg 提交 `085ae3bceb7a576e7c4aff68d7be36d2145023f9` 和上游包装层提交 `0680a973c0452137718fa22dcd09c2f158f7e1af`，从源码构建 FFmpeg、OHOS 编解码适配和外部编码库，重链 `libffmpegutils.so`，再封装进 `vendor/ffmpeg-tools-lgpl3-2.2.6.har`。应用的 `entry/oh-package.json5` 指向这个本地包，因此重新安装依赖不会回退到官方预编译 `.so`。

构建结束后，检查 `build_ffmpeg_encoders/openharmony_ffmpeg_6/config.h` 中 `CONFIG_GPL=0`、`CONFIG_POSTPROC=0`、`CONFIG_VERSION3=1`，并用 `strings` 检查最终 `.so` 自报许可证。构建 HAP 后，还应检查 **HAP 内** 的 `libs/arm64-v8a/libffmpegutils.so`，不能只检查工作目录中的库。

`bash docs/reproducible-build/package_source_offer.sh` 可在本机生成源码与重链材料包 `build_ffmpeg_encoders/MediaBox-FFmpeg-source-and-relink.tar.gz`。1.0.0 版公开下载地址为 [FFmpeg source offer](https://github.com/alanmacX/mediabox/releases/download/ffmpeg-source-1.0.0/MediaBox-FFmpeg-source-and-relink.tar.gz)。发布时需核对下载链接和哈希；本地生成的文件不会自动随 `.app` 上传。

## 验证状态

源码材料已经在隔离工作目录按其中说明成功重建为 `.har`。这证明工程重建路径可用，但不替代发布方对 LGPL 静态链接安排和最终分发方案的法律复核，详见 [`LICENSE_AUDIT.md`](LICENSE_AUDIT.md)。
