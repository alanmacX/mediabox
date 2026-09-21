/**
 * 应用入口。
 *
 * 一多共用：窄屏用 HdsTabs 底部栏；宽屏切为固定左侧导航。
 * - 手机/竖屏窄窗：底部悬浮材质页签
 * - 横屏 Pad / 宽窗：左侧固定导航栏，内容区保持完整宽度
 * 二级页统一 HdsNavDestination + 右滑转场 + systemBarStyle。
 */
import { HdsNavigation, HdsNavDestination, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppBackground } from '../ui/components/GlassCard';
import { HomePage } from './HomePage';
import { TasksPage } from './TasksPage';
import { TaskProgressPage } from './TaskProgressPage';
import { BenchmarkPage } from './BenchmarkPage';
import { Workbench } from './Workbench';
import { MediaInfoPage } from './MediaInfoPage';
import { BatchWorkbench } from './BatchWorkbench';
import { ToolConfigPage } from './ToolConfigPage';
import { BenchHistoryPage, BenchDetailPage } from './BenchHistoryPage';
import { BenchInfoPage } from './BenchInfoPage';
import { Adaptive } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import {
  destinationTitleBar,
  lightStatusBarStyle,
  tabBarFloatingStyle,
  tabBarWidthValue
} from '../ui/theme/HdsKit';
import { WorkbenchSession, RouteNames } from '../ui/components/WorkbenchSession';
import { NavPathStore } from '../ui/components/NavPathStore';
import { BenchHistoryStore } from '../core/bench/BenchHistoryStore';

/**
 * HdsNavigation 始终保持全宽，根侧栏只覆盖在根 Tab 上层，因此滑动时两页内容槽一致。
 * 使用原生右滑，保留明确的“进入详情/返回上级”空间语义而不露出容器边缘。
 */
const SECONDARY_TRANSITION: NavigationSystemTransitionType = NavigationSystemTransitionType.SLIDE_RIGHT;

@Entry
@Component
struct Index {
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  /** 固定引用模块级 stack，避免 render 期被当成“状态变更” */
  @Provide('pathStack') pathStack: NavPathStack = NavPathStore.stack();
  @State tab: number = 0;
  /** 任意二级 NavDestination 出场前隐藏根侧栏，避免转场中重排内容槽。 */
  @State secondaryVisible: boolean = false;
  // 不用 @Watch：首帧 StorageLink 同步可能触发 render 期导航
  @StorageLink('sharedFileVersion') sharedFileVersion: number = 0;
  private tabsController: HdsTabsController = new HdsTabsController();
  private uiReady: boolean = false;
  /**
   * 任务由任意二级页创建后，统一回到根 TasksPage。
   * 不把该请求绑定到 NavDestination 的渲染生命周期，避免旧二级页保留 1% 的快照。
   */
  private rootTaskPoller: number = -1;
  private lastRootTasksVersion: number = 0;

  aboutToAppear(): void {
    this.uiReady = true;
    // Index 是根组件；以一个轻量的请求序号接收二级页事件，避免 StorageLink/@Watch
    // 在首帧 render 期间触发导航。
    this.lastRootTasksVersion = AppStorage.get<number>('openRootTasksVersion') ?? 0;
    if (this.rootTaskPoller < 0) {
      this.rootTaskPoller = setInterval((): void => {
        const version = AppStorage.get<number>('openRootTasksVersion') ?? 0;
        if (this.uiReady && version > this.lastRootTasksVersion) {
          this.lastRootTasksVersion = version;
          this.switchRootTab(1);
        }
      }, 80);
    }
    // 所有副作用延后到首帧之后，避免 AceStateMgmt「render 期间改状态」
    setTimeout((): void => {
      if (this.useSideTabs()) {
        AppStorage.setOrCreate<number>('tabBarSideInsetVp', 224);
      }
      this.openSharedFile();
    }, 80);
  }

  private openSharedFile(): void {
    if (!WorkbenchSession.sharedPending || WorkbenchSession.picked === undefined) {
      return;
    }
    WorkbenchSession.sharedPending = false;
    this.tab = 0;
    const stack = NavPathStore.stack();
    stack.pushPathByName(RouteNames.WORKBENCH, 'share');
  }

  /** 官方一多：宽度优先，高度比 ≥0.8 时用侧栏（横屏 Pad / 宽窗）。 */
  private useSideTabs(): boolean {
    return Adaptive.useSideTabs(this.windowWidthVp, this.isLandscape, this.windowHeightVp);
  }

  private tabBarItem(icon: Resource, label: Resource): BottomTabBarStyle {
    const symbol: TabBarSymbol = {
      normal: new SymbolGlyphModifier(icon),
      selected: new SymbolGlyphModifier(icon)
    };
    return new BottomTabBarStyle(symbol, label)
      .labelStyle({
        selectedColor: $r('app.color.accent'),
        unselectedColor: $r('app.color.text_secondary'),
        font: { size: 11, weight: FontWeight.Medium }
      })
      .iconStyle({
        selectedColor: $r('app.color.accent'),
        unselectedColor: $r('app.color.text_secondary')
      })
      .layoutMode(LayoutMode.VERTICAL)
      .verticalAlign(VerticalAlign.Center);
  }

  /** 从任何二级页回到根 Tab：先移除覆盖在 Tabs 之上的 NavDestination。 */
  private switchRootTab(index: number): void {
    const stack = NavPathStore.stack();
    if (stack.size() > 0) {
      stack.clear();
    }
    this.tab = index;
    this.tabsController.changeIndex(index);
  }

