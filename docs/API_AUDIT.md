# HarmonyOS API 核对记录

核对日期：2026-09-05  
工程目标：HarmonyOS 6.1.1，API 24

本记录只采用华为 HarmonyOS 官方开发者文档与本机 DevEco Studio 6.1 SDK 类型声明作为依据。

## 已核对

| 能力 | 官方约束 | 工程处理 |
| --- | --- | --- |
| `AVMetadataExtractor` | `fdSrc` 需要真实字节长度；`fetchMetadata()` 从 API 11 提供；缩略图 API 为 `fetchFrameByTime()`，从 API 20 提供；用完调用 `release()` | 使用 `fileIo.statSync(fd).size`；改用 `fetchFrameByTime()`；`finally` 中释放 extractor 与 fd |
| `AVTranscoder` | 使用前通过 `canIUse("SystemCapability.Multimedia.Media.AVTranscoder")` 判断；顺序为创建、监听、设置 fd、`prepare()`、`start()`；完成或错误后释放 | 路由和执行器均检查 SysCap；`error` 会拒绝任务 Promise；完成后先 `release()` 再关闭 fd 和返回输出 |
| 转码分辨率 | API 24 `AVTranscoderConfig` 声明目标宽度范围 240–3840、目标高度范围 240–2160；设备编码器还可能有更严格的对齐与组合限制 | `native1080pDimensions()` 与 `nativeMaximumDimensions()` 保持比例、不放大、输出偶数尺寸并限制在声明范围内；`prepare()` 不支持时任务会明确失败而不伪装成功 |
| 转码编码与码率 | API 24 的 `AVTranscoderConfig` 仅开放 AVC/HEVC 视频与 AAC 音频；音频码率范围 1–500000 bit/s；`enableBFrame` 从 API 20 提供 | 兼容性预设固定 AVC/AAC；音频使用 128 kbps；“平衡”和“更小文件”在 API 24 打开 B 帧编码 |
| `DocumentViewPicker` | `select()` 的 Promise 结果是 `Array<string>` | 直接遍历返回的 URI 数组，不再读取不存在的 `fileUris` |
| 分类媒体选择 | API 24 `DocumentSelectOptions.fileSuffixFilters` 支持按“描述|后缀列表”限制文件；`PhotoSelectOptions.MIMEType` 可区分图片、视频、图片与视频、动态照片 | 首页按视频、图片、GIF、音频、字幕、动态照片分组；选择器先过滤，返回后再做实际类型校验，不向错误类型暴露操作 |
| 内容类型识别 | API 24 `ImageInfo.mimeType` 可返回图片 MIME；`AVMetadata.tracks` 与 `MD_KEY_TRACK_TYPE` 可区分视频/音频轨 | 扩展名缺失或不可靠时，先尝试 Image Kit，再用 `AVMetadataExtractor` 读取轨道，最后检查字幕时间轴标记；自动入口不再只依赖文件后缀 |
| 图片重编码 | `ImageSource.createPixelMap()` 解码；可编辑 PixelMap 的 `crop/rotate/flip` 自 API 9 提供；`ImagePacker.packToFile()` 写入目标 fd | 图片转换、压缩、等比缩放、居中裁剪、90 度旋转、水平翻转与清除元数据均走 Image Kit |
| Share Kit 输出 | `SharedData` 的文件记录需包含 UTD 与 URI；沙箱路径先由 `fileUri.getUriFromPath()` 转换；`ShareController.show()` 需要 UIAbilityContext | 任务完成卡片用准确媒体 UTD 拉起系统分享面板 |
| Share Kit 输入 | Ability 注册 `ohos.want.action.sendData` 和明确的 UTD；从 `onCreate/onNewWant` 调用 `getSharedData(want)` | 注册 image/video/audio，接收单文件后直接进入工作台，不申请媒体库权限 |
| 长时任务 | API 24 媒体导出使用 `ContinuousTaskRequest`，模式为 `MODE_SPECIAL_SCENARIO_PROCESSING`，子模式为 `SUBMODE_MEDIA_PROCESS_NORMAL_NOTIFICATION`；需检查并按需请求用户授权 | 声明两项后台权限和 `specialScenarioProcessing`，任务开始时检查授权，获准后启动，队列空闲立即释放 |
| 实况窗 | `startLiveView/updateLiveView/stopLiveView`；更新太快会触发 1003500008；模拟器不支持且应用需要场景准入 | 进度桥接至少间隔一秒更新；设备或权益不可用时降级为应用内任务队列 |
| 自适应窗口 | `WindowProperties` 不含屏幕密度；密度来自 `display.Display.densityPixels` | 使用 `display.getDefaultDisplaySync().densityPixels` 换算 vp |
| 沉浸光感 | UI Design Kit 的 HDS `HdsTabsFloatingStyle.systemMaterialEffect` 与 `barFloatingStyle()` 均从 6.1.0(23) 提供，包含 `MaterialType.IMMERSIVE`；官方 HdsTabs 悬浮示例同时设置 `barOverlap=true`、`vertical=false`、`barPosition=End`、宽度档位、底部间距和渐变遮罩 | API 24 使用 `HdsTabs`、原生 `BottomTabBarStyle` 和系统 Symbol；按官方示例明确请求 `IMMERSIVE + ADAPTIVE` 材质等级，并使用 200/300/400vp 宽度档位、28vp 底距与 92vp 渐变遮罩。模拟器返回空支持列表不再触发主动降级；真机材质效果仍以设备渲染为准 |
| HDS 列表 / 导航目的地 | 本机 HMS SDK `@kit.UIDesignKit` 提供 `HdsListItem`/`HdsListItemCard`（6.0.0(20)）、`HdsNavDestination.titleBar` 与 `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR`（6.1.0(23)）；`PrefixIcon`/`SuffixArrow` 等构造器接收 options 对象 | 首页最近任务使用 `HdsListItem + HdsListItemCard`；工作台推荐/任务/媒体信息分组用 `HdsListItem.customItemBuilder`；二级页由 Index 统一包 `HdsNavDestination` 并启用沉浸渐变模糊标题栏 |
| 动态照片能力门控 | `PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE` API 12+；`MediaAssetManager.requestMovingPhoto` API 18+ 且标注可能 801；`PhotoSubtype.MOVING_PHOTO` + `MediaAssetChangeRequest` API 12+；选择器徽章 API 22+ | 新增 `DeviceSupport`：无能力时隐藏首页动态照片入口、禁用导出/创建动作并给出原因；选择结果只信徽章，不再因入口模式强制 `isMovingPhoto`；导出前校验接口与输出文件 |
| 图片编码格式 | `getImagePackerSupportedFormats()` 返回设备可编码 MIME 集合 | WebP/PNG/HEIF/JPEG 动作按运行时集合启用；AVIF 仍如实禁用（随包 FFmpeg 无 AV1） |
| HDR Vivid 转 SDR | 官方实践明确以 AVTranscoder 的 H.264/AVC 目标编码触发 HDR Vivid 到 SDR；其他 HDR 类型需先转为 HDR Vivid 或走完整色彩空间转换管线 | 分析为 HDR 时提供原生 SDR 兼容版；输出编码明确设为 AVC；非 HDR Vivid 输入仍以设备 `prepare()` 的真实结果为准 |
| 图片输出格式 | API 20 起 `getImagePackerSupportedFormats()` 返回当前设备可编码 MIME 集合 | WebP、PNG、HEIF 动作按当前设备返回值动态启用，避免展示实际不可执行的格式 |
| 动态照片创建 | `MediaAssetChangeRequest.createAssetRequest()`、`PhotoSubtype.MOVING_PHOTO` 与双资源 `addResource()` 自 API 12 前已可用；第三方应用应从 `SaveButton` 获取临时写入授权 | 图片先经 Image Kit 标准化为 JPEG，MP4 复制到沙箱后写入图片与视频资源；完成或失败都会清理临时文件，不申请受限的全局图库写权限 |
| 音频封面 | 当前 FFmpeg 动态库包含 MJPEG 编码器及 `attached_pic` 支持 | M4A、MP3、FLAC 与图片组合时提供写入封面操作；音频流直接复制，图片编码为 MJPEG 并标记为封面流 |
| 图片透明通道转 JPEG | API 24 `DecodingOptions.desiredPixelFormat` 可请求 `RGBA_8888`；`ImageInfo.alphaType` 区分 `OPAQUE/PREMUL/UNPREMUL`；PixelMap 提供 `readPixelsToBuffer/writeBufferToPixels` | JPEG 输出前按 Alpha 类型与用户填写的 `#RRGGBB` 背景做像素合成，默认白色，不把透明像素交给编码器隐式决定 |
| 视频/音频兼容格式 | 随包 FFmpeg arm64 动态库实际包含 `m4v/mp4/ogg` muxer 与 AAC、Vorbis、Opus、FLAC、MPEG-4 Video 编码器；不包含 MP3 编码器 | 开放 M4V、OGG/Vorbis、Opus、FLAC；MP3 保持禁用。视频默认优先系统 H.264 编码器，特殊兼容容器按其可用编码器处理 |
| 无损多文件合并 | FFmpeg concat demuxer 只有在各段流参数兼容时才能安全 stream copy | 入队前逐文件比较视频编码、分辨率、帧率及音频编码、采样率、声道；全部一致才生成 concat 清单并 `-c copy`，否则提示改用兼容重编码合并 |
| 媒体轨道元数据 | FFmpeg stream metadata specifier 可单独写入输出轨道的 `title` 与 `language`，无需重新编码 | 每条视频、音频和字幕轨提供独立标题/语言配置，复制所有媒体流后只修改对应轨道标签 |
| 队列恢复 | preferences 可持久化应用结构化状态；恢复后的等待任务必须重新调度，任务参数不应在批量任务间共享可变引用 | 入队即保存等待/运行状态，启动时恢复并重新调度；每个任务深拷贝参数并使用进程内序列号避免同毫秒 ID 冲突 |

