/**
 * 根 Tab 沉浸式顶栏 — 对齐工具页 HdsNavDestination 视觉：
 * 透明底大标题 + 标题下方留白，避免内容贴边。
 */
import { Dt } from '../theme/DesignTokens';

@Builder
function EmptyTrailing() {
}

@Component
export struct ImmersiveRootHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  /** 标题行尾部插槽（右上角按钮与标题垂直居中对齐）。 */
  @BuilderParam trailing: () => void = EmptyTrailing;

  build() {
    Column() {
      Row() {
        Column({ space: 6 }) {
          Text(this.title)
            .fontSize(Dt.fontHero)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.trailing()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
    // 与工具页标题栏一致：顶安全区 + 标题，下方用空隙把内容推开
    .padding({
      top: this.safeTopVp + Dt.spaceLg,
      bottom: Dt.spaceXl + Dt.spaceSm,
      left: 0,
      right: 0
    })
  }
}
