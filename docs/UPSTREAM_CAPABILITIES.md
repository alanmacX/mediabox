# 上游功能对照与鸿蒙迁移记录

更新：2026-09-05。这里的“原 repo”指概要中作为功能来源的仓库，不是 MediaBox 自身的 Git remote。

## 对照来源

- [@prq/ffmpeg-tools 原仓库](https://github.com/jjjjjjava/ffmpeg_tools)：逐项读取当前实际安装的 2.2.6 `FFmpegFactory.ets`、`FFmpegCommandBuilder.ets`、`FFmpegManager.ets`。执行语义以随包版本为准，没有直接升级或修改第三方依赖。
- [LosslessCut 功能与工作流](https://github.com/mifi/lossless-cut#features)：无损片段、轨道管理、技术信息、时间点和关键帧工作流的对照来源。不是将其 Electron/GPL 实现复制进工程。
- [Shutter Encoder 官方文档](https://www.shutterencoder.com/documentation/)：参数、编码、预览、批处理工作流参考。
- HandBrake 在概要中属于功能研究来源；本轮官方功能页读取失败，不宣称完成全部功能核对。

## FFmpegFactory 本地功能覆盖

这里“已接入”仅表示已有参数入口及执行实现，不表示已经通过所有格式与设备验证。

| 上游方法/能力 | MediaBox 参数入口 | 当前执行路径 | 预览与边界 |
| --- | --- | --- | --- |
| remux | 无损转 MP4 / MKV 等固定目标动作 | FFmpeg stream copy | 容器兼容性仍取决于实际轨道 |
| cut | 无损裁剪的起点、时长 | FFmpeg stream copy | 可查看所选时间附近画面；不把关键帧裁剪称为帧精确 |
| extractAudio | M4A / WAV / FLAC，码率、采样率、声道 | FFmpeg | 明确提取首条音轨；逐轨复制走流工具 |
| scale | 自定义宽高、比例、可选码率 | 常规 MP4 转码用 AVTranscoder；视频滤镜用 FFmpeg | 原生缩略构图预览 |
| videoCrop / videoCropCenter | 宽高、X/Y、居中按钮、可选码率 | FFmpeg + 鸿蒙硬件编码器 | 原生关键帧裁剪预览；视频采用偶数像素边界 |
| watermark | 图片、水印宽度、预设位置/自定义坐标 | 视频 FFmpeg 硬件编码；图片原生绘图 | 水印缩略预览；图片与预览共用原生渲染器 |
| transcode | MP4、AVC/HEVC、尺寸、视频/音频码率 | AVTranscoder | 按 prepare 的实际设备能力判断成功，不虚构编码支持 |
| concat | 文件顺序、兼容合并/参数一致时无损合并 | FFmpeg | 可调整文件顺序；尚无多段时间线编辑器 |
| videoToGif | 起点、时长、帧率、宽度 | FFmpeg 调色板管线 | 时间点画面预览；不是完整动画质量预演 |
| videoSnapshot | 时间点 | FFmpeg；取预览用 Media Kit | 支持时间滑杆和所选时间点预览 |
| videoToImages | 抽帧间隔（可表达每秒 N 帧） | FFmpeg | 多文件输出；尚无任意输出文件名模板 UI |
| imagesToVideo | 顺序、逐帧模式/幻灯片模式、FPS、停留时间 | FFmpeg + 鸿蒙硬件编码器 | 逐帧模式每张持续 1/FPS 秒 |
| imageScale | 宽高、比例、编码质量及设备可用格式 | Image Kit | 缩略构图预览 |
| imageConvert | JPEG / PNG / WebP / HEIF 等已开放动作、质量、JPEG 背景 | Image Kit 优先；BMP/TIFF 用 FFmpeg | 不把缩略图当作最终压缩质量预览 |
| imageWatermark | 五种上游位置预设、自定义坐标及宽度 | Image Kit + ArkGraphics2D | 原生预览与输出使用同一绘制函数；PNG 保留透明 |
| imageHStack / imageVStack | 横向/纵向、顺序、公共边上限 | Image Kit + ArkGraphics2D | 统一公共边后拼接，输出 PNG；大画布有资源上限 |
| imageRotate | 0/90/180/270 度 | Image Kit | 原生旋转预览 |
| imageCrop | 宽高、X/Y、居中按钮 | Image Kit | 原生裁剪预览 |
| imageAddText | 内容、字号、颜色、X/Y | Image Kit + ArkGraphics2D | 预览和输出共用文字渲染器；超出画布会裁掉，不静默截断文字 |
| downloadRtsp / downloadHls | 未开放 | 未接入业务入口 | 项目仍按本地媒体处理定位实现 |

## 本轮同时修复的参数缺失

- GIF 裁剪/缩放接入构图面板，执行器使用明确的裁剪起点和目标高度。
- 视频速度、循环次数、帧率、时间码和旋转元数据不再使用不可改的固定值。
- 原生转码预设会展示可调整参数，而不是点一下直接按隐藏参数导出。
- 音频音量、采样率、声道、码率、响度 LUFS/真峰值/LRA、动态峰值目标、静音阈值及持续时间可设置。
- 淡入淡出作用于完整输入时长，不再隐式截取 30 秒。
- 批量操作先选择配置，再明确按“开始导出”；文件顺序可调整。只展示与当前操作有关的图片质量等设置。

## 媒体信息

- 精确字节数、毫秒时长、扩展名推断容器与 SDK 检测 MIME 分开显示。
- 修复 MP 像素数单位错误（原先除以 10000，现为 1000000）。
- 每条轨道独立展示尺寸、帧率、码率、采样率、声道、位深、语言和标题。
- 增加相机/镜头、焦距、白平衡、色彩 EXIF 与带方向的 GPS。
- 可展开并复制原始 SDK 元数据及逐轨字段，长文本不再截成两行。
- 区分 SDK 未返回、读取失败与真实值。例如未知 HDR 不直接显示“否”。
- 当前仍没有独立 ffprobe 分析桥接；SDK 不返回的 Profile、色彩或章节数据不能凭空补全。

## 验证和仍未交付的部分

已编译 API 24 HAP；参数、命令、原生拼接几何、水印缩放与队列测试使用生产代码、模拟 SDK 边界。它们不证明真机编码质量或 ArkUI 布局效果。

模拟器覆盖安装曾因签名不一致被拒绝，未擅自卸载。真实 UI/输出验收需可安装当前签名的环境。

以下不应被称为已完整迁移：LosslessCut 的多片段时间线/撤销重做/项目文件/波形，HandBrake 的完整滤镜与编码选项，Shutter Encoder 的全部专业编码链路，完整 HDR 保留、缺失编码器、任意脚本或网络输入、所有高级命令构建器参数。没有用同名按钮替代这些实际能力。
