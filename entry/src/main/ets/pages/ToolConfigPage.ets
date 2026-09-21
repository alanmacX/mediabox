/**
 * 工具配置二级页。
 *
 * 1. 预览只在工作台出现一次，本页不再复制大图。
 * 2. 竖屏：单列表单。
 * 3. 横屏：操作 card + 预览 card 双栏；仅本页按惯用手左右对调，带动画。
 *    右手（默认）：预览左、操作右；左手：操作左、预览右。
 *    主页等其他页面不跟手。
 */
import { AnalyzedMedia, MediaType, ToolAction } from '../core/model/MediaTypes';
import { TaskParams } from '../core/task/MediaTask';
import { TaskQueue } from '../core/task/TaskQueue';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { GlassCard } from '../ui/components/GlassCard';
import { MediaPreview } from '../ui/components/MediaPreview';
import { MediaThumb } from '../core/media/MediaThumb';
import { WorkbenchSession, RouteNames } from '../ui/components/WorkbenchSession';
import { TaskNavigation } from '../ui/components/TaskNavigation';
import { ActionConfigPanel, usesSimpleConfig } from '../ui/components/ActionConfigPanel';
import { AdjustmentPanel, hasAdjustmentPanel } from '../ui/components/AdjustmentPanel';
import { AudioAdjustmentPanel, hasAudioAdjustment } from '../ui/components/AudioAdjustmentPanel';
import { native1080pDimensions, targetSizeBudget } from '../core/engine/CapabilityRouter';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';

