# FFmpeg License Audit

状态：**本机已替换为带 libmp3lame / libvpx / libwebp 的重建二进制；发布合规结论仍待完成**。

审计对象：`@prq/ffmpeg-tools` 2.2.6 原始包 + MediaBox 本机重建产物。

## 已核对（重建后）

- FFmpeg 内核：n6.1.2（本机重建）。
- FFmpeg 自报许可：**GPL version 2 or later**（因 `--enable-gpl` / libpostproc）。
- 已启用外部编码库：
  - `libmp3lame`（LGPL-2.1）
  - `libvpx` VP8/VP9（BSD）
  - `libwebp` / `libwebp_anim`（BSD）
  - `libaom` AV1 编码（BSD-2-Clause，仅 encoder，decoder 未启用）
- 保留：从原包注入的 `h264_ohosavcodec` 硬件编解码目标文件。
- 未启用：libx264、libx265、libfdk_aac。
- 架构：arm64-v8a。
- 并发：FFTools 全局状态只能串行；MediaBox 队列强制串行。

## 原始 2.2.6 包（备份 `.orig`）备查

- FFmpeg 自报许可：LGPL 2.1 or later；`CONFIG_GPL=0`。
- 无 libmp3lame / libvpx / libwebp 编码器。

## 发布前必须补齐

- [ ] 在 `open_source_notices.md` 增加 libmp3lame / libvpx / libwebp 声明与版权。
- [ ] 按 **GPL v2+** 评估整包分发义务（本机重建启用 GPL），或改为不链接 libpostproc 的 LGPL 构建。
- [ ] 对静态链接形式落实 LGPL 可重链接要求。
- [ ] 固化源码、补丁、configure 命令与可复现构建脚本的提供地址（脚本已放在 `docs/reproducible-build/`）。
- [ ] 真机压测新二进制：MP3 / WebM / 动态 WebP / 水印硬件编码路径。

## 完整 configure 记录（本机重建）

```text
--target-os=linux --arch=aarch64 --enable-cross-compile
--disable-neon --disable-asm --disable-x86asm --disable-vulkan
--disable-network --disable-protocols
--enable-libmp3lame --enable-libvpx --enable-libwebp
--enable-static --enable-pic --disable-shared
--disable-doc --disable-htmlpages --disable-programs
--enable-gpl
```
