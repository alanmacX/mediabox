# MediaBox 架构说明

> HarmonyOS 原生全功能本地媒体处理工具箱 · targetSdkVersion 6.1.1(24) · 手机 / 折叠屏 / 平板 / 2in1

## 分层

```
UI(arkts pages / ui)
 ├─ Index: Navigation + Tabs 骨架,沉浸光感背景
 ├─ HomePage:类型优先入口(自动识别 + 视频/图片/GIF/音频/字幕/动态照片)
 ├─ Workbench:文件驱动工作台,lg 双栏(预览 | 工具)
 ├─ TasksPage:任务队列(如实串行,不伪造并发)
 └─ MediaInfoPage:完整技术参数
core
 ├─ model/MediaTypes:AnalyzedMedia / ToolAction 契约
 ├─ analyze/MediaAnalyzer:AVMetadataExtractor + ImageSource(File → MediaInfo)
 ├─ engine/CapabilityRouter:MediaInfo → 推荐(Lossless First)
 ├─ engine/NativeEngine:AVTranscoder 硬件转码(Hardware First)
 ├─ engine/FfmpegEngine:@prq/ffmpeg-tools 兼容管线(Remux / GIF / 音频 / 视频滤镜)
 ├─ media/MediaPickerService:PhotoViewPicker / DocumentViewPicker(零权限)
 ├─ media/OutputShareService:Share Kit 系统分享
 ├─ task/LiveViewProgress:实况窗进度节流与降级
 └─ task/TaskQueue:串行队列 + preferences 持久化 + 媒体处理长时任务
```

## 关键设计决策

1. **最小权限**:不申请媒体库或 INTERNET 权限。图库选择走 PhotoViewPicker 安全组件,文件走 DocumentViewPicker;仅为本地媒体处理声明后台运行权限。
2. **沉浸光感 / HDS Material**:
   - UI Design Kit 的 HDS 组件自 HarmonyOS 6.1.0(23) 提供 `systemMaterialEffect`;项目在 API 24 使用 `HdsTabs`、`HdsNavigation`、`HdsNavDestination`、`HdsListItem`/`HdsListItemCard`、原生 `BottomTabBarStyle` 和系统 Symbol，并按官方悬浮页签示例明确请求 `IMMERSIVE` 材质;
   - 二级页标题栏启用 `ScrollEffectType.IMMERSIVE_GRADIENT_BLUR`;
   - `GlassCard` 和 `AppBackground` 只承担内容层次与背景色彩，不冒充系统沉浸材质;
   - 遵循官方功耗指南:材质面积可控、不嵌套、不叠加模糊、不覆盖动态内容。
3. **沉浸式窗口**:setWindowLayoutFullScreen + avoidAreaChange,`safeTopVp/safeBottomVp/windowWidthVp` 进 AppStorage,全部页面响应式消费;旋转 / 折叠 / 分屏 / 自由窗口实时生效。
4. **断点系统**:sm(<600)单栏 + 底部 Tab;md(600-840)折叠屏展开;lg(≥840)双栏工作台、内容 720 宽封顶。布局用 GridRow/GridCol,避免灾难式后期适配。
5. **双引擎路由**:CapabilityRouter 依据 AnalyzedMedia 给每个动作标记 NATIVE / FFMPEG;AVTranscoder(硬件)承担常见转码，Image Kit 承担图片处理，FFmpeg 承担 Remux / GIF / 音频与兼容操作。
6. **码率预算**:按官方 AVTranscoder 实践文档经验公式(720p/30fps/3Mbps 基准,分辨率^1.57 因子,双路径取小)。
7. **后台导出**:API 24 使用 `MODE_SPECIAL_SCENARIO_PROCESSING` + `SUBMODE_MEDIA_PROCESS_NORMAL_NOTIFICATION`，按系统授权结果启用；不再把本地转码伪装成数据传输。
8. **实况窗**:任务开始、进度、结束分别调用 `startLiveView/updateLiveView/stopLiveView`；更新间隔至少一秒，设备未开放能力或应用未获准入时无声降级为应用内队列。
9. **系统分享**:输出路径先由 `fileUri.getUriFromPath` 转换，再以准确的图片/视频/音频 UTD 交给 Share Kit；同时注册 `ohos.want.action.sendData` 接收入口。
10. **类型隔离**:首页不再直接展示跨类型动作，而是先按媒体大类选择；系统选择器过滤、返回后的内容识别和 `CapabilityRouter` 三层共同约束可见能力。扩展名缺失时由 Image Kit MIME、Media Kit 轨道及字幕文本结构自动识别。
11. **可靠队列**:批量任务各自持有独立参数副本，等待与运行状态在入队和状态变化时持久化；应用恢复后会自动继续调度未完成任务。

## FFmpeg 发布前必须完成

见 `LICENSE_AUDIT.md`:开发态已完成二进制配置与 API 24 冒烟验证；上架前仍需补齐 LGPL 静态链接合规材料、可复现构建和真机压力测试。

HarmonyOS API 的逐项核对结果见 `API_AUDIT.md`。

## 当前功能边界

- 多输入组合已支持视频兼容合并、参数一致时无损合并、替换音轨、图片序列转视频/GIF、图片与音频生成视频、音频合并、水印、字幕封装与音频封面。
- Stream / Subtitle / Chapter / Analysis 已支持逐轨提取、删除和标题/语言编辑，字幕预览/转换/封装/烧录/偏移，章节导出/移除/创建，场景抽帧、静音/黑帧检测、自动去静音、自动裁头尾黑屏与响度报告。
- GIF Lab 已支持目标体积迭代、优化、时段裁剪、画面裁剪、缩放、帧率、速度、循环、调色板质量和 MP4 输出。
- Moving Photo 支持资源导出、GIF 转换以及通过系统 SaveButton 临时授权创建动态照片。
- 当前 FFmpeg 构建没有 MP3 和动态 WebP 编码器，对应入口会如实禁用；完整 HDR 到 HDR 仍需 10-bit VideoProcessing Surface 与色彩元数据管线，因此不以普通 HEVC 转码冒充。
