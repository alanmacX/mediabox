/**
 * 历史测试 — 二级页（跑分列表）+ 跑分详情三级页。
 * - 列表：每次跑分一行，点选写入 BenchHistoryStore.selected 后 push 详情页
 * - 详情：复用 BenchReportView，与性能页同一套分数/子项 UI
 */
import { common } from '@kit.AbilityKit';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';
import { BenchReportView } from '../ui/components/BenchReportView';
import { RouteNames } from '../ui/components/WorkbenchSession';
import { ToolSymbol } from '../core/model/MediaTypes';
import { BenchHistoryEntry, BenchHistoryStore } from '../core/bench/BenchHistoryStore';

@Component
export struct BenchHistoryPage {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @Consume('pathStack') pathStack: NavPathStack;
  @State entries: BenchHistoryEntry[] = [];
  @State loaded: boolean = false;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    void BenchHistoryStore.load(context).then((list: BenchHistoryEntry[]): void => {
      this.entries = list;
      this.loaded = true;
    });
  }

  private openEntry(entry: BenchHistoryEntry): void {
    BenchHistoryStore.selected = entry;
    this.pathStack.pushPathByName(RouteNames.BENCH_DETAIL, undefined);
  }

  build() {
    Scroll() {
      Column({ space: Dt.spaceMd }) {
        if (!this.loaded) {
          Text('加载中…')
            .fontSize(Dt.fontBody)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: Dt.spaceXxl })
        } else if (this.entries.length === 0) {
          Column({ space: Dt.spaceSm }) {
            SystemSymbolIcon({
              name: ToolSymbol.EMPTY,
              iconSize: 40,
              color: $r('app.color.text_tertiary')
            })
            Text('暂无历史记录')
              .fontSize(Dt.fontBody)
              .fontColor($r('app.color.text_secondary'))
            Text('完成一次性能测试后，结果会自动保存到这里')
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: Dt.spaceXxl })
        } else {
          Text(`共 ${this.entries.length} 次记录 · 最多保留 20 次`)
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')

          ForEach(this.entries, (e: BenchHistoryEntry, i: number) => {
            this.HistoryRow(e, i)
          }, (e: BenchHistoryEntry, i: number) => `${e.savedAt}_${i}`)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .padding({
      // HdsNavDestination 标题栏 avoidLayoutSafeArea：内容需预留标题栏高度（与 Workbench 一致）
      left: Dt.navContentInset,
      right: Adaptive.pagePadding(this.windowWidthVp),
      top: Dt.spaceXxl + 72,
      bottom: Dt.spaceXxl + this.safeBottomVp
    })
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  HistoryRow(e: BenchHistoryEntry, i: number) {
    Button() {
      Row({ space: Dt.spaceMd }) {
        Column({ space: 2 }) {
          Text(BenchHistoryStore.formatTime(e.savedAt))
            .fontSize(Dt.fontBody)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`${e.report.version} · ${e.report.passed}/${e.report.total} 项通过 · 用时 ${e.elapsedSec}s`)
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(e.report.passed === e.report.total ? `${e.report.score}` : '—')
          .fontSize(Dt.fontTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(e.report.passed === e.report.total ?
            $r('app.color.accent') : $r('app.color.text_tertiary'))
          .flexShrink(0)

        SystemSymbolIcon({
          name: ToolSymbol.CHEVRON,
          iconSize: 16,
          color: $r('app.color.text_secondary')
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .buttonStyle(ButtonStyleMode.NORMAL)
    .width('100%')
    .padding(Dt.spaceMd)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
    .onClick((): void => this.openEntry(e))
  }
}

@Component
export struct BenchDetailPage {
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @State entry: BenchHistoryEntry | undefined = undefined;

  aboutToAppear(): void {
    this.entry = BenchHistoryStore.selected;
  }

  private twoColItems(): boolean {
    return this.isLandscape && this.windowWidthVp >= 640;
  }

  private detailLabel(): string {
    if (this.entry === undefined) {
      return '';
    }
    return `历史 · ${BenchHistoryStore.formatTime(this.entry.savedAt)} · 用时 ${this.entry.elapsedSec}s`;
  }

  build() {
    Scroll() {
      Column() {
        if (this.entry === undefined) {
          Text('记录不存在')
            .fontSize(Dt.fontBody)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: Dt.spaceXxl })
        } else {
          BenchReportView({
            report: this.entry.report,
            label: this.detailLabel(),
            twoCol: this.twoColItems()
          })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        // HdsNavDestination 标题栏 avoidLayoutSafeArea：内容需预留标题栏高度（与 Workbench 一致）
        left: Dt.navContentInset,
        right: Adaptive.pagePadding(this.windowWidthVp),
        top: Dt.spaceXxl + 72,
        bottom: Dt.spaceXxl + this.safeBottomVp
      })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
