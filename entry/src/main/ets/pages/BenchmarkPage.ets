/**
 * Benchmark — 性能测试。
 * - 标题右侧三点 → 原生 bindMenu 菜单（系统 HDS 材质渲染）→ 历史测试二级页
 * - 历史详情复用 BenchReportView（与当前分数/子项 UI 同一套）
 * - 不再使用「屏幕保持常亮」
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { Immersive } from '../ui/theme/HdsKit';
import { BenchReportView } from '../ui/components/BenchReportView';
import { RouteNames } from '../ui/components/WorkbenchSession';
import { MediaBenchmark } from '../core/bench/MediaBenchmark';
import { BenchItemResult, BenchReport, BenchScoring } from '../core/bench/BenchScoring';
import { BenchHistoryEntry, BenchHistoryStore } from '../core/bench/BenchHistoryStore';

@Component
export struct BenchmarkPage {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @Consume('pathStack') pathStack: NavPathStack;

  @State running: boolean = false;
  @State progressText: string = '';
  @State progressRatio: number = 0;
  @State elapsedSec: number = 0;
  @State report: BenchReport | undefined = undefined;
  @State displayReport: BenchReport | undefined = undefined;
  @State displayLabel: string = '';
  /** 受控菜单显隐：bindContextMenu(isShown) + onDisappear 回写。 */
  @State benchMenuOpen: boolean = false;
  private alive: boolean = true;
  private tickerId: number = -1;
  private lastRatio: number = 0;

  aboutToAppear(): void {
    this.alive = true;
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.clearTicker();
  }

  private twoColItems(): boolean {
    return this.isLandscape && this.windowWidthVp >= 640;
  }

  private activeReport(): BenchReport | undefined {
    return this.displayReport !== undefined ? this.displayReport : this.report;
  }

  private writeBenchReport(report: BenchReport): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = `${context.cacheDir}/bench_report.txt`;
      const lines: string[] = [];
      lines.push(`version=${report.version} index=${report.score} reference_index=${BenchScoring.BASELINE_SCORE} passed=${report.passed}/${report.total}`);
      lines.push(`note=${report.deviceNote} elapsed=${this.elapsedSec}s max_cv=${report.maxVariationPct.toFixed(1)}%`);
      for (const item of report.items) {
        const line = `${item.id}|ok=${item.ok ? 1 : 0}|index=${item.score}|metric=${item.metric}|` +
          `reference_metric=${item.referenceMetric}|label=${item.metricLabel}|cv=${item.variationPct.toFixed(1)}%|batch=${item.iterations}|` +
          `samples_ms=${item.samplesMs.map((v: number): string => v.toFixed(2)).join(',')}|detail=${item.detail}`;
        lines.push(line);
        hilog.error(0x4D42, 'BenchItem', '%{public}s', line);
      }
      const header = lines[0] + ' ' + lines[1];
      hilog.error(0x4D42, 'BenchItem', 'SUMMARY %{public}s', header);
      const text = lines.join('\n') + '\n';
      const buf = new util.TextEncoder('utf-8').encodeInto(text);
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buf.slice().buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(0x4D42, 'BenchmarkPage', 'report written %{public}s passed=%{public}d/%{public}d',
        path, report.passed, report.total);
    } catch (e) {
      hilog.warn(0x4D42, 'BenchmarkPage', 'write report %{public}s', (e as Error).message);
    }
  }

  private clearTicker(): void {
    if (this.tickerId >= 0) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
  }

  private startTicker(): void {
    this.clearTicker();
    this.elapsedSec = 0;
    this.tickerId = setInterval((): void => {
      if (!this.alive || !this.running) {
        return;
      }
      this.elapsedSec += 1;
    }, 1000);
  }

  private applyRatio(ratio: number): void {
    const next = Math.max(this.lastRatio, Math.min(1, ratio));
    this.lastRatio = next;
    this.progressRatio = next;
  }

  private async startBench(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.report = undefined;
    this.displayReport = undefined;
    this.displayLabel = '';
    this.progressRatio = 0;
    this.lastRatio = 0;
    this.progressText = '准备样例…';
    this.startTicker();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bench = new MediaBenchmark(context);
      const report = await bench.run(3,
        (item: BenchItemResult, index: number, total: number): void => {
          if (!this.alive) {
            return;
          }
          this.applyRatio(0.12 + (index / total) * 0.86);
          this.progressText = `${index}/${total} ${item.title} · ${item.ok ?
            `${this.metricText(item)} / 指数 ${item.score}` : '跳过'}`;
        },
        (label: string, ratio: number): void => {
          if (!this.alive) {
            return;
          }
          this.progressText = label;
          this.applyRatio(ratio);
        });
      if (this.alive) {
        this.report = report;
        this.displayReport = report;
        this.displayLabel = '';
        this.applyRatio(1);
        this.progressText = `完成 · 总耗时 ${this.elapsedSec}s · ${report.passed}/${report.total} 通过`;
        this.writeBenchReport(report);
        const entry: BenchHistoryEntry = {
          savedAt: Date.now(),
          elapsedSec: this.elapsedSec,
          report: report
        };
        await BenchHistoryStore.add(context, entry);
      }
    } catch (e) {
      if (this.alive) {
        this.progressText = `测试失败：${(e as Error).message}`;
      }
    } finally {
      this.clearTicker();
      if (this.alive) {
        this.running = false;
      }
    }
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

  /** 原生 Menu + systemMaterial 沉浸光感材质；底色/描边/阴影交由系统材质层。 */
  @Builder
  BenchMenuBuilder() {
    Menu() {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.clock_arrow_2_circlepath'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')]),
        content: '历史测试'
      })
        .contentFont({ size: Dt.fontBody })
        .contentFontColor($r('app.color.text_primary'))
        .height(42)
        .borderRadius(Dt.radiusMd)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.benchMenuOpen = false;
          this.pathStack.pushPathByName(RouteNames.BENCH_HISTORY, undefined);
        })
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.info_circle'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')]),
        content: '测试说明'
      })
        .contentFont({ size: Dt.fontBody })
        .contentFontColor($r('app.color.text_primary'))
        .height(42)
        .borderRadius(Dt.radiusMd)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.benchMenuOpen = false;
          this.pathStack.pushPathByName(RouteNames.BENCH_INFO, undefined);
        })
    }
    .width(168)
    .padding(Dt.spaceSm)
    .borderRadius(Dt.radiusLg)
  }

  /**
   * 三点按钮：透明底 + Regular 模糊材质 + 描边。
   * 组件级 systemMaterial 在真机鸿蒙7上对页面内联组件不渲染（生效约束：
   * 仅弹窗/标题栏/页签区域），内容区按钮固定用模糊材质。
   */
  @Builder
  MoreButton() {
    Button() {
      this.MoreDots()
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .buttonStyle(ButtonStyleMode.NORMAL)
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 1, color: $r('app.color.divider') })
    .onClick((): void => {
      this.benchMenuOpen = true;
    })
    .bindContextMenu(this.benchMenuOpen, this.BenchMenuBuilder, {
      placement: Placement.BottomRight,
      systemMaterial: Immersive.regular(),
      onDisappear: (): void => {
        this.benchMenuOpen = false;
      }
    })
  }

  @Builder
  MoreDots() {
    Row({ space: 3 }) {
      Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
      Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
      Column().width(4).height(4).borderRadius(2).backgroundColor($r('app.color.text_primary'))
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  /** 性能页顶栏：左标题、右三点（受控 bindContextMenu，点击弹出）。 */
  @Builder
  PageHeader() {
    Row() {
      Text('性能')
        .fontSize(Dt.fontHero)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      this.MoreButton()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      top: this.safeTopVp + Dt.spaceLg,
      bottom: Dt.spaceXl + Dt.spaceSm,
      left: 0,
      right: 0
    })
  }

  private progressPct(): number {
    return Math.round(this.progressRatio * 100);
  }

  private scoreText(): string {
    const report = this.activeReport();
    return report === undefined || report.passed !== report.total ? '—' : `${report.score}`;
  }

  private scoreSubText(): string {
    const report = this.activeReport();
    if (report === undefined) {
      return '本机未测试';
    }
    return `${report.passed}/${report.total} 项通过`;
  }

  /** 顶部的分数块：把结果与“开始测试”收成一个操作区。 */
  @Builder
  ScorePanel() {
    Column({ space: 2 }) {
      Text('性能分数')
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
      Text(this.scoreText())
        .fontSize(48)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .lineHeight(56)
      Text(this.scoreSubText())
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Dt.spaceXl, right: Dt.spaceXl, top: Dt.spaceLg, bottom: Dt.spaceLg })
    .borderRadius(Dt.radiusXl)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({ radius: 18, color: '#0F101814', offsetX: 0, offsetY: 6 })
  }

  @Builder
  StartButton() {
    Button(this.running ? '测试中…' : (this.report === undefined ? '开始测试' : '再次测试'))
      .width('100%')
      .height(48)
      .type(ButtonType.Capsule)
      .buttonStyle(ButtonStyleMode.EMPHASIZED)
      .enabled(!this.running)
      .onClick(() => this.startBench())
  }

  /** 横屏横向收束、竖屏自然堆叠；进度永远紧贴在主按钮上方。 */
  @Builder
  BenchmarkControl() {
    if (this.isLandscape) {
      Row({ space: Dt.spaceLg }) {
        Column() {
          this.ScorePanel()
        }
        .width(248)
        Column({ space: Dt.spaceMd }) {
          this.ProgressSlot()
          this.StartButton()
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    } else {
      Column({ space: Dt.spaceMd }) {
        this.ScorePanel()
        this.ProgressSlot()
        this.StartButton()
      }
      .width('100%')
    }
  }

  @Builder
  ProgressCard() {
    Column({ space: Dt.spaceSm }) {
      Row() {
        Text(this.progressText.length > 0 ? this.progressText : '测试中…')
          .fontSize(Dt.fontBody)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.running ? `${this.progressPct()}%` : '')
          .fontSize(Dt.fontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .margin({ left: Dt.spaceSm })
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Progress({
        value: this.progressPct(),
        total: 100,
        type: ProgressType.Linear
      })
        .width('100%')
        .height(8)
        .color($r('app.color.accent'))

      Text(`已用 ${this.elapsedSec}s`)
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(Dt.spaceMd)
    .height(88)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
  }

  /** 始终保留进度槽，防止开始测试时把按钮和下方子项推开。 */
  @Builder
  ProgressSlot() {
    if (this.running || this.progressText.length > 0) {
      this.ProgressCard()
    } else {
      Blank()
        .width('100%')
        .height(88)
    }
  }

  build() {
    Scroll() {
      Column({ space: Dt.spaceLg }) {
        this.PageHeader()
        this.BenchmarkControl()
        BenchReportView({
          report: this.activeReport(),
          label: this.displayLabel,
          twoCol: this.twoColItems(),
          showHero: false
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .padding({
      left: Adaptive.pagePadding(this.windowWidthVp) +
        Adaptive.sideTabInset(this.windowWidthVp, this.isLandscape, this.windowHeightVp),
      right: Adaptive.pagePadding(this.windowWidthVp),
      top: 0,
      bottom: Adaptive.bottomTabInset(this.safeBottomVp, this.windowWidthVp, this.isLandscape,
        this.windowHeightVp)
    })
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
