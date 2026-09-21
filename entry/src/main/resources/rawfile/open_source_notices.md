# 开源软件声明

MediaBox媒体工具箱在本机处理媒体文件时使用了以下第三方开源软件。本应用按相应许可要求提供本声明。

## FFmpeg（本机重建）

- 版本：n6.1.2（本机交叉编译，保留 OHOS 硬件编解码目标文件）
- 许可证：**GPL-2.0-or-later**（构建启用 `--enable-gpl` 与 libpostproc）
- 源代码获取：https://git.ffmpeg.org/ffmpeg.git
- 构建配置要点：`--enable-libmp3lame --enable-libvpx --enable-libwebp --enable-gpl --disable-network --disable-protocols --enable-static --enable-pic --target-os=linux --arch=aarch64`
- 用途：本地 Remux、GIF、音频转换、滤镜与兼容容器处理。本应用不声明网络权限，不提供 URL/RTSP/HLS 入口。
- 源码提供：构建脚本见应用仓库 `docs/reproducible-build/rebuild_ffmpeg_encoders.sh`；如需对应源码包，请通过应用内「开源许可」或项目仓库获取说明。

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

## @prq/ffmpeg-tools

- 版本：2.2.6
- 上游仓库：https://github.com/jjjjjjava/ffmpeg_tools
- 用途：FFmpeg 命令构建与管理器的 ArkTS 封装（二进制已按上文重建替换）。

## 关于 OpenSSL / librtmp

本机重建产物**未**启用 OpenSSL 与 librtmp；应用亦不提供网络输入入口。

以上内容随应用分发。完整许可文本请访问各项目官方网站或源代码仓库。
