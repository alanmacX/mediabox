/**
 * 文件工作台 — MediaBox 的核心交互(项目简报 §16)。
 *
 *   VID_001.MOV
 *   4K · 60FPS · HEVC · HDR · 823 MB
 *   ── 推荐 ──────────────────
 *   无损转 MP4   (无需重新编码)
 *   智能压缩        (预计可节省 xx%)
 *   压到指定大小 / 转 GIF / 提取音频
 *   ── 更多 ──────────────────
 *
 * 自适应:sm/md 单栏(预览在上),lg 双栏(左预览、右工具),
 * 充分利用 MatePad / 2in1 横屏空间。
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AudioAdjustmentPanel, hasAudioAdjustment } from '../ui/components/AudioAdjustmentPanel';
import { AdjustmentPanel, hasAdjustmentPanel } from '../ui/components/AdjustmentPanel';
import { ActionConfigPanel, usesSimpleConfig } from '../ui/components/ActionConfigPanel';
import { TaskParams } from '../core/task/MediaTask';
import { TaskQueue } from '../core/task/TaskQueue';
import { MediaAnalyzer, AnalysisResult, PickedFile } from '../core/analyze/MediaAnalyzer';
import { MediaThumb } from '../core/media/MediaThumb';
import { PreviewFrames } from '../core/media/PreviewFrames';
import {
  CapabilityRouter,
  FfmpegEncoderCaps,
  estimateTargetBitrateBps,
  native1080pDimensions,
  nativeMaximumDimensions,
  targetSizeBudget
} from '../core/engine/CapabilityRouter';
import { AnalyzedMedia, ToolAction, Fmt, MediaType, ToolSymbol, EngineKind } from '../core/model/MediaTypes';
import { WorkbenchSession, RouteNames } from '../ui/components/WorkbenchSession';
import { TaskNavigation } from '../ui/components/TaskNavigation';
import { RecommendCard } from '../ui/components/RecommendCard';
import { MediaPreview } from '../ui/components/MediaPreview';
import { GlassCard } from '../ui/components/GlassCard';
import { SectionHeader } from '../ui/components/CommonUi';
import { Adaptive, Breakpoint } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';

@Component
export struct Workbench {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @State media: AnalyzedMedia | undefined = undefined;
  @State thumbnail?: image.PixelMap = undefined;
  @State analyzing: boolean = false;
  @State previewUri: string = '';
  private pageScroller: Scroller = new Scroller();
  @State actions: ToolAction[] = [];
  private encoderCaps: FfmpegEncoderCaps = {};
  @State subtitlePreview: string = '';

  aboutToAppear(): void {
    if (WorkbenchSession.result !== undefined) {
      this.applyResult(WorkbenchSession.result);
    } else if (WorkbenchSession.picked !== undefined) {
      this.analyze(WorkbenchSession.picked);
    }
  }

  private cachePreview(pm: image.PixelMap): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MediaThumb.cachePreview(pm, context).then((uri: string) => {
      if (this.media !== undefined) {
        this.previewUri = uri;
        WorkbenchSession.previewUri = uri;
      }
    }).catch(() => {
      // 预览图缓存失败时退回 PixelMap 渲染
    });
  }

  private applyResult(r: AnalysisResult): void {
    this.media = r.media;
    this.thumbnail = r.thumbnail;
    this.previewUri = WorkbenchSession.previewUri ?? '';
    if (r.thumbnail !== undefined) {
      this.cachePreview(r.thumbnail);
    }
    WorkbenchSession.result = r;
    WorkbenchSession.thumbnail = r.thumbnail;
    this.actions = CapabilityRouter.recommend(r.media, this.encoderCaps);
    this.analyzing = false;
    if (r.media.mediaType === MediaType.SUBTITLE) {
      this.loadSubtitlePreview(r.media.uri);
    }
    // 视频/图片/动态照片：缩略图缺失时用 MediaThumb 兜底（动态照片走系统关键帧）
    if (this.thumbnail === undefined && MediaThumb.wantsPreview(r.media.mediaType, r.media.isMovingPhoto)) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      MediaThumb.load(r.media, context, 0).then((pm: image.PixelMap | undefined) => {
        if (pm !== undefined && this.media !== undefined && this.media.uri === r.media.uri) {
          this.thumbnail = pm;
          WorkbenchSession.thumbnail = pm;
          this.cachePreview(pm);
        }
      }).catch(() => {
        // 预览失败不阻断工具列表
      });
    }
    // 不在用户刚选完媒体时抢占 FFmpeg 的唯一执行线程做编码器探测。
    // 探测异常会让后续真正的导出永远等不到 onStart，表现为任务卡停在“正在准备”。
    // 罕见编码器的可用性在实际执行时由引擎如实返回错误，不阻塞常规视频任务。
  }

  private loadSubtitlePreview(uri: string): void {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const size = Math.min(64 * 1024, fileIo.statSync(file.fd).size);
      const buffer = new ArrayBuffer(size);
      const bytesRead = fileIo.readSync(file.fd, buffer, { length: size });
      const bytes = new Uint8Array(buffer, 0, bytesRead);
      this.subtitlePreview = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
    } catch (e) {
      this.subtitlePreview = '无法预览该字幕编码，可尝试转换为 SRT。';
    } finally {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
    }
  }

  private async analyze(picked: PickedFile): Promise<void> {
    this.analyzing = true;
    const r = await MediaAnalyzer.analyze(picked);
    WorkbenchSession.result = r;
    this.applyResult(r);
  }

  private typeIcon(): ToolSymbol {
    switch (this.media?.mediaType) {
      case MediaType.VIDEO:
        return ToolSymbol.VIDEO;
      case MediaType.AUDIO:
        return ToolSymbol.AUDIO;
      case MediaType.GIF:
        return ToolSymbol.GIF;
      case MediaType.IMAGE:
        return ToolSymbol.IMAGE;
      default:
        return ToolSymbol.FILE;
    }
  }

  private summaryChips(): string[] {
    const m = this.media;
    if (m === undefined) {
      return [];
    }
    const chips: string[] = [];
    if (m.video !== undefined) {
      chips.push(`${m.video.width}×${m.video.height}`);
      if (m.video.fps > 0) {
        chips.push(`${Math.round(m.video.fps)}FPS`);
      }
      chips.push(m.video.codec);
      if (m.video.hdr) {
        chips.push('HDR');
      }
    }
    if (m.imageWidth > 0) {
      chips.push(`${m.imageWidth}×${m.imageHeight}`);
    }
    if (m.imageFrameCount > 1) {
      chips.push(`${m.imageFrameCount} 帧`);
    }
    if (m.audio !== undefined) {
      chips.push(m.audio.codec.length > 0 ? m.audio.codec : 'Audio');
      if (m.audio.sampleRateHz > 0) {
        chips.push(`${Math.round(m.audio.sampleRateHz / 1000)}kHz`);
      }
    }
    if (m.durationMs > 0) {
      chips.push(Fmt.duration(m.durationMs));
    }
    if (m.sizeBytes > 0) {
      chips.push(Fmt.bytes(m.sizeBytes));
    }
    return chips;
  }

  /** 推荐区 = 无损优先 + 压缩;其余进"更多"。 */
  private splitActions(): ToolAction[] {
    const primary: ToolAction[] = [];
    for (const a of this.actions) {
      if (a.lossless || a.id === 'compress_smart' || a.id === 'compress_target_size' || a.id === 'media_info') {
        primary.push(a);
      }
    }
    return primary;
  }

  private moreActions(): ToolAction[] {
    const primary = this.splitActions();
    return this.actions.filter((a: ToolAction) => !primary.includes(a));
  }

  private onRun(action: ToolAction): void {
    const m = this.media;
    if (m === undefined) {
      return;
    }
    // 需要参数的工具：统一进入二级配置页（标题=工具名），返回回到工作台。
    if (hasAudioAdjustment(action.id) || hasAdjustmentPanel(action.id) ||
      usesSimpleConfig(action.id) ||
      action.id === 'compress_target_size' || action.id === 'image_target_size' ||
      action.id === 'gif_target_size') {
      WorkbenchSession.pendingAction = action;
      this.pathStack.pushPathByName(RouteNames.TOOL_CONFIG, action.title);
      return;
    }
    if (action.id === 'media_info') {
      this.pathStack.pushPathByName(RouteNames.MEDIA_INFO, '');
      return;
    }
    // 方案 A：无参工具先二次确认，避免误触直接写入队列
    AlertDialog.show({
      title: action.title,
      message: action.subtitle.length > 0 ? action.subtitle : '将按默认参数开始处理，可在任务页取消。',
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '开始',
        fontColor: $r('app.color.accent'),
        action: () => {
          this.executeQuickAction(action);
        }
      }
    });
  }

  private executeQuickAction(action: ToolAction): void {
    const m = this.media;
    if (m === undefined) {
      return;
    }
    if (action.id.startsWith('moving_photo_')) {
      WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], action.id, action.title, {});
      TaskNavigation.showRootQueue();
      return;
    }
    if (m.mediaType === MediaType.IMAGE && action.id.startsWith('image_')) {
      let targetWidth: number | undefined = undefined;
      let targetHeight: number | undefined = undefined;
      let imageFormat = 'image/jpeg';
      let imageQuality = 90;
      let stripMetadata = false;
      if (action.id === 'image_convert') {
        imageFormat = 'image/webp';
      } else if (action.id === 'image_to_png') {
        imageFormat = 'image/png';
      } else if (action.id === 'image_to_heif') {
        imageFormat = 'image/heif';
      } else if (action.id === 'image_to_avif') {
        imageFormat = 'image/avif';
      } else if (action.id === 'image_compress') {
        imageQuality = 72;
      } else if (action.id === 'image_resize') {
        const scale = Math.min(1, 1920 / Math.max(m.imageWidth, m.imageHeight, 1));
        targetWidth = Math.max(1, Math.round(m.imageWidth * scale));
        targetHeight = Math.max(1, Math.round(m.imageHeight * scale));
      } else if (action.id === 'image_metadata') {
        stripMetadata = true;
      }
      const squareSide = Math.min(m.imageWidth, m.imageHeight);
      WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], action.id, action.title, {
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        imageFormat: imageFormat,
        imageQuality: imageQuality,
        stripMetadata: stripMetadata,
        imageRotateDegrees: action.id === 'image_rotate' ? 90 : undefined,
        imageFlipHorizontal: action.id === 'image_flip' ? true : undefined,
        cropX: action.id === 'image_crop' ? Math.floor((m.imageWidth - squareSide) / 2) : undefined,
        cropY: action.id === 'image_crop' ? Math.floor((m.imageHeight - squareSide) / 2) : undefined,
        cropWidth: action.id === 'image_crop' ? squareSide : undefined,
        cropHeight: action.id === 'image_crop' ? squareSide : undefined
      });
      TaskNavigation.showRootQueue();
      return;
    }
    if (m.video !== undefined && (action.id === 'compress_smart' || action.id === 'compress_target_size'
      || action.id === 'convert_mp4' || action.id.startsWith('preset_') || action.id === 'hdr_to_sdr'
      || action.id === 'hdr_preserve')) {
      // 原生转码:按官方经验公式计算目标码率,1080p 封顶
      const src = m.video;
      let dimensions = native1080pDimensions(src.width, src.height);
      if (action.id === 'preset_quality') {
        dimensions = nativeMaximumDimensions(src.width, src.height);
      } else if (action.id === 'preset_small') {
        const scale = Math.min(1, 1280 / Math.max(src.width, 1), 720 / Math.max(src.height, 1));
        dimensions = { width: Math.max(240, Math.floor(src.width * scale / 2) * 2),
          height: Math.max(240, Math.floor(src.height * scale / 2) * 2) };
      }
      const dstW = dimensions.width;
      const dstH = dimensions.height;
      const targetBps = estimateTargetBitrateBps(src.width, src.height, src.fps, src.bitrateKbps * 1000,
        dstW, dstH, Math.max(src.fps, 30));
      const bitrateFactor = action.id === 'preset_quality' ? 1.25 : (action.id === 'preset_small' ? 0.7 : 1);
      WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], action.id, action.title, {
        targetVideoKbps: Math.round(targetBps * bitrateFactor / 1000),
        targetAudioKbps: 128,
        targetVideoCodec: action.id === 'hdr_preserve' ? 'HEVC' : 'AVC',
        targetWidth: dstW,
        targetHeight: dstH,
        targetContainer: 'MP4'
      });
      TaskNavigation.showRootQueue();
      return;
    }
    if (action.engine === EngineKind.FFMPEG) {
      const durationSeconds = Math.max(1, Math.min(30, Math.floor(m.durationMs / 1000))).toString();
      WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], action.id, action.title, {
        targetWidth: action.id === 'to_gif' ? 480 : undefined,
        targetFps: action.id === 'video_fps' ? 30 :
          (action.id === 'to_gif' || action.id.startsWith('gif_') ? 12 : undefined),
        targetAudioKbps: action.id.startsWith('audio_') ? 192 : undefined,
        targetSampleRateHz: action.id === 'audio_mono' ? 48000 : undefined,
        targetChannels: action.id === 'audio_mono' ? 1 : (action.id === 'audio_stereo' ? 2 : undefined),
                startTime: '00:00:00',
        durationSeconds: durationSeconds,
        loopCount: '0',
        speed: action.id === 'gif_speed' ? 1 : undefined,
        streamKind: m.audio !== undefined ? 'av' : 'video',
        totalDurationSeconds: Math.max(0, m.durationMs / 1000),
        subtitleDelaySeconds: action.id === 'subtitle_shift_advance' ? -0.5 : 0.5
      });
      TaskNavigation.showRootQueue();
    }
  }

  private enqueueTargetSize(): void {
    // 已迁移到 ToolConfigPage 二级配置页
  }

  @Builder
  Chip(text: string) {
    Text(text)
      .fontSize(Dt.fontCaption)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(Dt.radiusSm)
      .backgroundColor($r('app.color.accent_soft'))
  }

  private previewHeight(): number {
    return Dt.previewH;
  }

  @Builder
  PreviewPane() {
    GlassCard({ radius: Dt.radiusXl, paddingV: Dt.spaceLg }) {
      Column({ space: Dt.spaceMd }) {
        MediaPreview({
          media: this.media,
          thumbnail: this.thumbnail,
          previewUri: this.previewUri,
          subtitlePreview: this.subtitlePreview,
          heightVp: Dt.previewH
        })
        Text(this.media?.displayName ?? '')
          .fontSize(Dt.fontSub)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.summaryChips(), (c: string) => {
            Text(c)
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(Dt.radiusSm)
              .backgroundColor($r('app.color.accent_soft'))
              .margin({ right: Dt.spaceSm, bottom: Dt.spaceSm })
          }, (c: string) => c)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  @Builder
  ActionListItem(a: ToolAction) {
    Row({ space: Dt.spaceMd }) {
      Row() {
        SystemSymbolIcon({
          name: a.icon,
          iconSize: 20,
          color: a.lossless ? $r('app.color.lossless_green') : $r('app.color.accent')
        })
      }
      .width(Dt.iconBox)
      .height(Dt.iconBox)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(Dt.radiusMd)
      .backgroundColor(a.lossless ? $r('app.color.lossless_green_soft') : $r('app.color.accent_soft'))

      Column({ space: 2 }) {
        Row({ space: Dt.spaceSm }) {
          Text(a.title)
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          if (a.lossless) {
            Text('无损')
              .fontSize(11)
              .fontColor($r('app.color.lossless_green'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor($r('app.color.lossless_green_soft'))
          }
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')
        Text(a.subtitle)
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if ((a.estimatedSavingPct ?? 0) > 0) {
        Text(`-${a.estimatedSavingPct}%`)
          .fontSize(Dt.fontBody)
          .fontColor($r('app.color.lossless_green'))
          .fontWeight(FontWeight.Medium)
      } else if (!a.available) {
        Text(a.statusLabel ?? '不可用')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      } else {
        SystemSymbolIcon({ name: ToolSymbol.CHEVRON, iconSize: 16,
          color: $r('app.color.text_tertiary') })
      }
    }
    .width('100%')
    .padding({ left: Dt.spaceMd, right: Dt.spaceMd, top: Dt.spaceMd, bottom: Dt.spaceMd })
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({
      radius: 24,
      color: '#0F101814',
      offsetX: 0,
      offsetY: 8
    })
    .opacity(a.available === false ? 0.55 : 1)
    .onClick(() => {
      if (a.available) {
        this.onRun(a);
      }
    })
  }

  @Builder
  ToolsPane() {
    Column({ space: Dt.spaceSm }) {
      Text($r('app.string.workbench_recommend'))
        .fontSize(Dt.fontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: Dt.spaceSm })

      if (this.analyzing) {
        Text($r('app.string.workbench_analyzing'))
          .fontSize(Dt.fontBody)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Dt.spaceXxl)
      } else {
        ForEach(this.splitActions(), (a: ToolAction) => {
          this.ActionListItem(a)
        }, (a: ToolAction) => a.id)

        if (this.moreActions().length > 0) {
          Text($r('app.string.workbench_more'))
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: Dt.spaceSm, bottom: Dt.spaceSm })
          ForEach(this.moreActions(), (a: ToolAction) => {
            this.ActionListItem(a)
          }, (a: ToolAction) => a.id)
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 工作台是全屏二级页，以实际全宽决定是否容纳得下双栏。 */
  private useWideWorkbench(): boolean {
    const contentWidth = this.windowWidthVp;
    return contentWidth >= 700 || (!this.isLandscape && Adaptive.breakpoint(contentWidth) === Breakpoint.LG);
  }

  build() {
    // 横屏：有足够内容宽度时才采用左预览 + 右工具独立滚动。
    if (this.useWideWorkbench()) {
      Row({ space: Dt.spaceLg }) {
        Column() {
          this.PreviewPane()
        }
        .width('38%')
        .constraintSize({ maxWidth: 460, minWidth: 300 })
        .height('100%')
        .padding({ top: 96 })
        Scroll(this.pageScroller) {
          Column() {
            this.ToolsPane()
          }
          .width('100%')
          .padding({ top: 96, bottom: Dt.spaceXxl })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Top)
      .padding({
        left: Dt.navContentInset,
        right: Adaptive.pagePadding(this.windowWidthVp),
        top: 24,
        bottom: Dt.spaceLg
      })
      .backgroundColor(Color.Transparent)
    } else {
      Scroll(this.pageScroller) {
        Column() {
          this.PreviewPane()
          this.ToolsPane()
        }
        .width('100%')
        .padding({
          left: Dt.navContentInset,
          right: Adaptive.pagePadding(this.windowWidthVp),
          top: 96,
          bottom: Dt.spaceXxl
        })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
  }
}