  private onSecondaryWillAppear(): void {
    this.secondaryVisible = true;
  }

  private onSecondaryHidden(): void {
    // 嵌套二级页切换时，栈仍有内容，不能让侧栏中途闪回。
    if (NavPathStore.stack().size() === 0) {
      this.secondaryVisible = false;
    }
  }

  /** 宽屏固定侧边导航：遵循大屏“侧栏 + 内容区”结构，不复用手机浮动 TabBar。 */
  @Builder
  SideNavItem(index: number, icon: Resource, label: Resource) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.tab === index ? $r('app.color.accent') : $r('app.color.text_secondary')])
      Text(label)
        .fontSize(16)
        .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.tab === index ? $r('app.color.accent') : $r('app.color.text_primary'))
        .maxLines(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 18 })
    .borderRadius(24)
    .backgroundColor(this.tab === index ? $r('app.color.accent_soft') : Color.Transparent)
    .onClick((): void => {
      this.switchRootTab(index);
    })
  }

  @Builder
  SideNavigation() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        // layered-image 资源不能作为普通 Image 直接绘制；这里显式叠合前后景，和启动图标一致。
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.background'))
            .width('100%')
            .height('100%')
          Image($r('app.media.foreground'))
            .width('100%')
            .height('100%')
            .padding(3)
        }
          .width(32)
          .height(32)
          .borderRadius(9)
          .clip(true)
        Column({ space: 0 }) {
          Text('MediaBox')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          Text('媒体工具箱')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(64)
      .padding({ left: 20, right: 12 })

      Column({ space: 8 }) {
        this.SideNavItem(0, $r('sys.symbol.house'), $r('app.string.tab_tools'))
        this.SideNavItem(1, $r('sys.symbol.list_bullet_square'), $r('app.string.tab_tasks'))
        this.SideNavItem(2, $r('sys.symbol.waveform'), $r('app.string.tab_bench'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      Blank()
    }
    .width(165)
    .height('100%')
    .padding({ top: this.safeTopVp + 12 })
    // 侧栏是覆盖式根导航，与 AppBackground 保持同一底色，不再绘制硬分隔线。
    .backgroundColor($r('app.color.app_background'))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackground()
      // Navigation 不能随侧栏显隐改变宽度，否则 SLIDE_RIGHT 的两帧边缘会错位。
      HdsNavigation(NavPathStore.stack()) {
        HdsTabs({ index: this.tab, controller: this.tabsController }) {
          TabContent() {
            HomePage()
          }
          .tabBar(this.tabBarItem($r('sys.symbol.house'), $r('app.string.tab_tools')))

          TabContent() {
            TasksPage()
          }
          .tabBar(this.tabBarItem($r('sys.symbol.list_bullet_square'), $r('app.string.tab_tasks')))

          TabContent() {
            BenchmarkPage()
          }
          .tabBar(this.tabBarItem($r('sys.symbol.waveform'), $r('app.string.tab_bench')))
        }
        // 宽屏时 TabBar 只保留内容切换职责，视觉导航由固定 SideNavigation 提供。
        .vertical(false)
        .barPosition(BarPosition.End)
        .barWidth(tabBarWidthValue(false, this.windowWidthVp))
        .barHeight(this.useSideTabs() ? 0 : Dt.tabBarHeight)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        .barOverlap(true)
        .barFloatingStyle(tabBarFloatingStyle(
          this.safeBottomVp,
          $r('app.color.accent') as ResourceColor,
          false,
          undefined
        ))
        .barBackgroundColor(Color.Transparent)
        .onChange((index: number) => {
          if (!this.uiReady) {
            return;
          }
          this.tab = index;
        })
      }
        .navDestination(this.PageMap)
      .hideTitleBar(true)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')
      if (this.useSideTabs() && !this.secondaryVisible) {
        this.SideNavigation()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  PageMap(name: string) {
    if (name === RouteNames.WORKBENCH) {
      HdsNavDestination() {
        Workbench()
      }
      .titleBar(destinationTitleBar('工作台'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.BATCH) {
      HdsNavDestination() {
        BatchWorkbench()
      }
      .titleBar(destinationTitleBar('批量处理'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.TASK_PROGRESS) {
      HdsNavDestination() {
        TaskProgressPage()
      }
      .titleBar(destinationTitleBar('任务进度'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.MEDIA_INFO) {
      HdsNavDestination() {
        MediaInfoPage()
      }
      .titleBar(destinationTitleBar('媒体信息'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.TOOL_CONFIG) {
      HdsNavDestination() {
        ToolConfigPage()
      }
      .titleBar(destinationTitleBar(WorkbenchSession.pendingAction?.title ?? '工具设置'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.BENCH_HISTORY) {
      HdsNavDestination() {
        BenchHistoryPage()
      }
      .titleBar(destinationTitleBar('历史测试'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.BENCH_DETAIL) {
      HdsNavDestination() {
        BenchDetailPage()
      }
      .titleBar(destinationTitleBar('跑分详情', BenchHistoryStore.detailSubtitle()))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    } else if (name === RouteNames.BENCH_INFO) {
      HdsNavDestination() {
        BenchInfoPage()
      }
      .titleBar(destinationTitleBar('测试说明'))
      .systemTransition(SECONDARY_TRANSITION)
      .systemBarStyle(lightStatusBarStyle(), lightStatusBarStyle())
      .onWillAppear((): void => this.onSecondaryWillAppear())
      .onHidden((): void => this.onSecondaryHidden())
    }
  }
}
