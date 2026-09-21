/**
 * 本次提交的进度页。
 *
 * 它不是根“任务队列”的第二份带分组列表：二级导航中的整页任务列表会同时经历
 * NavDestination 转场、观察者回调与 ForEach 重组，在部分设备上会留下旧快照。
 * 这里仅展示本次任务，并以低频快照同步队列的权威状态。
 */
import { TaskQueue } from '../core/task/TaskQueue';
import { MediaTask, reconcileMediaTaskSnapshots, TaskState } from '../core/task/MediaTask';
import { TaskCard } from '../ui/components/TaskCard';
import { WorkbenchSession } from '../ui/components/WorkbenchSession';
import { Dt } from '../ui/theme/DesignTokens';
import { SystemSymbolIcon } from '../ui/components/SystemSymbolIcon';
import { ToolSymbol } from '../core/model/MediaTypes';

@Component
export struct TaskProgressPage {
  @State tasks: MediaTask[] = [];
  private pollingId: number = -1;
  private observedQueueRevision: number = -1;

  private refresh(force: boolean = false): void {
    const queue = TaskQueue.getInstance();
    const revision = queue.currentRevision();
    if (!force && revision === this.observedQueueRevision) {
      return;
    }
    const ids = WorkbenchSession.lastTaskIds;
    const next: MediaTask[] = [];
    for (const task of queue.list()) {
      if (ids.indexOf(task.id) >= 0) {
        next.push(task);
      }
    }
    // 与根任务页相同：稳定对象身份，原位更新 @ObjectLink 所观察的字段。
    this.tasks = reconcileMediaTaskSnapshots(this.tasks, next);
    this.observedQueueRevision = revision;
  }

  aboutToAppear(): void {
    this.refresh(true);
    // 避开高频引擎回调与导航转场的状态竞争；任务状态来源始终是 TaskQueue。
    this.pollingId = setInterval((): void => this.refresh(), 250);
  }

  aboutToDisappear(): void {
    if (this.pollingId >= 0) {
      clearInterval(this.pollingId);
      this.pollingId = -1;
    }
  }

  private remove(id: string): void {
    TaskQueue.getInstance().removeTask(id);
    this.refresh();
  }

  private activeCount(): number {
    let count = 0;
    for (const task of this.tasks) {
      if (task.state === TaskState.RUNNING || task.state === TaskState.WAITING ||
        task.state === TaskState.CANCELING) {
        count++;
      }
    }
    return count;
  }

  build() {
    Scroll() {
      Column({ space: Dt.spaceMd }) {
        Row({ space: Dt.spaceSm }) {
          SystemSymbolIcon({ name: ToolSymbol.TASKS, iconSize: 22, color: $r('app.color.accent') })
          Column({ space: 2 }) {
            Text(this.activeCount() > 0 ? '正在处理' : '处理完成')
              .fontSize(Dt.fontTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.activeCount() > 0 ? '任务状态会自动更新' : '结果已保存到任务队列')
              .fontSize(Dt.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: Dt.spaceLg, bottom: Dt.spaceSm })

        if (this.tasks.length === 0) {
          Column({ space: Dt.spaceSm }) {
            SystemSymbolIcon({ name: ToolSymbol.TASKS, iconSize: 32, color: $r('app.color.text_secondary') })
            Text('未找到本次任务')
              .fontSize(Dt.fontBody)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(48)
          .alignItems(HorizontalAlign.Center)
        } else {
          ForEach(this.tasks, (task: MediaTask) => {
            TaskCard({ task: task, onRemove: (): void => this.remove(task.id) })
          }, (task: MediaTask) => task.id)
        }
      }
      .width('100%')
      .padding({ left: Dt.spaceLg, right: Dt.spaceLg, top: Dt.spaceXxl, bottom: Dt.spaceXxl })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }
}
