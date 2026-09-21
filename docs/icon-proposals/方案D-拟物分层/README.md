# 方案 D · 拟物分层图标

由原始草图 `../方案D-全幅蓝底.png` 经内置 imagegen 生成，随后统一缩放并合成。

- `foreground.png`：1024 × 1024，RGBA，透明前景（纸箱与媒体卡片）。
- `background.png`：1024 × 1024，RGB，满幅蓝色背景。
- `icon-composite.png`：1024 × 1024，RGB，总成预览。
- `icon-120px-preview.png`：120 × 120，小尺寸预览。

项目现有 `AppScope/resources/base/media/layered_image.json` 使用 `$media:foreground` 与 `$media:background`。选定此方案后，可将两层资源复制到该目录覆盖现有同名资源；本次未覆盖现有应用图标。

## 生成提示词摘要

前景：以方案 D 草图为构图参考，保留打开的牛皮纸纸箱、橙色播放、紫色 GIF、绿色音乐、粉色图片和青色列表卡片；转换为有纸纤维、折边、环境遮蔽、柔和高光和阴影的立体拟物图标；背景完全透明，只有 `GIF` 文本。

后景：以草图的蓝色为基准，生成满幅钴蓝至皇家蓝的柔和渐变，不包含任何前景物体、文字和圆角。
