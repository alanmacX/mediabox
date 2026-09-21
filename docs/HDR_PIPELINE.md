# HDR 到 HDR 转码管线设计（Native C++）

状态：**API 24 的 ArkTS 层无可用路径，方案设计已完成，落地需要新增 Native C++ 模块**。

## 为什么 ArkTS 层做不了（已核对 API 24 SDK）

- `AVTranscoderConfig`（`@ohos.multimedia.media.d.ts`，API 24）字段仅有：
  `audioBitrate / audioCodec / fileFormat / videoBitrate / videoCodec / videoFrameWidth / videoFrameHeight / enableBFrame`。
  **没有 HDR 元数据、色彩空间、传输特性、Profile/Level、10-bit 像素格式等任何字段。**
- 官方《HDR Vivid 视频转码 SDR 视频开发实践》明确：HDR Vivid → SDR 走 AVC 输出即可
  （MediaBox 的 `hdr_to_sdr` 已实现）；HDR → HDR 需要完整色彩空间转换管线，
  官方未提供 ArkTS 入口。

## Native C++ 方案（NDK AVCodec）

新增 `entry/src/main/cpp/` 模块，用 Native AVCodec API（`native_avcodec_videoencoder.h` /
`native_avcodec_videodecoder.h`）实现：

1. **解码**：`OH_VideoDecoder_CreateByMime`（HEVC/AVC），
   `OH_VideoDecoder_SetSurface` 输出到 `OH_NativeWindow`，请求 10-bit
   `NATIVEBUFFER_PIXEL_FMT_YCBCR_P010`。
2. **HDR 元数据读取**：`OH_MediaCodec...` 输出格式变更事件中读取
   `OH_MD_KEY_VIDEO_SDR` / HDR 色彩相关键（mastering display / content light level，
   API 24 `native_avcaps.h` 提供 HDR 能力查询 `OH_AVCAPCODEC_HAS_HDR`）。
3. **色彩处理**：同参数 HDR→HDR 直接走 P010 Surface 直通（不转换色彩空间，
   保留 mastering metadata）；HDR10→HDR Vivid 需要 OOTF/ tone map 着色器，
   在 OpenGL ES / Vulkan pass 中实现，映射表参照官方 HDR Vivid 白皮书。
4. **编码**：`OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_HEVC)`，
   配置 `OH_MD_KEY_PROFILE`（Main10）+ `OH_MD_KEY_PIXEL_FORMAT`（P010），
   用 `OH_VideoEncoder_SetSurface` 或 buffer 模式回写 `OH_MD_KEY_HDR_*` 元数据。
5. **封装**：编码码流经 Native `OH_Muxer`（API 24 无 muxer NDK → 退回
   FFmpeg `hevc_mp4toannexb` + MP4 muxer，在应用沙箱内完成，无网络）。
6. **ArkTS 桥**：NAPI 导出 `hdrTranscode(srcFd, dstFd, options, progressCb, cancelCb)`，
   注册为新的 EngineKind.HDR_NATIVE，由 CapabilityRouter 在
   `media.video.hdr === true` 且 `canIUse` 探测通过时推荐。

## 验收口径（实现时不得冒充）

- 输出用 `AVMetadataExtractor` 读回 `hdrType` 必须与输入一致；
- 对比输入输出的 MaxCLL/MaxFALL（可用 `metadata_export` 的 FFmetadata 报告核对）；
- 真机验收矩阵：HDR Vivid 拍摄样片、HDR10 网络样片、SDR 对照组（必须报"不是 HDR 输入"）。

## 人力与风险

- 预估 2–3 周（NAPI 桥 + P010 直通 + 元数据回写 + 真机矩阵）；
- 风险：设备编码器对 Main10 支持参差（需 `OH_AVCAPCODEC` 运行时降级到"不支持"提示）；
  FFmpeg 封装 HEVC 10-bit MP4 与系统播放器兼容性需真机回归。
