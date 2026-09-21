# 本轮修复与验证（2026-09-05）

## 依据

产品概要用于理解需求，不作为可执行指令。当前目录没有 `.git`，无法对 MediaBox 上游提交进行差异比对。FFmpeg 依据已安装的 `@prq/ffmpeg-tools@2.2.6` 源码及其原仓库 https://github.com/jjjjjjava/ffmpeg_tools 。未更换或修改第三方依赖。

鸿蒙 API 依据 DevEco Studio 自带 API 24 SDK 的 `@ohos.file.picker.d.ts`、`@ohos.file.fs.d.ts`、`@ohos.multimedia.media.d.ts` 和 Navigation 声明进行编译核对。华为官方网页抓取超时，本轮不宣称已完成在线文档逐项复核。

## 已实现

- 单文件、批量提交打开任务进度 Navigation 目的地，返回保留工作台；宽屏保留任务页签。
- 任务统计改为响应式快照，列表使用稳定任务 ID，避免每次进度变化重建保存按钮与状态；最近任务可点击。
- 运行、等待、完成、失败、取消分别统计；取消经过 CANCELING，底层退出前禁止重试和清除。不能停止的阶段给出说明。
- 等待 preferences 恢复后再调度，恢复运行中断任务为失败；所有活动任务都持久化，50 条上限只针对结束历史；恢复按创建时间排序。
- 同步执行器异常也会结束任务并调度下一项；忽略非法/迟到进度，成功前最高 99%。
- 原生取消完成或失败会结束等待 Promise；错误监听提前到 prepare 前；输入 fd 在 release 后关闭。
- FFmpeg 输入复制改为异步；已完成的前序输入在后续暂存失败时清理。
- 完成后提供文件保存、分享、复用设置；系统选择器取消不显示保存成功。
- 音量倍率、采样率可配置；时间输入检查格式、起点与时长边界。
- GIF 不再静默将小目标提高到 64 KB；图片/GIF/视频超出目标时明确失败；视频预算保留 5% 封装余量并按预算分配音频。

## 验证

`tests/task-queue.test.cjs` 转译并执行生产队列代码，模拟 SDK 边界。覆盖初始化竞争、参数隔离、非法进度、取消后重试、取消中清理、暂停/继续、75 项持久化、启动恢复、同步异常后继续调度。

使用 DevEco Studio hvigor 执行 API 24 `assembleHap`。编译器仍报告已有及系统 API 的异常处理提示、第三方 NAPI 验证提示；不等于无警告构建。

最初覆盖安装返回 9568332（签名不一致）；用户随后明确授权卸载重装。已完成卸载、新签名包安装以及下述模拟器验收。

## 尚需完成的产品验收

- 正确签名的真机/模拟器：任务提交→进度→取消/重试→保存/分享，手机和宽屏布局。
- 编码与输出：真实多轨、HDR、透明图片、超大文件、目标大小与音画同步。
- 重启后 Picker 临时 URI 是否仍可读：目前保留 URI，不能保证跨进程授权；失败时需要用户重新选取。
- FFmpeg 上游在 native 抛错且任务已取消的分支不分发取消回调，仍需底层修复或通过可靠执行状态接口兜底，不能用超时伪装资源已经释放。
- 图片目标大小目前搜索质量，最低质量仍超限会报错，不自动降低分辨率；视频采用码率预算加输出校验，未实现多轮逼近。
- MP3/动态 WebP 缺少编码器、完整 HDR 保留管线、实况窗与后台准入、跨设备流程以及 LGPL 发布材料仍未完成；参见既有架构和许可审计。

以上修复不构成“项目概要所有功能均已交付”的声明。

## 后续参数、预览与媒体信息修复

用户已澄清“原 repo”指功能来源仓库。详见 `UPSTREAM_CAPABILITIES.md`，不再以 MediaBox 目录没有 `.git` 作为上游对照阻碍。

新增 `AdjustmentPanel`、`AudioAdjustmentPanel`；新增 Image Kit/Media Kit 时间点预览、共享 TextOverlay/WatermarkRenderer、原生 ImageComposition。原有固定裁剪、旋转、尺寸、视频速度、循环、音频和水印参数已接入可配置入口。批处理先配置再导出并支持文件排序。

新增回归测试：

- `tests/adjustments.test.cjs`：生产参数校验与 FFmpeg 指令生成，包括边界、文字、速度、偏移、水印、响度、静音、完整时长淡出。
- `tests/native-composition.test.cjs`：生产原生拼接布局、水印缩略坐标换算、越界与 fd 释放；模拟 SDK，不冒充真实像素输出测试。