@Component
export struct ToolConfigPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  /**
   * Navigation 内容槽的实测宽度。不能用全局窗口宽度：宽屏根页有侧栏、
   * 二级页切换时侧栏又会退出，二者会让固定双栏的右侧越出实际容器。
   */
  @State contentWidthVp: number = 0;
  /** 惯用手变化时对调操作/预览 card（仅本页）。 */
  @StorageProp('preferredHand') @Watch('onPreferredHandChange') preferredHand: string = 'right';
  /** true = 操作 card 在左。 */
  @State formOnLeft: boolean = false;
  @State media: AnalyzedMedia | undefined = WorkbenchSession.result?.media;
  @State thumbnail: image.PixelMap | undefined = WorkbenchSession.thumbnail ??
    WorkbenchSession.result?.thumbnail;
  @State previewUri: string = WorkbenchSession.previewUri ?? '';
  @State action: ToolAction | undefined = WorkbenchSession.pendingAction;
  @State targetSizeText: string = '25';
  @State targetSizeError: string = '';

  aboutToAppear(): void {
    // 每次进入配置页重新对齐会话，避免复用实例时 media/action 过期
    this.media = WorkbenchSession.result?.media;
    this.thumbnail = WorkbenchSession.thumbnail ?? WorkbenchSession.result?.thumbnail;
    this.previewUri = WorkbenchSession.previewUri ?? '';
    this.action = WorkbenchSession.pendingAction;
    this.formOnLeft = this.preferredHand === 'left';
    this.ensureThumbnail();
  }

  /** 配置页预览窗必须有画面：缺缩略图时现场补（动态照片=系统关键帧）。 */
  private ensureThumbnail(): void {
    const m = this.media;
    if (m === undefined || this.thumbnail !== undefined ||
      !MediaThumb.wantsPreview(m.mediaType, m.isMovingPhoto)) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MediaThumb.load(m, context, 0).then((pm: image.PixelMap | undefined) => {
      if (pm !== undefined && this.media !== undefined && this.media.uri === m.uri) {
        MediaThumb.cachePreview(pm, context).then((uri: string) => {
          if (this.media !== undefined && this.media.uri === m.uri) {
            this.previewUri = uri;
            WorkbenchSession.previewUri = uri;
          }
        }).catch(() => {
          // 退回 PixelMap 渲染
        });
        this.thumbnail = pm;
        WorkbenchSession.thumbnail = pm;
      }
    }).catch(() => {
      // 预览失败不影响表单
    });
  }

  private onPreferredHandChange(): void {
    const wantLeft = this.preferredHand === 'left';
    if (wantLeft === this.formOnLeft) {
      return;
    }
    this.getUIContext().animateTo({
      duration: 360,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.formOnLeft = wantLeft;
    });
  }

  private goBack(): void {
    if (this.pathStack.size() > 0) {
      const _popped = this.pathStack.pop();
    }
  }

  /** 严格校验目标体积（MB）：不静默改写非法输入。 */
  private parseTargetMb(): number {
    const raw = this.targetSizeText.trim();
    if (raw.length === 0) {
      this.targetSizeError = '请输入目标体积';
      throw new Error('请输入目标体积');
    }
    const n = Number(raw);
    if (!Number.isFinite(n)) {
      this.targetSizeError = '请输入有效数字';
      throw new Error('请输入有效数字');
    }
    if (n < 0.1) {
      this.targetSizeError = '目标体积至少 0.1 MB';
      throw new Error('目标体积至少 0.1 MB');
    }
    if (n > 8192) {
      this.targetSizeError = '目标体积过大（上限 8192 MB）';
      throw new Error('目标体积过大');
    }
    this.targetSizeError = '';
    return n;
  }

  private enqueueAndGoTasks(actionId: string, title: string, params: TaskParams): void {
    const m = this.media;
    if (m === undefined) {
      return;
    }
    WorkbenchSession.saveDraft(m.uri, actionId, params);
    const ids = TaskQueue.getInstance().enqueue([m.uri], [m.displayName], actionId, title, params);
    WorkbenchSession.lastTaskIds = ids;
    this.goBack();
    TaskNavigation.showRootQueue();
  }

  private enqueueTargetSize(): void {
    const m = this.media;
    const action = this.action;
    if (m === undefined || action === undefined) {
      return;
    }
    let targetMb: number;
    try {
      targetMb = this.parseTargetMb();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: this.targetSizeError });
      return;
    }
    const targetBytes = Math.round(targetMb * 1024 * 1024);
    if (action.id === 'gif_target_size' || m.mediaType === MediaType.GIF) {
      this.enqueueAndGoTasks(action.id, action.title, {
        targetBytes: targetBytes,
        targetFps: 15,
        targetWidth: 640,
        paletteColors: 256,
        loopCount: '0'
      });
      return;
    }
    if (m.mediaType === MediaType.VIDEO && m.video !== undefined) {
      if (m.durationMs <= 0) {
        this.getUIContext().getPromptAction().showToast({ message: '无法读取时长，无法计算目标体积' });
        return;
      }
      const budget = targetSizeBudget(m, targetBytes);
      if (budget.videoKbps < 80) {
        this.getUIContext().getPromptAction().showToast({ message: '目标体积过小，请增大后重试' });
        return;
      }
      const dims = native1080pDimensions(m.video.width, m.video.height);
      this.enqueueAndGoTasks(action.id, action.title, {
        targetVideoKbps: budget.videoKbps,
        targetAudioKbps: budget.audioKbps || 128,
        targetWidth: dims.width,
        targetHeight: dims.height,
        targetContainer: 'MP4',
        targetBytes: targetBytes
      });
      return;
    }
    this.enqueueAndGoTasks(action.id, action.title, {
      imageQuality: 70,
      targetWidth: Math.max(1, Math.round(m.imageWidth * 0.7)),
      targetHeight: Math.max(1, Math.round(m.imageHeight * 0.7)),
      targetBytes: targetBytes
    });
  }

  private useTwoColumn(): boolean {
    // 双栏至少为操作栏 280 + 预览栏 240 + 栏距；不足时回退单列，
    // 不以横屏为由强行塞入两张固定宽 card。
    return this.pageContentWidth() >= 536;
  }

  private pageContentWidth(): number {
    const containerWidth = this.contentWidthVp > 0 ? this.contentWidthVp : this.windowWidthVp;
    return Math.max(0, containerWidth - Dt.navContentInset - Adaptive.pagePadding(containerWidth));
  }

  private formPaneWidth(): number {
    // 宽屏沿用 400vp；临界宽度时等比例收缩，保证另一栏和栏距都保留。
    return Math.min(Dt.formPaneW, Math.max(280, Math.floor(this.pageContentWidth() * 0.46)));
  }

  private previewPaneWidth(): number {
    return Math.max(240, this.pageContentWidth() - this.formPaneWidth() - Dt.spaceLg);
  }

  @Builder
  FileCaption() {
    if (this.media !== undefined) {
      Text(this.media.displayName)
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: Dt.spaceMd })
    }
  }

  @Builder
  TargetSizeForm() {
    Column({ space: Dt.spaceMd }) {
      Text('目标体积')
        .fontSize(Dt.fontBody)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Row({ space: Dt.spaceSm }) {
        TextInput({ text: this.targetSizeText, placeholder: '例如 25' })
          .type(InputType.Number)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.targetSizeText = value;
            this.targetSizeError = '';
          })
        Text('MB')
          .fontSize(Dt.fontBody)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      if (this.targetSizeError.length > 0) {
        Text(this.targetSizeError)
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.danger_red'))
          .width('100%')
      }
      Text('允许 0.1–8192 MB；实际体积以导出结果为准')
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Button('开始导出')
        .width('100%')
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => this.enqueueTargetSize())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  FormBody() {
    if (this.action === undefined || this.media === undefined) {
      Text('未选择工具参数，请返回工作台重新选择')
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding(Dt.spaceXxl)
    } else if (hasAudioAdjustment(this.action.id)) {
      AudioAdjustmentPanel({
        mediaInfo: this.media,
        action: this.action,
        onClose: (): void => this.goBack(),
        onSubmit: (params: TaskParams): void => {
          const a = this.action;
          if (a !== undefined) {
            this.enqueueAndGoTasks(a.id, a.title, params);
          }
        }
      })
    } else if (hasAdjustmentPanel(this.action.id)) {
      AdjustmentPanel({
        mediaInfo: this.media,
        action: this.action,
        showPreview: !this.useTwoColumn(),
        onClose: (): void => this.goBack(),
        onSubmit: (params: TaskParams): void => {
          const a = this.action;
          if (a !== undefined) {
            this.enqueueAndGoTasks(a.id, a.title, params);
          }
        }
      })
    } else if (usesSimpleConfig(this.action.id)) {
      ActionConfigPanel({
        action: this.action,
        mediaInfo: this.media,
        onClose: (): void => this.goBack(),
        onSubmit: (): void => {
          this.goBack();
          TaskNavigation.showRootQueue();
        }
      })
    } else {
      GlassCard({ radius: Dt.radiusLg, paddingV: Dt.spaceXl }) {
        this.TargetSizeForm()
      }
    }
  }

  @Builder
  FormCard() {
    Column({ space: Dt.spaceMd }) {
      this.FileCaption()
      this.FormBody()
    }
    .width(this.formPaneWidth())
    .alignItems(HorizontalAlign.Start)
    .translate({
      x: this.formOnLeft ? 0 : this.previewPaneWidth() + Dt.spaceLg
    })
  }

  @Builder
  PreviewCard() {
    Column() {
      MediaPreview({
        media: this.media,
        thumbnail: this.thumbnail,
        previewUri: this.previewUri,
        heightVp: 360
      })
      if (this.action !== undefined && this.action.subtitle.length > 0) {
        Text(this.action.subtitle)
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: Dt.spaceSm })
      } else {
        Text('编码质量与 HDR 以导出结果为准')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: Dt.spaceSm })
      }
    }
    .width(this.previewPaneWidth())
    .alignItems(HorizontalAlign.Start)
    .translate({
      x: this.formOnLeft ? this.formPaneWidth() + Dt.spaceLg : 0
    })
  }

  build() {
    Scroll() {
      if (this.useTwoColumn()) {
        // 固定槽位 + translate：惯用手变化时两张 card 滑动对调
        Stack({ alignContent: Alignment.TopStart }) {
          this.PreviewCard()
          this.FormCard()
        }
        .width('100%')
        .constraintSize({ minHeight: 480 })
      } else {
        Column({ space: 0 }) {
          this.FileCaption()
          this.FormBody()
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .padding({
      left: Dt.navContentInset,
      right: Adaptive.pagePadding(this.contentWidthVp > 0 ? this.contentWidthVp : this.windowWidthVp),
      top: 96,
      bottom: Dt.spaceXxl
    })
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onAreaChange((_old: Area, area: Area): void => {
      const width = Number(area.width);
      if (width > 0 && Math.abs(width - this.contentWidthVp) > 0.5) {
        this.contentWidthVp = width;
      }
    })
  }
}
