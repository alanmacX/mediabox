# 可复现构建与二进制替换指南

状态：**本机已完成一次带缺失编码器的重建并替换**（见下文「本轮实际产物」）。

## 为什么需要

`@prq/ffmpeg-tools` 2.2.6 原始随包二进制的 `configuration:` 串确认未编译：

- `libmp3lame` → MP3 编码
- `libvpx` → VP8/VP9 编码（WebM）
- `libwebp` → 动态 WebP 编码

MediaBox 通过运行时探测（`core/engine/FFmpegCapability.ets`）动态适配编码器可用性。
**替换二进制后，对应功能自动点亮**；探测失败时维持禁用与说明文案。

## 本轮实际产物（2026-09-12）

> 关键坑：首次重建误用 `--disable-protocols`，导致 **本地 `file` 协议缺失**，所有输入文件打不开。
> 已改为 `--disable-network` + 显式启用 `file/pipe/data/cache/crypto/subfile`。

执行脚本：`docs/reproducible-build/rebuild_ffmpeg_encoders.sh`。

| 项 | 结果 |
| --- | --- |
| 第三方库 | LAME 3.100、libvpx 1.14.1、libwebp 1.3.2（aarch64-linux-ohos 静态库） |
| FFmpeg | n6.1.2，`--enable-libmp3lame --enable-libvpx --enable-libwebp --enable-gpl` |
| 已点亮编码器 | `libmp3lame`、`libvpx_vp8/vp9`、`libwebp`、`libwebp_anim` |
| 硬件编解码 | 从原 `libavcodec.a` 注入 `ohosavcodec` 目标文件并写回 `codec_list.c`，保留 `h264_ohosavcodec` |
| 产物 | `build_ffmpeg_encoders/wrap_out/libffmpegutils.so`（strip 后约 21MB） |
| 替换位置 | `oh_modules/.ohpm/@prq+ffmpeg-tools@2.2.6/.../libs/arm64-v8a/libffmpegutils.so`（原件备份为 `.orig`） |

### 许可注意

- 本构建启用 `--enable-gpl`（因链接 `libpostproc`），**FFmpeg 整体按 GPL v2+ 分发义务处理**。
- libmp3lame：LGPL-2.1；libvpx / libwebp：BSD 系。
- 上架前必须在 `open_source_notices.md` 与 `LICENSE_AUDIT.md` 同步上述事实，并完成 LGPL/GPL 对应的源码提供与再链接义务评估。

### 未覆盖

- AVIF（libaom）体积过大，本轮未加入。
- 真机编码质量与硬件 `h264_ohosavcodec` 在注入后的行为需真机压测。

## 步骤（复现）

1. 准备 DevEco Studio OpenHarmony Native SDK。
2. 准备第三方库源码与官方 release tarball（libwebp 必须用带 `configure` 的 release 包）。
3. 运行 `rebuild_ffmpeg_encoders.sh`（需可访问 GitHub / SourceForge / ffmpeg.org）。
4. 注入 OHOS 硬件编解码目标文件并重建 wrapper（脚本后半段）。
5. 替换 `libffmpegutils.so`，安装 HAP 后进入音频/GIF 工作台验证探测点亮。

## 固化上游信息（已核对）

- FFmpeg：n6.1.2，https://git.ffmpeg.org/ffmpeg.git
- 上游 OHOS 补丁来源：https://github.com/jjjjjjava/ffmpeg_tools
- 原始 configure 串全文已存档于 `LICENSE_AUDIT.md`
