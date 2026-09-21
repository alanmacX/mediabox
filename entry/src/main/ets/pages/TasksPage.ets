/**
 * 任务队列页 — 按天分组；当天不折叠，其它天可点开/收起。
 */
import { curves } from '@kit.ArkUI';
import { TaskQueue, QueueStats } from '../core/task/TaskQueue';
import { MediaTask, reconcileMediaTaskSnapshots } from '../core/task/MediaTask';
import { TaskCard } from '../ui/components/TaskCard';
import { QueueObserver } from '../ui/components/QueueObserver';
import { Adaptive, Breakpoint } from '../ui/adaptive/AdaptiveKit';
import { Dt } from '../ui/theme/DesignTokens';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';
import { ToolSymbol } from '../core/model/MediaTypes';
import { WorkbenchSession } from '../ui/components/WorkbenchSession';
import { ImmersiveRootHeader } from '../ui/components/ImmersiveRootHeader';
import {
  TaskDayGroup, groupTasksByDay, taskDayRenderKey
} from '../core/task/TaskQueuePresentation';

@Component
struct QueueStatChip {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop color: ResourceColor = $r('app.color.text_primary');

  build() {
    Column({ space: 2 }) {
      Text(`${this.value}`)
        .fontSize(Dt.fontTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color)
      Text(this.label)
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .padding(Dt.spaceMd)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(Dt.radiusLg)
    .backgroundColor($r('app.color.surface_card'))
    .shadow({
      radius: 24,
      color: '#0F101814',
      offsetX: 0,
      offsetY: 8
    })
  }
}

@Component
export struct TasksPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageProp('windowWidthVp') windowWidthVp: number = 390;
  @StorageProp('safeTopVp') safeTopVp: number = 0;
  @StorageProp('safeBottomVp') safeBottomVp: number = 0;
  @StorageProp('isLandscape') isLandscape: boolean = false;
  @StorageProp('windowHeightVp') windowHeightVp: number = 844;
  /** 入队页面发出的显式导航信号；即使 Tabs 没有重新触发生命周期，也强制同步一次。 */
  @StorageProp('openRootTasksVersion') @Watch('onOpenQueueRequest') openRootTasksVersion: number = 0;
  @State tasks: MediaTask[] = [];
  @State counts: QueueStats = { running: 0, waiting: 0, completed: 0, failed: 0, canceled: 0 };
  @State paused: boolean = false;
  @State asRootTab: boolean = true;
  /** 收起的日期 key；当天永远展开。 */
  @State collapsedDays: string[] = [];
  /**
   * HdsTabs/Navigation 切换期间，组件的 listener 可能已经退订而实体仍保持在屏幕上。
   * 轮询的是轻量 revision，不是每 200ms 深拷贝整份队列。
   */
  private observedQueueRevision: number = -1;
  private refreshPollingId: number = -1;

  private refresh(force: boolean = false): void {
    const queue = TaskQueue.getInstance();
    const revision = queue.currentRevision();
    if (!force && revision === this.observedQueueRevision) {
      return;
    }
    // ForEach 按 task.id 复用 TaskCard；必须保留已有快照对象的引用，才能让卡片的
    // @ObjectLink 收到字段变化。替换成同 id 的新对象只会留下首次渲染的旧进度。
    this.tasks = reconcileMediaTaskSnapshots(this.tasks, queue.list().slice().reverse());
    this.counts = queue.stats();
    this.paused = queue.isPaused();
    this.observedQueueRevision = revision;
  }

  private listener: QueueObserver = new QueueObserver((): void => {
    this.refresh(true);
  });

  private onOpenQueueRequest(): void {
    this.refresh(true);
  }

  aboutToAppear(): void {
    try {
      this.asRootTab = this.pathStack.getAllPathName().length === 0;
    } catch (e) {
      this.asRootTab = true;
    }
    TaskQueue.getInstance().subscribe(this.listener);
    this.refresh(true);
    if (this.refreshPollingId < 0) {
      this.refreshPollingId = setInterval((): void => this.refresh(), 200);
    }
  }

  aboutToDisappear(): void {
    TaskQueue.getInstance().unsubscribe(this.listener);
    if (this.refreshPollingId >= 0) {
      clearInterval(this.refreshPollingId);
      this.refreshPollingId = -1;
    }
  }

  private groups(): TaskDayGroup[] {
    return groupTasksByDay(this.tasks);
  }

  private isDayCollapsed(key: string, isToday: boolean): boolean {
    if (isToday) {
      return false;
    }
    return this.collapsedDays.indexOf(key) >= 0;
  }

