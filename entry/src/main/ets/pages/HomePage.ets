/**
 * 首页 — File First：先选文件，再出工具。
 * 通用入口保留；类型区使用 MediaDeck（叠放 / 滑动，原生动画）。
 * 文案与原先一致。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { MediaType } from '../core/model/MediaTypes';
import { MediaPickerService, MediaPickMode } from '../core/media/MediaPickerService';
import { MediaAnalyzer, guessMediaType, PickedFile } from '../core/analyze/MediaAnalyzer';
import { WorkbenchSession, RouteNames } from '../ui/components/WorkbenchSession';
import { MediaDeck } from '../ui/components/MediaDeck';
import { ImmersiveRootHeader } from '../ui/components/ImmersiveRootHeader';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { Immersive } from '../ui/theme/HdsKit';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';
import { ToolSymbol } from '../core/model/MediaTypes';
import { DeviceSupport } from '../core/capability/DeviceSupport';
import { MediaInputStore } from '../core/media/MediaInputStore';

@CustomDialog
struct DocumentDialog {
  controller?: CustomDialogController;
  @State title: string = '';
  @State content: string = '';

  /** 行内 **粗体** 标记剥离（简化渲染）。 */
  private mdPlain(line: string): string {
    return line.replace(/\*\*/g, '');
  }

  private mdLines(): string[] {
    return this.content.split('\n').filter((l: string): boolean => !l.startsWith('# '));
  }

  /** 轻量 Markdown 排版：小节标题 / 列表 / 段落，层级清晰。 */
  @Builder
  MdBody() {
    ForEach(this.mdLines(), (line: string, idx: number) => {
      if (line.startsWith('## ')) {
        Text(this.mdPlain(line.substring(3)))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: idx === 1 ? 0 : 14 })
      } else if (line.startsWith('- ')) {
        Row({ space: 8 }) {
          Column()
            .width(4)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.accent'))
            .margin({ top: 8 })
          Text(this.mdPlain(line.substring(2)))
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
      } else if (line.trim().length === 0) {
        Column().height(4)
      } else {
        Text(this.mdPlain(line))
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
      }
    }, (line: string, idx: number) => `${idx}_${line.length}`)
  }

  build() {
    Column({ space: Dt.spaceMd }) {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Column()
        .width('100%')
        .height(1)
        .backgroundColor($r('app.color.divider'))
      Scroll() {
        Column() {
          this.MdBody()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .constraintSize({ maxHeight: '56%' })
      .width('100%')
      .scrollBar(BarState.Off)
      Button('关闭')
        .width('100%')
        .height(Dt.btnHeight)
        .type(ButtonType.Capsule)
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .onClick(() => this.controller?.close())
    }
    .alignItems(HorizontalAlign.Start)
    .padding(Dt.spaceXl)
    .borderRadius(Dt.radiusXl)
    .backgroundColor($r('app.color.surface_card'))
  }
}

@Component
export struct HomePage {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('safeRightVp') safeRightVp: number = 0;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @State picking: boolean = false;
  @State dialogTitle: string = '';
  @State dialogContent: string = '';
  dialogController: CustomDialogController = new CustomDialogController({
    builder: DocumentDialog({
      title: this.dialogTitle, content: this.dialogContent
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  /** 折叠外屏常见的宽矮竖屏：底栏会明显侵占牌堆的可视高度。 */
  private compactPortrait(): boolean {
    return !this.isLandscape && this.windowWidthVp >= 420 && this.windowHeightVp > 0 &&
      this.windowHeightVp / this.windowWidthVp < 1.62;
  }

  private fileType(file: PickedFile): MediaType {
    return file.mediaTypeHint ?? guessMediaType(file.displayName);
  }

  private accepts(file: PickedFile, mode: MediaPickMode): boolean {
    if (mode === MediaPickMode.AUTO) {
      return this.fileType(file) !== MediaType.UNKNOWN;
    }
    if (mode === MediaPickMode.MOVING_PHOTO) {
      return file.isMovingPhoto === true;
    }
    return this.fileType(file) === this.mediaTypeForMode(mode);
  }

  private mediaTypeForMode(mode: MediaPickMode): MediaType {
    switch (mode) {
      case MediaPickMode.VIDEO:
        return MediaType.VIDEO;
      case MediaPickMode.IMAGE:
      case MediaPickMode.MOVING_PHOTO:
        return MediaType.IMAGE;
      case MediaPickMode.GIF:
        return MediaType.GIF;
      case MediaPickMode.AUDIO:
        return MediaType.AUDIO;
      case MediaPickMode.SUBTITLE:
        return MediaType.SUBTITLE;
      default:
        return MediaType.UNKNOWN;
    }
  }

  private modeLabel(mode: MediaPickMode): string {
    switch (mode) {
      case MediaPickMode.VIDEO:
        return '视频';
      case MediaPickMode.IMAGE:
        return '图片';
      case MediaPickMode.GIF:
        return 'GIF';
      case MediaPickMode.AUDIO:
        return '音频';
      case MediaPickMode.SUBTITLE:
        return '字幕';
      case MediaPickMode.MOVING_PHOTO:
        return '动态照片';
      default:
        return '媒体';
    }
  }

  private async handlePicked(files: PickedFile[], mode: MediaPickMode): Promise<void> {
    for (const file of files) {
      if (this.fileType(file) === MediaType.UNKNOWN) {
        const detected = await MediaAnalyzer.detectMediaType(file);
        file.mediaTypeHint = detected === MediaType.UNKNOWN ? undefined : detected;
      }
    }
    const accepted = files.filter((file: PickedFile) => this.accepts(file, mode));
    const rejected = files.length - accepted.length;
    if (rejected > 0) {
      const message = mode === MediaPickMode.MOVING_PHOTO ?
        `已忽略 ${rejected} 个非动态照片文件` :
        (mode === MediaPickMode.AUTO ? `有 ${rejected} 个文件无法识别` :
          `已忽略 ${rejected} 个非${this.modeLabel(mode)}文件`);
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
    if (accepted.length === 0) {
      if (mode === MediaPickMode.MOVING_PHOTO) {
        this.getUIContext().getPromptAction().showToast({
          message: DeviceSupport.movingPhoto().available ?
            '未选择到动态照片，请在图库中选择带动态标识的照片' :
            (DeviceSupport.movingPhoto().reason ?? '当前设备不支持动态照片')
        });
      }
      return;
    }
    if (accepted.length > 1) {
      WorkbenchSession.clear();
      WorkbenchSession.pickedFiles = accepted;
      WorkbenchSession.batchIntent = mode;
      this.pathStack.pushPathByName(RouteNames.BATCH, mode);
      return;
    }
    WorkbenchSession.clear();
    WorkbenchSession.picked = accepted[0];
    this.pathStack.pushPathByName(RouteNames.WORKBENCH, mode);
  }

  private async pickFromGallery(mode: MediaPickMode): Promise<void> {
    if (this.picking) {
      return;
    }
    if (mode === MediaPickMode.MOVING_PHOTO) {
      const mp = DeviceSupport.movingPhoto();
      if (!mp.available || !mp.canExportMovingPhoto) {
        this.getUIContext().getPromptAction().showToast({
          message: mp.reason ?? '当前设备不支持动态照片导出'
        });
        return;
      }
    }
    this.picking = true;
    try {
      const files = await MediaPickerService.pickPhotos(50, mode);
      await this.handlePicked(files, mode);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `打开图库失败：${(e as Error).message}` });
    } finally {
      this.picking = false;
    }
  }

  private async pickFromFiles(mode: MediaPickMode): Promise<void> {
    if (this.picking) {
      return;
    }
    this.picking = true;
    try {
      const files = await MediaPickerService.pickDocuments(50, mode);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const localFiles = await MediaInputStore.materializeDocuments(context, files);
      await this.handlePicked(localFiles, mode);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `打开文件失败：${(e as Error).message}` });
    } finally {
      this.picking = false;
    }
  }

  private async showDocument(file: string, title: string): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const bytes = await context.resourceManager.getRawFileContent(file);
      this.dialogContent = util.TextDecoder.create('utf-8', { ignoreBOM: true })
        .decodeToString(new Uint8Array(bytes.buffer));
      this.dialogTitle = title;
      this.dialogController.open();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '无法读取文档内容' });
    }
  }

  @Builder
  AutoPickCard() {
    Row({ space: Dt.spaceMd }) {
      Row() {
        SystemSymbolIcon({ name: ToolSymbol.TARGET, iconSize: 20, color: $r('app.color.accent') })
      }
      .width(Dt.iconBox)
      .height(Dt.iconBox)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(Dt.radiusMd)
      .backgroundColor($r('app.color.accent_soft'))

      Column({ space: 2 }) {
        Text('选择媒体文件')
          .fontSize(Dt.fontSub)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('可多选')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 按钮上下排列，给左侧文案更多空间
      Column({ space: Dt.spaceSm }) {
        Button($r('app.string.home_pick_photo'))
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .type(ButtonType.Capsule)
          .height(Dt.btnHeight)
          .width('100%')
          .onClick(() => this.pickFromGallery(MediaPickMode.AUTO))
        Button($r('app.string.home_pick_files'))
          .buttonStyle(ButtonStyleMode.NORMAL)
          .type(ButtonType.Capsule)
          .height(Dt.btnHeight)
          .width('100%')
          .onClick(() => this.pickFromFiles(MediaPickMode.AUTO))
      }
      .width(148)
      .constraintSize({ maxWidth: 168 })
    }
    .width('100%')
    .padding(Dt.spaceLg)
    .borderRadius(Dt.radiusXl)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({ radius: 24, color: '#0F101814', offsetX: 0, offsetY: 8 })
  }

  @State legalMenuOpen: boolean = false;

  /** 右上角二级菜单（照搬性能页 bindContextMenu 逻辑）：隐私声明 / 开源许可。 */
  @Builder
  LegalMenuBuilder() {
    Menu() {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.doc_plaintext'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')]),
        content: '隐私声明'
      })
        .contentFont({ size: Dt.fontBody })
        .contentFontColor($r('app.color.text_primary'))
        .height(40)
        .borderRadius(Dt.radiusMd)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.legalMenuOpen = false;
          this.showDocument('privacy_statement.md', '隐私声明');
        })
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.doc_text'))
          .fontSize(16)
          .fontColor([$r('app.color.text_primary')]),
        content: '开源许可'
      })
        .contentFont({ size: Dt.fontBody })
        .contentFontColor($r('app.color.text_primary'))
        .height(40)
        .borderRadius(Dt.radiusMd)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.legalMenuOpen = false;
          this.showDocument('open_source_notices.md', '开源软件声明');
        })
    }
    .width(150)
    .padding(Dt.spaceSm)
    .borderRadius(Dt.radiusLg)
  }

  @Builder
  LegalMenuButton() {
    Button() {
      Row({ space: 3 }) {
        Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
        Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
        Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
    .type(ButtonType.Circle)
    .width(36)
    .height(36)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 1, color: $r('app.color.divider') })
    .onClick((): void => {
      this.legalMenuOpen = true;
    })
    .bindContextMenu(this.legalMenuOpen, this.LegalMenuBuilder, {
      placement: Placement.BottomRight,
      systemMaterial: Immersive.regular(),
      onDisappear: (): void => {
        this.legalMenuOpen = false;
      }
    })
  }

  @Builder
  BrandBlock() {
    ImmersiveRootHeader({
      title: '开始',
      trailing: (): void => {
        this.LegalMenuButton()
      }
    })
  }

  build() {
    Scroll() {
      Column({ space: 0 }) {
        this.BrandBlock()
        Column() {
          this.AutoPickCard()
        }
        .width('100%')
        .margin({ top: Dt.spaceSm })
        Column() {
          MediaDeck({
            onPickGallery: (mode: MediaPickMode): void => {
              this.pickFromGallery(mode);
            },
            onPickFiles: (mode: MediaPickMode): void => {
              this.pickFromFiles(mode);
            }
          })
        }
        .width('100%')
        // 竖屏把牌区从选择卡拉开；卡片尺寸由 MediaDeck 的可用高度自适应补足。
        .margin({
          top: this.isLandscape ? Dt.spaceMd : (this.compactPortrait() ? Dt.spaceSm : Dt.spaceXl)
        })
        // 横屏：牌区占满剩余高度（MediaDeck 内部量高定环缩放）
        .layoutWeight(this.isLandscape ? 1 : 0)
      }
      .width('100%')
      .height(this.isLandscape ? '100%' : undefined)
    }
    .padding({
      left: Adaptive.pagePadding(this.windowWidthVp) +
        Adaptive.sideTabInset(this.windowWidthVp, this.isLandscape, this.windowHeightVp),
      // 全屏窗口的右侧系统避让区（如折叠屏/自由窗菜单栏）也必须计入内容边距。
      right: Adaptive.pagePadding(this.windowWidthVp) + this.safeRightVp,
      // 安全区与标题留白由 ImmersiveRootHeader 负责
      top: 0,
      bottom: Adaptive.bottomTabInset(this.safeBottomVp, this.windowWidthVp, this.isLandscape,
        this.windowHeightVp)
    })
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
  }
}
