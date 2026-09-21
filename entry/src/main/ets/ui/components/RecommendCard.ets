/**
 * 工作台推荐卡片 — 普通 Row 卡片，可放在 Scroll/Column 中。
 */
import { ToolAction, ToolSymbol } from '../../core/model/MediaTypes';
import { Dt } from '../theme/DesignTokens';
import { SystemSymbolIcon } from './SystemSymbolIcon';

@Component
export struct RecommendCard {
  @Prop action: ToolAction | undefined;
  onRun: (action: ToolAction) => void = () => {
  };

  build() {
    Row({ space: Dt.spaceMd }) {
      Row() {
        SystemSymbolIcon({
          name: this.action?.icon ?? ToolSymbol.FILE,
          iconSize: 20,
          color: this.action?.lossless ? $r('app.color.lossless_green') : $r('app.color.accent')
        })
      }
      .width(Dt.iconBox)
      .height(Dt.iconBox)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(Dt.radiusMd)
      .backgroundColor(this.action?.lossless ? $r('app.color.lossless_green_soft') : $r('app.color.accent_soft'))

      Column({ space: 2 }) {
        Row({ space: Dt.spaceSm }) {
          Text(this.action?.title ?? '')
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.action?.lossless) {
            Text('无损')
              .fontSize(11)
              .fontColor($r('app.color.lossless_green'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor($r('app.color.lossless_green_soft'))
          }
          if (!this.action?.available) {
            Text(this.action?.statusLabel ?? '暂不可用')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(4)
          }
        }
        .alignItems(VerticalAlign.Center)
        .width('100%')

        Text(this.action?.subtitle ?? '')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if ((this.action?.estimatedSavingPct ?? 0) > 0) {
        Text(`-${this.action?.estimatedSavingPct}%`)
          .fontSize(Dt.fontBody)
          .fontColor($r('app.color.lossless_green'))
          .fontWeight(FontWeight.Medium)
      } else {
        SystemSymbolIcon({ name: ToolSymbol.CHEVRON, iconSize: 16, color: $r('app.color.text_tertiary') })
      }
    }
    .width('100%')
    .padding(Dt.spaceLg)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({
      radius: 24,
      color: '#0F101814',
      offsetX: 0,
      offsetY: 8
    })
    .opacity(this.action?.available === false ? 0.55 : 1)
    .onClick(() => {
      if (this.action !== undefined && this.action.available) {
        this.onRun(this.action);
      }
    })
  }
}
