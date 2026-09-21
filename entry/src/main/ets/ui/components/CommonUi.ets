/**
 * 与 docs/ui-preview/index.html 对齐的通用 UI 片段。
 */
import { ToolSymbol } from '../../core/model/MediaTypes';
import { SystemSymbolIcon } from './SystemSymbolIcon';
import { Dt } from '../theme/DesignTokens';
import { image } from '@kit.ImageKit';
import { MediaType } from '../../core/model/MediaTypes';

@Builder
function emptyShadowContent() {
}

/** 轻阴影卡片容器 */
@Component
export struct ShadowCard {
  @BuilderParam content: () => void = emptyShadowContent;
  @Prop radius: number = Dt.radiusLg;
  @Prop paddingV: number = Dt.spaceLg;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(this.paddingV)
    .borderRadius(this.radius)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({ radius: 24, color: '#0F101814', offsetX: 0, offsetY: 8 })
    .clip(true)
  }
}

/** 分区标题 */
@Component
export struct SectionHeader {
  @Prop title: string = '';
  @Prop caption: string = '';

  build() {
    Row({ space: Dt.spaceMd }) {
      Text(this.title)
        .fontSize(Dt.fontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      if (this.caption.length > 0) {
        Text(this.caption)
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ top: Dt.spaceXl, bottom: Dt.spaceMd })
  }
}

/** 工作台/批量「操作行」：图标 + 标题/副标题 + 箭头 */
@Component
export struct ActionRow {
  @Prop icon: ToolSymbol = ToolSymbol.FILE;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop badge: string = '';
  @Prop badgeGreen: boolean = false;
  @Prop trail: string = '';
  @Prop rowEnabled: boolean = true;
  onActivate: () => void = () => {
  };

  build() {
    Row({ space: Dt.spaceMd }) {
      Row() {
        SystemSymbolIcon({
          name: this.icon,
          iconSize: 20,
          color: this.badgeGreen ? $r('app.color.lossless_green') : $r('app.color.accent')
        })
      }
      .width(Dt.iconBox)
      .height(Dt.iconBox)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(Dt.radiusMd)
      .backgroundColor(this.badgeGreen ? $r('app.color.lossless_green_soft') : $r('app.color.accent_soft'))

      Column({ space: 2 }) {
        Row({ space: Dt.spaceSm }) {
          Text(this.title)
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          if (this.badge.length > 0) {
            Text(this.badge)
              .fontSize(11)
              .fontColor(this.badgeGreen ? $r('app.color.lossless_green') : $r('app.color.accent'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor(this.badgeGreen ? $r('app.color.lossless_green_soft') : $r('app.color.accent_soft'))
          }
        }
        .alignItems(VerticalAlign.Center)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.trail.length > 0) {
        Text(this.trail)
          .fontSize(Dt.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.lossless_green'))
      } else if (this.rowEnabled) {
        SystemSymbolIcon({ name: ToolSymbol.CHEVRON, iconSize: 16, color: $r('app.color.text_tertiary') })
      }
    }
    .width('100%')
    .padding(Dt.spaceLg)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({ radius: 24, color: '#0F101814', offsetX: 0, offsetY: 8 })
    .opacity(this.rowEnabled ? 1 : 0.55)
    .onClick(() => {
      if (this.rowEnabled) {
        this.onActivate();
      }
    })
  }
}

/** 键值信息行 */
@Component
export struct KeyValueRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_secondary'))
        .width(96)
        .flexShrink(0)
      Text(this.value)
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
  }
}

/** 胶囊操作按钮 */
@Component
export struct CapsuleButton {
  @Prop label: string = '';
  @Prop emphasized: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Button(this.label)
      .type(ButtonType.Capsule)
      .height(Dt.btnHeight)
      .buttonStyle(this.emphasized ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
      .onClick(() => this.onTap())
  }
}
