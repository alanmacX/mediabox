# FFmpeg 发布许可审计

状态：**GPL 构建已移除；对应源码包已通过隔离目录重建，并提供公开下载。最终法律判断仍需发布方负责。**

## 已验证的二进制事实

- MediaBox 使用 OpenHarmony FFmpeg `ohos-n6.1.2` 固定提交 `085ae3bceb7a576e7c4aff68d7be36d2145023f9`，交叉编译为 HarmonyOS arm64-v8a。
- 构建配置没有 `--enable-gpl` 或 `--enable-nonfree`，`CONFIG_GPL=0`、`CONFIG_POSTPROC=0`、`CONFIG_VERSION3=1`；最终 `libffmpegutils.so` 自报 `LGPL version 3 or later`。
- 启用 libmp3lame、libvpx、libwebp、libaom；保留本地文件协议，关闭网络功能。
- FFmpeg 库与外部编码库以静态归档链接进动态 `libffmpegutils.so`。不能因为产物是 `.so`，就把其中的 LGPL 静态链接义务当作自动解决。
- OHOS H.264 硬编解码适配从上述 FFmpeg 分支中的 `ohosavcodec*`、`ohoscodecdata.cpp` 等源码编译，不再从原始预编译包提取目标文件。适配源码头部为 Apache-2.0，因此启用 FFmpeg `--enable-version3`。仍需对最终静态链接库的重链方式做发布验收。
- ArkTS / NAPI 包装层来自上游 MIT 项目 `ffmpeg_tools` 2.2.6，构建脚本固定提交 `0680a973c0452137718fa22dcd09c2f158f7e1af`。

## 第三方库

| 组件 | 版本 | 许可 | 用途 |
| --- | --- | --- | --- |
| OpenHarmony FFmpeg | ohos-n6.1.2 | LGPL-3.0-or-later；OHOS 适配源码 Apache-2.0 | 媒体处理 |
| LAME | 3.100 | LGPL-2.1-or-later | MP3 编码 |
| libvpx | 1.14.1 | BSD-3-Clause | VP8/VP9 编码 |
| libwebp | 1.3.2 | BSD-3-Clause | WebP 编码 |
| libaom | 3.8.0 | BSD-2-Clause | AV1 编码 |
| @prq/ffmpeg-tools 封装 | 2.2.6 | MIT | ArkTS / NAPI 桥接 |

## 发布闭环

- [x] 提供与发布 `.so` 对应的 FFmpeg、LAME、libvpx、libwebp、libaom 源码、构建参数和重链说明；应用内开源声明包含公开下载地址。
- [x] 从打包后的源码材料在隔离工作目录重建 `.har`，重建产物通过 LGPLv3、自带编码器及无 GPL 配置检查。
- [x] 正式 `.app` 内的 `.so` 已复核许可证与配置；同一原生库在真机实际初始化 H.264、MP3、VP8、动态 WebP、AV1 编码器，五项均成功。
- [ ] 上架候选包经 AGC 内测安装后，补跑完整用户媒体样本及实况窗外显验收（Release 包受系统可信来源限制，不能用 HDC 直接侧载）。
- [ ] 对最终分发方案进行许可复核；本文件是工程审计，不替代法律意见。

构建与打包：`docs/reproducible-build/rebuild_ffmpeg_encoders.sh`；分发说明：`entry/src/main/resources/rawfile/open_source_notices.md`。