## 官方文档

- [AVMetadataExtractor API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avmetadataextractor)
- [AVTranscoder API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-media-avtranscoder)
- [使用 AVTranscoder 实现视频转码（ArkTS）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/using-avtranscoder-for-transcodering)
- [Media Kit 简介：AVTranscoder 支持格式与约束](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/media-kit-intro#avtranscoder)
- [UI Design Kit HDS 材质组件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material)
- [HdsTabs API 与页签栏悬浮样式示例](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdstabs#页签栏悬浮样式)
- [组件适配沉浸光感](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-component-adaptation)
- [文件选择器 Picker](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/file-picker)
- [ImageSource 图片解码](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/image-decoding)
- [获取支持的编解码能力](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/obtain-supported-codecs)
- [应用内处理分享内容](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/share-interface-description)
- [分享文本（含 ShareController 官方调用流程）](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/share-utd-text)
- [基于长时任务与实况窗的视频后台导出方案](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-video-background-export)
- [访问和管理动态照片资源](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/photoaccesshelper-movingphoto)
- [HDR Vivid 视频转码 SDR 视频开发实践](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdr-vivid-transcoding-sdr)

## 待继续核对

- 图片编码器的透明通道、色彩空间与 HDR 保留策略
- 音频转码应使用的原生 API 及各目标容器能力
- HDR10/HLG 到 HDR Vivid 的完整 Native C++ 色彩空间转换链路
