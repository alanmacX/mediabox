/**
 * BenchReportView — 跑分报告共用 UI（分数 Hero + 子项指数）。
 * 性能页（实时/最近一次）与历史详情页复用，保证展示口径一致。
 */
import { Dt } from '../theme/DesignTokens';
import { BenchItemResult, BenchReport } from '../../core/bench/BenchScoring';

@Component
export struct BenchReportView {
  @Prop report: BenchReport | undefined = undefined;
  /** Hero 顶部小字；空串时回退为「媒体性能指数」。 */
  @Prop label: string = '';
  /** 横屏双列子项。 */
  @Prop twoCol: boolean = false;
  /** 首页性能页将分数放进主操作区；历史详情保留完整分数 Hero。 */
  @Prop showHero: boolean = true;

  private scoreText(): string {
    const r = this.report;
    return r === undefined || r.passed !== r.total ? '—' : `${r.score}`;
  }

  private scoreSubText(): string {
    const r = this.report;
    if (r === undefined) {
      return '本机未测试';
    }
    return `${r.version} · ${r.passed}/${r.total} 项通过 · 最大波动 ${r.maxVariationPct.toFixed(1)}%`;
  }

  private metricText(item: BenchItemResult): string {
    const v = item.metric;
    if (!Number.isFinite(v)) {
      return item.detail.length > 0 ? item.detail : item.metricLabel;
    }
    if (item.metricLabel.indexOf('MP/s') >= 0) {
      return `${v.toFixed(1)} MP/s`;
    }
    if (item.metricLabel.indexOf('MB/s') >= 0) {
      return `${v.toFixed(1)} MB/s`;
    }
    return `${v.toFixed(2)}x 实时`;
  }

  private relativeText(item: BenchItemResult): string {
    return item.referenceMetric > 0 ? (item.metric / item.referenceMetric).toFixed(2) : '—';
  }

  /** 横屏双列时标题可完整换行，不截断。 */
  @Builder
  ItemRow(item: BenchItemResult) {
    Column({ space: 6 }) {
      Row({ space: Dt.spaceSm }) {
        Text(item.title)
          .fontSize(Dt.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(this.twoCol ? 3 : 2)
          .textOverflow({ overflow: TextOverflow.None })
        Text(item.ok ? `${item.score}` : '—')
          .fontSize(Dt.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(item.ok ? $r('app.color.accent') : $r('app.color.text_tertiary'))
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text(item.ok ?
        `${this.metricText(item)} · 参考 ${this.relativeText(item)}× · 波动 ${item.variationPct.toFixed(1)}% · ${item.note}` :
        `${item.note} · ${item.detail}`)
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(this.twoCol ? 5 : 4)
        .textOverflow({ overflow: TextOverflow.None })
    }
    .width('100%')
    .padding(Dt.spaceMd)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
  }

  @Builder
  ScoreHero() {
    Column({ space: Dt.spaceSm }) {
      Text(this.label.length > 0 ? this.label : '媒体性能指数')
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
      Text(this.scoreText())
        .fontSize(56)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
      Text(this.scoreSubText())
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(this.twoCol ? 4 : 3)
        .textOverflow({ overflow: TextOverflow.None })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding(Dt.spaceXl)
    .borderRadius(Dt.radiusXl)
    // 沉浸光感受 HarmonyOS 7 生效约束：内容区卡片不适用组件级材质（会被系统降级成透明），
    // 沉浸光感落点收敛为 标题栏/页签/弹窗/按钮（见 HdsKit.destinationTitleBar / BenchmarkPage）
    .backgroundColor($r('app.color.surface_card'))
    .shadow({ radius: 24, color: '#0F101814', offsetX: 0, offsetY: 8 })
  }

  @Builder
  ItemsSection() {
    if (this.report !== undefined) {
      Text('子项指数（参考值 = 100）')
        .fontSize(Dt.fontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.twoCol) {
        GridRow({
          columns: 2,
          gutter: Dt.spaceMd
        }) {
          ForEach(this.report!.items, (item: BenchItemResult) => {
            GridCol() {
              this.ItemRow(item)
            }
          }, (item: BenchItemResult) => item.id)
        }
        .width('100%')
      } else {
        Column({ space: Dt.spaceSm }) {
          ForEach(this.report!.items, (item: BenchItemResult) => {
            this.ItemRow(item)
          }, (item: BenchItemResult) => item.id)
        }
        .width('100%')
      }

    }
  }

  build() {
    Column({ space: Dt.spaceLg }) {
      if (this.showHero) {
        this.ScoreHero()
      }
      this.ItemsSection()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
