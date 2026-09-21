/** 性能测试说明 — 从主页面抽出的口径、样本和结果解读。 */
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { BenchScoring } from '../core/bench/BenchScoring';

@Component
export struct BenchInfoPage {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;

  @Builder
  Section(title: string, body: string) {
    Column({ space: Dt.spaceSm }) {
      Text(title)
        .fontSize(Dt.fontSub)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(body)
        .fontSize(Dt.fontBody)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .padding(Dt.spaceLg)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
  }

  build() {
    Scroll() {
      Column({ space: Dt.spaceMd }) {
        this.Section('这项测试测什么',
          '测试会使用固定媒体负载，分别衡量转码、图像处理和音频处理等本地吞吐能力。运行期间请避免同时进行大型下载、录屏或其他高负载任务。')
        this.Section('指数如何计算',
          `每个子项都会和固定参考负载比较并换算为指数。总指数参考值为 ${BenchScoring.BASELINE_SCORE}，没有“满分”；约两倍指数表示相对该固定参考负载约两倍的综合吞吐。`)
        this.Section('怎样比较结果',
          '建议只比较同一应用版本、相同负载下的多次结果。单次结果会受温度、电量、性能调度和后台任务影响；页面会显示每个子项的波动，波动较大时请稍后重测。')
        this.Section('数据与隐私',
          '测试只在设备本地运行，结果保存在本机的历史记录中。它用于观察这台设备的相对性能，不用于跨设备的绝对排名。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .padding({
      left: Dt.navContentInset,
      right: Adaptive.pagePadding(this.windowWidthVp),
      top: Dt.spaceXxl + 72,
      bottom: Dt.spaceXxl + this.safeBottomVp
    })
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }
}
