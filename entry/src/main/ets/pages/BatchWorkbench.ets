/**
 * 多文件工作台：批量操作与多输入合成均进入同一真实任务队列。
 * 宽屏：左文件清单 / 右工具与配置（UX-12）。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { MediaThumb } from '../core/media/MediaThumb';
import { BatchResultPreview } from '../core/media/BatchResultPreview';
import { PickedFile, guessMediaType } from '../core/analyze/MediaAnalyzer';
import { MediaType, ToolSymbol } from '../core/model/MediaTypes';
import { TaskQueue } from '../core/task/TaskQueue';
import { TaskParams } from '../core/task/MediaTask';
import { MovingPhotoEngine } from '../core/engine/MovingPhotoEngine';
import { DeviceSupport } from '../core/capability/DeviceSupport';
import { WorkbenchSession, RouteNames } from '../ui/components/WorkbenchSession';
import { TaskNavigation } from '../ui/components/TaskNavigation';
import { GlassCard } from '../ui/components/GlassCard';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';
import { Adaptive, Breakpoint } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';

@Component
export struct BatchWorkbench {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @StorageProp('preferredHand') @Watch('onPreferredHandChange') preferredHand: string = 'right';
  /** 与单任务配置页一致：左手时把操作栏放在左侧。 */
  @State controlsOnLeft: boolean = false;
  @State files: PickedFile[] = [];
  @State fileThumbs: Map<string, image.PixelMap> = new Map();
  @State busy: boolean = false;
  @State pendingTitle: string = '';
  @State subtitleOffsetText: string = '500';
  private pageActive: boolean = true;
  @State pendingDescription: string = '';
  @State qualityValue: number = 90;
  @State dimensionText: string = '1920';
  @State holdText: string = '2';
  @State fpsText: string = '30';
  @State watermarkWidthText: string = '240';
  @State watermarkPosition: string = 'custom';
  @State watermarkXText: string = '24';
  @State watermarkYText: string = '24';
  @State resultPreview: image.PixelMap | undefined = undefined;
  @State previewBusy: boolean = false;
  @State previewNote: string = '';
  @State previewFrameIndex: number = 0;
  private pendingAction?: () => void;
  private pageScroller: Scroller = new Scroller();
  private previewTimer: number = -1;
  private frameTimer: number = -1;
  private previewEpoch: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    this.controlsOnLeft = this.preferredHand === 'left';
    this.files = WorkbenchSession.pickedFiles.slice();
    this.loadFileThumbs();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.stopPreviewTimers();
    this.previewEpoch++;
    this.resultPreview?.release().catch(() => {});
    this.resultPreview = undefined;
  }

  private onPreferredHandChange(): void {
    const wantLeft = this.preferredHand === 'left';
    if (wantLeft === this.controlsOnLeft) {
      return;
    }
    this.getUIContext().animateTo({ duration: 360, curve: Curve.FastOutSlowIn }, (): void => {
      this.controlsOnLeft = wantLeft;
    });
  }

  /** 文件清单缩略图：动态照片用系统关键帧；音频/字幕不加载。 */
  private loadFileThumbs(): void {
    if (this.files.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const next = new Map(this.fileThumbs);
    let changed = false;
    const jobs: Promise<void>[] = this.files.map(async (file: PickedFile) => {
      const type = file.mediaTypeHint ?? guessMediaType(file.displayName);
      if (!MediaThumb.wantsPreview(type, file.isMovingPhoto === true)) {
        return;
      }
      const key = file.uri;
      if (next.has(key)) {
        return;
      }
      try {
        const pm = await MediaThumb.load({
          uri: file.uri,
          displayName: file.displayName,
          mediaType: type,
          isMovingPhoto: file.isMovingPhoto === true
        }, context, 0);
        if (pm !== undefined && this.pageActive) {
          next.set(key, pm);
          changed = true;
        }
      } catch (e) {
        // 单文件预览失败不影响清单
      }
    });
    Promise.all(jobs).then(() => {
      if (changed && this.pageActive) {
        this.fileThumbs = next;
      }
    });
  }

  private wantsFileThumb(file: PickedFile): boolean {
    const type = file.mediaTypeHint ?? guessMediaType(file.displayName);
    return MediaThumb.wantsPreview(type, file.isMovingPhoto === true);
  }

  private moveFile(index: number, offset: number): void {
    const target = index + offset;
    if (target < 0 || target >= this.files.length) {
      return;
    }
    const next = this.files.slice();
    const file = next.splice(index, 1)[0];
    next.splice(target, 0, file);
    this.files = next;
    WorkbenchSession.pickedFiles = next;
    this.scheduleResultPreview();
  }

  private removeFile(index: number): void {
    const next = this.files.slice();
    next.splice(index, 1);
    this.files = next;
    WorkbenchSession.pickedFiles = next;
    this.previewFrameIndex = Math.min(this.previewFrameIndex, Math.max(0, next.length - 1));
    this.scheduleResultPreview();
  }

  private typeOf(file: PickedFile): MediaType {
    return file.mediaTypeHint ?? guessMediaType(file.displayName);
  }

  private allOf(type: MediaType): boolean {
    return this.files.length > 0 && this.files.every((file: PickedFile) => this.typeOf(file) === type);
  }

  private allImages(): boolean {
    return this.files.length > 0 && this.files.every((file: PickedFile) => {
      const t = this.typeOf(file);
      return t === MediaType.IMAGE || t === MediaType.GIF;
    });
  }

  private videoAndAudio(): boolean {
    return this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO) &&
      this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.AUDIO) &&
      this.files.every((f: PickedFile) => {
        const t = this.typeOf(f);
        return t === MediaType.VIDEO || t === MediaType.AUDIO;
      });
  }

  private imageAndAudio(): boolean {
    return this.files.some((f: PickedFile) => {
      const t = this.typeOf(f);
      return t === MediaType.IMAGE || t === MediaType.GIF;
    }) && this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.AUDIO);
  }

  private videoAndImage(): boolean {
    return this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO) &&
      this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.IMAGE);
  }

  private videoAndSubtitle(): boolean {
    return this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO) &&
      this.files.some((f: PickedFile) => this.typeOf(f) === MediaType.SUBTITLE);
  }

  private notify(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private numberValue(text: string, fallback: number, min: number, max: number): number {
    const parsed = Number(text);
    return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
  }

  private enqueueSimpleBatch(actionId: string, title: string): void {
    const uris = this.files.map((f: PickedFile) => f.uri);
    const names = this.files.map((f: PickedFile) => f.displayName);
    WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue(uris, names, actionId, title, {
      imageFormat: actionId === 'image_convert' ? 'image/webp' : 'image/jpeg',
      imageQuality: Math.round(this.qualityValue)
    });
    TaskNavigation.showRootQueue();
  }

  private enqueueImageResize(): void {
    const limit = Math.max(16, Number(this.dimensionText) || 1920);
    const uris = this.files.map((f: PickedFile) => f.uri);
    const names = this.files.map((f: PickedFile) => f.displayName);
    WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue(uris, names, 'image_resize', '批量缩放', {
      targetWidth: limit,
      targetHeight: limit,
      imageFormat: 'image/jpeg',
      imageQuality: Math.round(this.qualityValue)
    });
    TaskNavigation.showRootQueue();
  }

  private enqueueCombined(actionId: string, title: string, inputs: PickedFile[], params: TaskParams = {}): void {
    // 多输入操作必须作为一个任务携带全部输入；enqueue 的逐文件拆分只适用于批量同类操作。
    WorkbenchSession.lastTaskIds = [TaskQueue.getInstance().enqueueTaskGroup(
      inputs.map((f: PickedFile) => f.uri),
      inputs.map((f: PickedFile) => f.displayName),
      actionId, title, params)];
    TaskNavigation.showRootQueue();
  }

  private enqueueVideoCompress(): void {
    const videos = this.files.filter((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO);
    if (videos.length === 0) {
      this.notify('没有可处理的视频');
      return;
    }
    WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue(
      videos.map((f: PickedFile) => f.uri),
      videos.map((f: PickedFile) => f.displayName),
      'compress_smart', '批量智能压缩', { targetVideoKbps: 2000, targetAudioKbps: 128, targetContainer: 'MP4' });
    TaskNavigation.showRootQueue();
  }

  private enqueueVideoMerge(): void {
    this.enqueueCombined('video_merge', '合并视频', this.files);
  }

  private enqueueLosslessVideoMerge(): void {
    this.enqueueCombined('video_merge_lossless', '无损合并视频', this.files);
  }

  private enqueueReplaceAudio(): void {
    const videos = this.files.filter((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO);
    const audios = this.files.filter((f: PickedFile) => this.typeOf(f) === MediaType.AUDIO);
    if (videos.length !== 1 || audios.length !== 1) {
      this.notify('请只选择 1 个视频和 1 个音频');
      return;
    }
    this.enqueueCombined('replace_audio', '替换音轨', [videos[0], audios[0]]);
  }

  private enqueueImageAudio(): void {
    const imageFile = this.files.find((f: PickedFile) => {
      const t = this.typeOf(f);
      return t === MediaType.IMAGE || t === MediaType.GIF;
    });
    const audioFile = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.AUDIO);
    if (imageFile !== undefined && audioFile !== undefined) {
      this.enqueueCombined('image_audio_video', '图片与音频生成视频', [imageFile, audioFile]);
    }
  }

  private enqueueCoverArt(): void {
    const imageFile = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.IMAGE);
    const audioFile = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.AUDIO);
    if (imageFile !== undefined && audioFile !== undefined) {
      this.enqueueCombined('metadata_cover', '写入音频封面', [audioFile, imageFile]);
    }
  }

  private enqueueVideoWatermark(): void {
    const video = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO);
    const mark = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.IMAGE);
    if (video !== undefined && mark !== undefined) {
      this.enqueueCombined('video_watermark', '添加视频水印', [video, mark], {
        watermarkWidth: Math.round(this.numberValue(this.watermarkWidthText, 240, 16, 4096)),
        watermarkPosition: this.watermarkPosition,
        watermarkX: Math.round(this.numberValue(this.watermarkXText, 24, 0, 32768)),
        watermarkY: Math.round(this.numberValue(this.watermarkYText, 24, 0, 32768))
      });
    }
  }

  private enqueueSubtitle(actionId: string, title: string): void {
    const video = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO);
    const sub = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.SUBTITLE);
    if (video !== undefined && sub !== undefined) {
      this.enqueueCombined(actionId, title, [video, sub]);
    }
  }

  private async saveMovingPhoto(result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      this.notify('未获得保存授权');
      return;
    }
    const imageFile = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.IMAGE);
    const videoFile = this.files.find((f: PickedFile) => this.typeOf(f) === MediaType.VIDEO);
    if (imageFile === undefined || videoFile === undefined) {
      this.notify('需要 1 张图片和 1 个视频');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await MovingPhotoEngine.createInMediaLibrary(context, imageFile.uri, videoFile.uri, 'MediaBox');
      this.notify('动态照片已保存到图库');
    } catch (e) {
      this.notify(`保存失败：${(e as Error).message}`);
    }
  }

  private stopPreviewTimers(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    if (this.frameTimer >= 0) {
      clearInterval(this.frameTimer);
      this.frameTimer = -1;
    }
  }

  private isSequencePreview(): boolean {
    return this.pendingTitle === '图片生成视频' || this.pendingTitle === '图片生成 GIF';
  }

  private restartFramePreview(): void {
    if (this.frameTimer >= 0) {
      clearInterval(this.frameTimer);
      this.frameTimer = -1;
    }
    if (!this.pageActive || !this.isSequencePreview() || this.files.length < 2) {
      return;
    }
    const delay = Math.round(this.numberValue(this.holdText, 2, 0.35, 3) * 1000);
    this.frameTimer = setInterval((): void => {
      if (!this.pageActive || !this.isSequencePreview() || this.files.length < 2) {
        return;
      }
      this.previewFrameIndex = (this.previewFrameIndex + 1) % this.files.length;
      this.scheduleResultPreview(0);
    }, delay);
  }

  private scheduleResultPreview(delay: number = 180): void {
    if (!this.pageActive || !BatchResultPreview.supports(this.pendingTitle)) {
      return;
    }
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
    }
    const epoch = ++this.previewEpoch;
    this.previewBusy = true;
    this.previewTimer = setTimeout((): void => {
      this.previewTimer = -1;
      this.updateResultPreview(epoch);
    }, delay);
  }

  private async updateResultPreview(epoch: number): Promise<void> {
    let pixels: image.PixelMap | undefined = undefined;
    try {
      pixels = await BatchResultPreview.render(this.files, this.pendingTitle,
        this.qualityValue, Math.round(this.numberValue(this.dimensionText, 1920, 16, 32768)),
        this.previewFrameIndex);
      if (!this.pageActive || epoch !== this.previewEpoch || this.pendingTitle.length === 0) {
        await pixels?.release();
        return;
      }
      const old = this.resultPreview;
      this.resultPreview = pixels;
      pixels = undefined;
      await old?.release();
      if (this.isSequencePreview()) {
        this.previewNote = `第 ${this.previewFrameIndex + 1}/${this.files.length} 帧段 · 实际按设置时长依次播放`;
      } else if (this.pendingTitle.includes('拼接')) {
        this.previewNote = '按当前顺序与拼接边长实时合成';
      } else if (this.pendingTitle === '批量缩放') {
        this.previewNote = '首项按当前长边上限等比缩放';
      } else {
        this.previewNote = '首项按当前格式与编码质量生成';
      }
    } catch (e) {
      if (epoch === this.previewEpoch) {
        this.previewNote = `预览失败：${(e as Error).message}`;
      }
    } finally {
      await pixels?.release();
      if (epoch === this.previewEpoch) {
        this.previewBusy = false;
      }
    }
  }

  private releaseResultPreview(): void {
    this.stopPreviewTimers();
    this.previewEpoch++;
    this.previewBusy = false;
    this.previewNote = '';
    const old = this.resultPreview;
    this.resultPreview = undefined;
    old?.release().catch(() => {});
  }

  private startConfigured(): void {
    if (this.pendingAction !== undefined) {
      this.pendingAction();
      this.releaseResultPreview();
      this.pendingTitle = '';
    }
  }

  private openConfig(title: string, description: string, action: () => void): void {
    this.pendingAction = action;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, (): void => {
      this.pendingTitle = title;
      this.pendingDescription = description;
      this.previewFrameIndex = 0;
      this.scheduleResultPreview(0);
      this.restartFramePreview();
    });
  }

  private closeConfig(): void {
    this.releaseResultPreview();
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
      this.pendingTitle = '';
      this.pendingDescription = '';
    });
    this.pendingAction = undefined;
  }

  @Builder
  ActionButton(icon: ToolSymbol, title: string, subtitle: string, action: () => void) {
    Button() {
      Row({ space: Dt.spaceMd }) {
        SystemSymbolIcon({ name: icon, iconSize: Dt.fontTitle, color: $r('app.color.text_primary') })
        Column({ space: 2 }) {
          Text(title).fontSize(Dt.fontBody).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).width('100%')
          Text(subtitle).fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SystemSymbolIcon({ name: ToolSymbol.CHEVRON, iconSize: Dt.fontBody,
          color: $r('app.color.text_secondary') })
      }.width('100%')
    }
    .width('100%').height(68).padding({ left: Dt.spaceMd, right: Dt.spaceMd })
    .buttonStyle(ButtonStyleMode.NORMAL)
    .enabled(!this.busy).onClick(() => {
      this.openConfig(title, subtitle, action);
    })
  }

  @Builder
  FileRow(file: PickedFile, index: number) {
    Row({ space: Dt.spaceSm }) {
      if (this.wantsFileThumb(file)) {
        if (this.fileThumbs.has(file.uri)) {
          Image(this.fileThumbs.get(file.uri))
            .width(48).height(48).objectFit(ImageFit.Cover)
            .borderRadius(Dt.radiusSm).backgroundColor('#181818')
        } else {
          Column() {
            SystemSymbolIcon({
              name: file.isMovingPhoto === true ? ToolSymbol.IMAGE :
                (this.typeOf(file) === MediaType.VIDEO ? ToolSymbol.VIDEO : ToolSymbol.IMAGE),
              iconSize: 17, color: $r('app.color.text_secondary')
            })
          }
          .width(48).height(48).justifyContent(FlexAlign.Center)
          .borderRadius(Dt.radiusSm).backgroundColor('#181818')
        }
      } else {
        Column() {
          SystemSymbolIcon({
            name: this.typeOf(file) === MediaType.AUDIO ? ToolSymbol.AUDIO : ToolSymbol.FILE,
            iconSize: 17, color: $r('app.color.text_secondary')
          })
        }
        .width(48).height(48).justifyContent(FlexAlign.Center)
        .borderRadius(Dt.radiusSm).backgroundColor($r('app.color.app_background'))
      }
      Column({ space: 2 }) {
        Text(file.displayName).fontSize(Dt.fontBody).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(`第 ${index + 1} 项`).fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary')).width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(15)
          .fontColor([$r('app.color.text_primary')])
      }
      .type(ButtonType.Circle).width(36).height(36).buttonStyle(ButtonStyleMode.NORMAL)
      .enabled(index > 0 && !this.busy).onClick(() => this.moveFile(index, -1))
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(15)
          .fontColor([$r('app.color.text_primary')])
      }
      .type(ButtonType.Circle).width(36).height(36).buttonStyle(ButtonStyleMode.NORMAL)
      .enabled(index < this.files.length - 1 && !this.busy).onClick(() => this.moveFile(index, 1))
      Button() {
        SystemSymbolIcon({ name: ToolSymbol.DELETE, iconSize: 16,
          color: $r('app.color.text_secondary') })
      }
      .type(ButtonType.Circle).width(36).height(36).buttonStyle(ButtonStyleMode.NORMAL)
      .backgroundColor(Color.Transparent).enabled(!this.busy)
      .onClick(() => this.removeFile(index))
    }
    .width('100%').alignItems(VerticalAlign.Center)
    .padding({ left: Dt.spaceMd, right: Dt.spaceSm, top: Dt.spaceSm, bottom: Dt.spaceSm })
    .borderRadius(Dt.radiusMd)
    .backgroundColor($r('app.color.app_background'))
  }

  @Builder
  FileListPane() {
    GlassCard({ radius: Dt.radiusXl, paddingV: 0 }) {
      Column({ space: Dt.spaceSm }) {
        Column({ space: 4 }) {
          Text(`文件队列 · ${this.files.length}`)
            .fontSize(Dt.fontSub).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary')).width('100%')
          Text('可调整处理顺序；合成操作只生成一个结果')
            .fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
        }.padding({ left: Dt.spaceLg, right: Dt.spaceLg, top: Dt.spaceLg, bottom: Dt.spaceSm })
        List({ space: Dt.spaceSm }) {
          ForEach(this.files, (file: PickedFile, index: number) => {
            ListItem() {
              this.FileRow(file, index)
            }
          }, (file: PickedFile, index: number) =>
            `${file.uri}_${index}_${this.files.length}_${this.fileThumbs.has(file.uri) ? '1' : '0'}`)
        }
        .width('100%').height(this.fileListViewportHeight()).scrollBar(BarState.Auto)
        .padding({ left: Dt.spaceSm, right: Dt.spaceSm, bottom: Dt.spaceSm })
      }.alignItems(HorizontalAlign.Start).width('100%')
    }
  }

  private fileListViewportHeight(): number {
    const visible = Math.max(1, Math.min(this.files.length, 4));
    return visible * Dt.listRowHeight + Math.max(0, visible - 1) * Dt.spaceSm + Dt.spaceSm;
  }

  private filePaneWidth(): number {
    return Math.min(420, Math.max(Dt.fileListW, Math.floor(this.windowWidthVp * 0.34)));
  }

  @Builder
  ResultPreviewPane() {
    if (BatchResultPreview.supports(this.pendingTitle)) {
      Column({ space: Dt.spaceSm }) {
        Row() {
          Text('成品预览')
            .fontSize(Dt.fontCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          if (this.previewBusy) {
            LoadingProgress().width(18).height(18)
          }
        }
        .width('100%')
        if (this.resultPreview !== undefined) {
          Image(this.resultPreview)
            .width('100%')
            .height(220)
            .objectFit(ImageFit.Contain)
            .backgroundColor('#16000000')
            .borderRadius(Dt.radiusMd)
        } else {
          Column({ space: Dt.spaceSm }) {
            LoadingProgress().width(28).height(28)
            Text('正在生成预览')
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%').height(160).justifyContent(FlexAlign.Center)
          .borderRadius(Dt.radiusMd).backgroundColor('#10000000')
        }
        if (this.previewNote.length > 0) {
          Text(this.previewNote)
            .fontSize(Dt.fontCaption)
            .fontColor(this.previewNote.startsWith('预览失败') ?
              $r('app.color.danger_red') : $r('app.color.text_secondary'))
            .width('100%')
        }
      }
      .width('100%')
      .padding(Dt.spaceMd)
      .borderRadius(Dt.radiusLg)
      .backgroundColor($r('app.color.app_background'))
    }
  }

  @Builder
  ConfigCard() {
    if (this.pendingTitle.length > 0) {
      Column({ space: Dt.spaceMd }) {
        Row({ space: Dt.spaceSm }) {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_backward')).fontSize(17)
              .fontColor([$r('app.color.text_primary')])
          }
          .type(ButtonType.Circle).width(36).height(36).buttonStyle(ButtonStyleMode.NORMAL)
          .onClick(() => this.closeConfig())
          Column({ space: 2 }) {
            Text(this.pendingTitle).fontSize(Dt.fontSub).fontWeight(FontWeight.Medium).width('100%')
            Text('确认成品效果与参数后开始导出')
              .fontSize(Dt.fontCaption).fontColor($r('app.color.text_secondary')).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        this.ResultPreviewPane()
        if (['批量转 WebP', '批量压缩图片', '批量缩放'].includes(this.pendingTitle)) {
          Text(`图片编码质量 ${Math.round(this.qualityValue)}`).fontSize(Dt.fontCaption).width('100%')
          Slider({ value: this.qualityValue, min: 1, max: 100, step: 1 })
            .onChange((v: number) => {
              this.qualityValue = v;
              this.scheduleResultPreview();
            })
        }
        if (this.pendingTitle.includes('缩放') || this.pendingTitle.includes('拼接')) {
          Text('图片长边上限 px').fontSize(Dt.fontCaption).width('100%')
          TextInput({ text: this.dimensionText }).type(InputType.Number)
            .onChange((v: string) => {
              this.dimensionText = v;
              this.scheduleResultPreview();
            })
        }
        if (this.pendingTitle.includes('水印')) {
          Text('水印宽度 / 自定义 X、Y').fontSize(Dt.fontCaption).width('100%')
          TextInput({ text: this.watermarkWidthText }).type(InputType.Number)
            .onChange((v: string) => this.watermarkWidthText = v)
          TextInput({ text: this.watermarkXText }).type(InputType.Number)
            .onChange((v: string) => this.watermarkXText = v)
          TextInput({ text: this.watermarkYText }).type(InputType.Number)
            .onChange((v: string) => this.watermarkYText = v)
        }
        if (this.pendingTitle.includes('图片生成')) {
          Text('每张图片停留秒数').fontSize(Dt.fontCaption).width('100%')
          TextInput({ text: this.holdText }).type(InputType.Number)
            .onChange((v: string) => {
              this.holdText = v;
              this.restartFramePreview();
            })
          Text('输出帧率').fontSize(Dt.fontCaption).width('100%')
          TextInput({ text: this.fpsText }).type(InputType.Number)
            .onChange((v: string) => this.fpsText = v)
        }
        if (this.pendingTitle.includes('字幕延迟') || this.pendingTitle.includes('字幕提前')) {
          Text('时间偏移（毫秒）').fontSize(Dt.fontCaption).width('100%')
          TextInput({ text: this.subtitleOffsetText }).type(InputType.Number)
            .onChange((v: string) => this.subtitleOffsetText = v)
        }
        Text(this.pendingDescription).fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary')).width('100%')
        Row({ space: 12 }) {
          Button('返回处理方式').buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
            .onClick(() => this.closeConfig())
          Button('开始导出').layoutWeight(1).enabled(!this.busy).onClick(() => this.startConfigured())
        }.width('100%')
      }.padding(Dt.spaceLg).borderRadius(Dt.radiusLg).backgroundColor($r('app.color.surface_card'))
        .width('100%')
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 18 })),
          TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 10 }))
        ).animation({ duration: 240, curve: Curve.EaseOut }))
    }
  }

  @Builder
  ToolsList() {
    if (this.allImages()) {
      this.ActionButton(ToolSymbol.IMAGE, '横向拼接图片', '统一高度后按顺序拼接为 PNG',
        () => this.enqueueCombined('image_stack_horizontal', '横向拼接图片', this.files, {
          targetWidth: Math.round(this.numberValue(this.dimensionText, 1920, 16, 32768))
        }))
      this.ActionButton(ToolSymbol.IMAGE, '纵向拼接图片', '统一宽度后按顺序拼接为 PNG',
        () => this.enqueueCombined('image_stack_vertical', '纵向拼接图片', this.files, {
          targetWidth: Math.round(this.numberValue(this.dimensionText, 1920, 16, 32768))
        }))
      this.ActionButton(ToolSymbol.CONVERT, '批量转 WebP', '每个文件分别输出 WebP',
        () => this.enqueueSimpleBatch('image_convert', '批量转 WebP'))
      this.ActionButton(ToolSymbol.COMPRESS, '批量压缩图片', '自定义 JPEG 编码质量',
        () => this.enqueueSimpleBatch('image_compress', '批量压缩图片'))
      this.ActionButton(ToolSymbol.RESIZE, '批量缩放', '设置图片长边上限', () => this.enqueueImageResize())
      this.ActionButton(ToolSymbol.VIDEO, '图片生成视频', '设置停留时长和帧率，输出 MP4',
        () => this.enqueueCombined('images_to_video', '图片生成视频', this.files, {
          durationSeconds: `${this.numberValue(this.holdText, 2, 0.1, 3600)}`,
          targetFps: Math.round(this.numberValue(this.fpsText, 30, 1, 120))
        }))
      this.ActionButton(ToolSymbol.GIF, '图片生成 GIF', '设置停留时长和帧率，生成动画',
        () => this.enqueueCombined('images_to_gif', '图片生成 GIF', this.files, {
          durationSeconds: `${this.numberValue(this.holdText, 2, 0.1, 3600)}`,
          targetFps: Math.round(this.numberValue(this.fpsText, 12, 1, 30))
        }))
    }
    if (this.allOf(MediaType.VIDEO)) {
      this.ActionButton(ToolSymbol.COMPRESS, '批量智能压缩', '逐个分析后使用原生硬件转码',
        () => this.enqueueVideoCompress())
      this.ActionButton(ToolSymbol.EDIT, '合并视频', '按选择顺序重新编码为一个 MP4',
        () => this.enqueueVideoMerge())
      this.ActionButton(ToolSymbol.EDIT, '尝试无损合并', '参数完全一致时直接复制媒体流',
        () => this.enqueueLosslessVideoMerge())
    }
    if (this.allOf(MediaType.AUDIO)) {
      this.ActionButton(ToolSymbol.AUDIO, '合并音频', '按选择顺序输出一个 M4A',
        () => this.enqueueCombined('audio_merge', '合并音频', this.files))
    }
    if (this.videoAndAudio()) {
      this.ActionButton(ToolSymbol.AUDIO, '替换视频音轨', '使用所选音频替换原音轨',
        () => this.enqueueReplaceAudio())
    }
    if (this.imageAndAudio()) {
      this.ActionButton(ToolSymbol.VIDEO, '图片与音频生成视频', '静态画面持续到音频结束',
        () => this.enqueueImageAudio())
      this.ActionButton(ToolSymbol.IMAGE, '写入音频封面', '图片编码为 JPEG 并写入封面流',
        () => this.enqueueCoverArt())
    }
    if (this.videoAndImage()) {
      this.ActionButton(ToolSymbol.IMAGE, '添加视频水印', '自定义水印位置与尺寸',
        () => this.enqueueVideoWatermark())
      if (DeviceSupport.movingPhoto().canCreateMovingPhoto) {
        Column({ space: Dt.spaceSm }) {
          Text('创建 HarmonyOS 动态照片').fontSize(Dt.fontBody).fontWeight(FontWeight.Medium)
          Text('图片 + MP4，通过系统安全控件保存').fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Capsule })
            .enabled(!this.busy)
            .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => this.saveMovingPhoto(result))
        }
        .alignItems(HorizontalAlign.Start).width('100%').padding(Dt.spaceLg)
        .borderRadius(Dt.radiusLg).backgroundColor($r('app.color.surface_card'))
      }
    }
    if (this.videoAndSubtitle()) {
      this.ActionButton(ToolSymbol.FILE, '封装字幕轨', '复制音视频流并添加可关闭字幕',
        () => this.enqueueSubtitle('subtitle_mux', '封装字幕轨'))
      this.ActionButton(ToolSymbol.EDIT, '烧录字幕', '将字幕永久写入画面',
        () => this.enqueueSubtitle('subtitle_burn', '烧录字幕'))
    }
    if (this.allOf(MediaType.SUBTITLE)) {
      this.ActionButton(ToolSymbol.EDIT, '批量字幕延迟', '批量调整字幕时间轴', () => {
        const uris = this.files.map((f: PickedFile) => f.uri);
        const names = this.files.map((f: PickedFile) => f.displayName);
        WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue(uris, names, 'subtitle_shift_delay', '批量字幕延迟', {
          subtitleDelaySeconds: this.numberValue(this.subtitleOffsetText, 500, 0, 86400000) / 1000
        });
        TaskNavigation.showRootQueue();
      })
      this.ActionButton(ToolSymbol.EDIT, '批量字幕提前', '批量调整字幕时间轴', () => {
        const uris = this.files.map((f: PickedFile) => f.uri);
        const names = this.files.map((f: PickedFile) => f.displayName);
        WorkbenchSession.lastTaskIds = TaskQueue.getInstance().enqueue(uris, names, 'subtitle_shift_advance', '批量字幕提前', {
          subtitleDelaySeconds: -this.numberValue(this.subtitleOffsetText, 500, 0, 86400000) / 1000
        });
        TaskNavigation.showRootQueue();
      })
    }
    if (!this.allImages() && !this.allOf(MediaType.VIDEO) && !this.allOf(MediaType.AUDIO) &&
      !this.videoAndAudio() && !this.imageAndAudio() && !this.videoAndSubtitle() &&
      !this.videoAndImage() && !this.allOf(MediaType.SUBTITLE)) {
      Text('当前文件组合没有可用的批处理或合成操作')
        .fontSize(Dt.fontBody).fontColor($r('app.color.text_secondary')).padding(Dt.spaceXl).width('100%')
    }
  }

  @Builder
  WorkflowPane() {
    if (this.pendingTitle.length > 0) {
      this.ConfigCard()
    } else {
      Column({ space: Dt.spaceMd }) {
        Column({ space: 4 }) {
          Text('选择处理方式')
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('选择后先预览成品和调整参数，不会立即创建任务')
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .padding({ left: Dt.spaceXs, right: Dt.spaceXs, bottom: Dt.spaceXs })
        this.ToolsList()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: -18 })),
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: -10 }))
      ).animation({ duration: 240, curve: Curve.EaseOut }))
    }
  }

  @Builder
  WideFilePane() {
    Column() {
      this.FileListPane()
    }
    .width(this.filePaneWidth())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  WideControlPane() {
    Scroll() {
      Column() {
        this.WorkflowPane()
      }
      .width('100%')
      .padding({ bottom: Dt.spaceXxl })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .height('100%')
  }

  build() {
    if (Adaptive.useSideTabs(this.windowWidthVp, this.isLandscape, this.windowHeightVp) ||
      Adaptive.breakpoint(this.windowWidthVp) === Breakpoint.LG) {
      Row({ space: Dt.spaceLg }) {
        if (this.controlsOnLeft) {
          this.WideControlPane()
          this.WideFilePane()
        } else {
          this.WideFilePane()
          this.WideControlPane()
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Top)
      .padding({
        left: Dt.navContentInset,
        right: Adaptive.pagePadding(this.windowWidthVp),
        top: 96,
        bottom: Dt.spaceLg
      })
    } else {
      Scroll(this.pageScroller) {
        Column({ space: Dt.spaceMd }) {
          this.FileListPane()
          this.WorkflowPane()
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
    }
  }
}
