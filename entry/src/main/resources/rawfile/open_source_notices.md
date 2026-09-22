# 开源软件声明

MediaBox媒体工具箱在本机处理媒体文件时使用了以下第三方开源软件。本应用按相应许可要求提供本声明。

## FFmpeg（本机重建）

- 版本：OpenHarmony FFmpeg `ohos-n6.1.2`，提交 `085ae3bceb7a576e7c4aff68d7be36d2145023f9`（本机交叉编译）
- 许可证：**LGPL-3.0-or-later**（OHOS 硬件编解码适配源码为 Apache-2.0；未启用 GPL / nonfree 组件，也未链接 libpostproc）
- 源代码获取：https://gitee.com/openharmony-tpc-incubate/FFmpeg/tree/ohos-n6.1.2
- 本应用对应源码与重建材料：https://github.com/alanmacX/mediabox/releases/download/ffmpeg-source-1.0.0/MediaBox-FFmpeg-source-and-relink.tar.gz
- 构建配置要点：`--enable-version3 --enable-ohosavcodecdecoder --enable-ohosavcodecencoder --enable-libmp3lame --enable-libvpx --enable-libwebp --enable-libaom --disable-network --enable-static --enable-pic --target-os=linux --arch=aarch64`
- 用途：本地 Remux、GIF、音频转换、滤镜与兼容容器处理。本应用不声明网络权限，不提供 URL/RTSP/HLS 入口。
- 构建脚本和本地修改见项目仓库 `docs/reproducible-build/`；上述材料包含与本应用二进制对应的源码、修改及重链说明。

## LAME (libmp3lame)

- 版本：3.100
- 许可证：LGPL-2.1-or-later
- 源代码获取：https://lame.sourceforge.io/
- 用途：MP3 编码。

## libvpx

- 版本：1.14.1
- 许可证：BSD-3-Clause
- 源代码获取：https://github.com/webmproject/libvpx
- 用途：VP8/VP9 编码（WebM）。

## libwebp

- 版本：1.3.2
- 许可证：BSD-3-Clause
- 源代码获取：https://github.com/webmproject/libwebp
- 用途：静态/动态 WebP 编码。

## libaom

- 版本：3.8.0
- 许可证：BSD-2-Clause
- 源代码获取：https://aomedia.googlesource.com/aom/
- 用途：AV1 编码。

## @prq/ffmpeg-tools

- 版本：2.2.6
- 上游仓库：https://github.com/jjjjjjava/ffmpeg_tools
- 许可证：MIT（ArkTS / NAPI 封装）；其中 FFmpeg 本体按上文许可证单独处理。
- 用途：FFmpeg 命令构建与管理器的 ArkTS 封装（二进制已按上文重建替换）。

## 关于 OpenSSL / librtmp

本机重建产物**未**启用 OpenSSL 与 librtmp；应用亦不提供网络输入入口。

以上内容随应用分发。完整许可文本请访问各项目官方网站或源代码仓库。