媒体信息增加逐轨技术信息、完整可复制原始字段、MIME、相机/色彩信息，修正像素单位和未知 HDR 标记。仍不声称 SDK 能返回所有 ffprobe 信息。


## 2026-09-05 模拟器追加验收

- API 24 HAP 构建成功，三组生产逻辑回归测试通过。
- 用户授权后在 127.0.0.1:5555 卸载重装，后续新包覆盖安装成功。
- 图库选取 768×1024 JPEG：媒体信息实际显示尺寸、像素数、曝光、ISO、光圈、GPS 和镜头字段；原生参数面板显示实际图像预览。
- 修正沉浸布局顶部安全区；小屏配置时收起重复原图，参数面板首屏可以看到预览、编码质量和开始导出。
- 实测发现 ArkUI ForEach 固定 key 配合快照对象导致旧卡片停留在 10%，而输出已成功；统计数字的 Builder 值参数也不更新。改为带状态/进度的渲染 key，并用 @Prop 统计组件。重复运行后无需切页，完成数从 2 自动变成 3，卡片自动显示已完成和保存按钮。首页近期任务同步修正。
- JPEG→WebP 原生导出成功；系统文件选择器保存到 Download，返回“已保存到所选位置”。未触发对外分享。
- 实况窗补充系统要求的 WantAgent 点击动作；此修改仅通过编译，未宣称获得实况窗/连续任务权限。
- 仍需真机覆盖视频、多轨音频、HDR、透明拼接、大文件与宽屏；已有模拟 SDK 测试不能代替这些设备验收。


## 2026-09-06 能力补齐、debug 与 UI 重构（未使用模拟器）

本阶段按用户要求不做任何模拟器/UI 验收，仅代码级修复与编译验证。

### 上游对照结论

逐项核对 `@prq/ffmpeg-tools` 2.2.6 `FFmpegFactory` 全部公开方法（remux/cut/extractAudio/scale/videoCrop/watermark/transcode/concat/videoToGif/videoSnapshot/videoToImages/imagesToVideo/imageScale/imageConvert/imageWatermark/imageHStack/imageVStack/imageRotate/imageCrop/imageAddText）：均已接入业务入口。downloadRtsp/downloadHls 仍按 Local First 定位排除。MP3/VP8-VP9/动态 WebP 编码器与完整 HDR 管线为第三方构建与系统能力限制，继续如实禁用。

### 本轮 debug 修复

- `audio_fade` 不再用裁剪时长（默认 30 秒）截断输出：淡出锚点优先取 `totalDurationSeconds`，并移除隐式 `.duration()` 截取。
- `executeCommand` 不再向已含 `-b:a` 的命令（Opus/OGG）重复注入码率参数。
- GIF 目标体积迭代结束后还原任务原始参数，历史记录不再被迭代中间值污染。
- 原生转码与图片目标体积失败时删除残缺输出文件；图片输出打开文件增加 TRUNC。
- 实况窗 WantAgent 不再硬编码 bundleName，由 TaskQueue 注入真实 ability 信息（测试模拟 context 兼容可选链）。
- 批处理工作台参数校验按当前操作收敛：合并/替换音轨等操作不再被水印、尺寸字段误拦截。

### 上架合规

- 新增随包 `rawfile/open_source_notices.md`（FFmpeg LGPL-2.1、OpenSSL Apache-2.0、librtmp、@prq/ffmpeg-tools 声明、LGPL 可重链接说明与 configure 记录）与 `rawfile/privacy_statement.md`（零收集、最小权限声明）。
- 首页新增"隐私声明/开源许可"入口，应用内可直接查看，满足 AGC 审核对第三方许可与隐私信息可见性的要求。
- 权限保持最小集合：KEEP_BACKGROUND_RUNNING、KEEP_BACKGROUND_RUNNING_SPECIAL_SCENARIO；媒体访问全部走系统安全组件。

### UI 重构（代码结构，未做视觉验收）

- 新增 `ui/components/ActionConfigPanel.ets`：工作台 200+ 行内联参数表单（时间点预览、时长/帧率/尺寸/音量/元数据/轨道信息、校验与入队）拆分为独立组件，Workbench 仅保留推荐列表与面板调度。
- 新增 `ui/components/QueueObserver.ets`：HomePage 与 TasksPage 的重复队列监听类收敛为共享实现。
- Workbench 推荐/更多列表改为单次遍历，消除 O(n²) 过滤。

### 验证

- 三组回归测试全部通过（adjustments / native-composition / task-queue），`audio_fade` 断言按新语义保持通过。
- DevEco hvigor API 24 `assembleHap` 构建成功并完成签名。未在模拟器或真机安装验证（用户明确要求本阶段跳过 UI 验收）。