  private toggleDay(key: string, isToday: boolean): void {
    if (isToday) {
      return;
    }
    const idx = this.collapsedDays.indexOf(key);
    const next = this.collapsedDays.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(key);
    }
    this.getUIContext().animateTo({
      duration: 240,
      curve: curves.cubicBezierCurve(0.2, 0.0, 0.0, 1.0)
    }, (): void => {
      this.collapsedDays = next;
    });
  }

  @Builder
  DeleteAction(taskId: string) {
    Button() {
      SystemSymbolIcon({ name: ToolSymbol.DELETE, iconSize: 22, color: Color.White })
    }
    .type(ButtonType.Circle)
    .width(56)
    .height(56)
    .buttonStyle(ButtonStyleMode.EMPHASIZED)
    .backgroundColor($r('app.color.danger_red'))
    .margin({ left: Dt.spaceSm })
    .onClick(() => this.deleteTask(taskId))
  }

  private deleteTask(taskId: string): void {
    const result = TaskQueue.getInstance().removeTask(taskId);
    if (result === 'busy') {
      this.getUIContext().getPromptAction().showToast({ message: '任务处理中，请先停止' });
      return;
    }
    if (result === 'ok') {
      this.getUIContext().getPromptAction().showToast({ message: '已删除该记录' });
    }
  }

  private isFocused(id: string): boolean {
    return WorkbenchSession.lastTaskIds.indexOf(id) >= 0;
  }

  @Builder
  TaskItem(t: MediaTask) {
    Column() {
      TaskCard({ task: t, onRemove: (): void => this.deleteTask(t.id) })
      if (this.isFocused(t.id)) {
        Text('本次提交')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.accent'))
          .padding({ left: Dt.spaceSm, top: 2 })
      }
    }
    .width('100%')
  }

  @Builder
  DayHeader(group: TaskDayGroup, collapsed: boolean) {
    Row({ space: Dt.spaceSm }) {
      Text(group.label)
        .fontSize(Dt.fontSub)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(`${group.tasks.length} 项`)
        .fontSize(Dt.fontCaption)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      if (!group.isToday) {
        SymbolGlyph(collapsed ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
          .fontSize(16)
          .fontColor([$r('app.color.text_secondary')])
          .rotate({ z: 1, angle: collapsed ? 0 : 180, centerX: '50%', centerY: '50%' })
          .animation({ duration: 240, curve: Curve.EaseOut })
      } else {
        Text('今天')
          .fontSize(Dt.fontCaption)
          .fontColor($r('app.color.accent'))
      }
    }
    .width('100%')
    .padding({ top: Dt.spaceLg, bottom: Dt.spaceSm })
    .onClick((): void => this.toggleDay(group.key, group.isToday))
  }

  @Builder
  GroupTasksList(group: TaskDayGroup) {
    if (this.asRootTab && (Adaptive.useSideTabs(this.windowWidthVp, this.isLandscape, this.windowHeightVp) ||
      Adaptive.breakpoint(this.windowWidthVp) === Breakpoint.LG)) {
      GridRow({
        columns: Adaptive.taskGridColumns(this.windowWidthVp, this.isLandscape),
        gutter: Dt.spaceSm
      }) {
        ForEach(group.tasks, (t: MediaTask) => {
          GridCol() {
            this.TaskItem(t)
          }
        }, (t: MediaTask) => t.id)
      }
      .width('100%')
    } else {
      Column({ space: Dt.spaceSm }) {
        ForEach(group.tasks, (t: MediaTask) => {
          this.TaskItem(t)
        }, (t: MediaTask) => t.id)
      }
      .width('100%')
    }
  }

  @Builder
  TaskListBody() {
    Column({ space: 0 }) {
      ForEach(this.groups(), (g: TaskDayGroup) => {
        Column({ space: 0 }) {
          this.DayHeader(g, this.isDayCollapsed(g.key, g.isToday))
          if (!this.isDayCollapsed(g.key, g.isToday)) {
            Column() {
              this.GroupTasksList(g)
            }
            .width('100%')
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: -8 })),
              TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: -8 }))
            ).animation({ duration: 220, curve: Curve.EaseOut }))
          }
        }
        .width('100%')
      }, (g: TaskDayGroup) => taskDayRenderKey(g))
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 0 }) {
        if (this.asRootTab) {
          ImmersiveRootHeader({ title: '任务队列' })
        }

        if (this.tasks.length > 0) {
          Column({ space: 0 }) {
            Row({ space: Dt.spaceSm }) {
              if (this.counts.waiting > 0) {
                Button() {
                  Row({ space: 4 }) {
                    SystemSymbolIcon({
                      name: this.paused ? ToolSymbol.PLAY : ToolSymbol.PAUSE,
                      iconSize: 14, color: $r('app.color.text_primary')
                    })
                    Text(this.paused ? '继续' : '暂停').fontSize(Dt.fontCaption)
                  }
                }
                .buttonStyle(ButtonStyleMode.NORMAL)
                .controlSize(ControlSize.SMALL)
                .onClick(() => this.paused ?
                  TaskQueue.getInstance().resume() : TaskQueue.getInstance().pause())
              }
              Blank()
              if (this.counts.completed + this.counts.failed + this.counts.canceled > 0) {
                Button('清除记录')
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .controlSize(ControlSize.SMALL)
                  .onClick(() => TaskQueue.getInstance().clearFinished())
              }
            }
            .width('100%')
            .margin({ bottom: Dt.spaceLg })

            Row({ space: Dt.spaceSm }) {
              QueueStatChip({ label: '处理中', value: this.counts.running, color: $r('app.color.accent') })
              QueueStatChip({ label: '等待', value: this.counts.waiting })
              QueueStatChip({ label: '完成', value: this.counts.completed, color: $r('app.color.lossless_green') })
              QueueStatChip({ label: '失败', value: this.counts.failed, color: $r('app.color.danger_red') })
            }
            .width('100%')
            .margin({ bottom: Dt.spaceXl })

            this.TaskListBody()
          }
          .width('100%')
        } else {
          Column({ space: Dt.spaceMd }) {
            SystemSymbolIcon({ name: ToolSymbol.EMPTY, iconSize: 32, color: $r('app.color.text_tertiary') })
            Text($r('app.string.tasks_empty'))
              .fontSize(Dt.fontBody)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(Dt.spaceXxl)
        }
      }
      .width('100%')
      .padding({
        left: Adaptive.pagePadding(this.windowWidthVp) +
          (this.asRootTab ?
            Adaptive.sideTabInset(this.windowWidthVp, this.isLandscape, this.windowHeightVp) : 0),
        right: Adaptive.pagePadding(this.windowWidthVp),
        top: this.asRootTab ? 0 : 96,
        bottom: this.asRootTab ?
          Adaptive.bottomTabInset(this.safeBottomVp, this.windowWidthVp, this.isLandscape,
            this.windowHeightVp) : Dt.spaceXxl
      })
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
  }
}
