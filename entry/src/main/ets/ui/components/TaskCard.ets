/**
 * 任务卡片 — 普通 Column 卡片，进度与操作。
 * 操作按钮统一等宽一行三列，避免某个按钮被撑爆。
 */
import { MediaTask, TaskState, mediaTaskPrimaryTitle, mediaTaskSubTitle } from '../../core/task/MediaTask';
import { TaskQueue } from '../../core/task/TaskQueue';
import { common } from '@kit.AbilityKit';
import { OutputShareService } from '../../core/media/OutputShareService';
import { ToolSymbol } from '../../core/model/MediaTypes';
import { SystemSymbolIcon } from './SystemSymbolIcon';
import { Dt } from '../theme/DesignTokens';

@Component
export struct TaskCard {
  /** @State MediaTask[] 的数组项，使用 ObjectLink 才能跟踪 progress/state/message 的字段更新。 */
  @ObjectLink task: MediaTask;
  @State exporting: boolean = false;
  /** 横屏双列时提供删除入口（竖屏用左滑）。 */
  onRemove: () => void = () => {
  };

  private async saveOutput(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await OutputShareService.save(context, this.task.outputUri)) {
        this.getUIContext().getPromptAction().showToast({ message: '已保存到所选位置' });
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `保存失败：${(e as Error).message}` });
    } finally {
      this.exporting = false;
    }
  }

  private stopTask(): void {
    if (!TaskQueue.getInstance().cancel(this.task.id)) {
      this.getUIContext().getPromptAction().showToast({ message: '当前处理阶段暂不支持停止，请等待本阶段完成' });
    }
  }

  private async shareOutput(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await OutputShareService.show(context, this.task.outputUri, mediaTaskPrimaryTitle(this.task));
    } catch (e) {
      const error = e as Error;
      this.getUIContext().getPromptAction().showToast({ message: `无法分享：${error.message}` });
    }
  }

  /**
   * 原生胶囊按钮：ButtonType.Capsule，三列 layoutWeight 等宽。
   * 不用自定义方角容器，交给系统按钮形状。
   */
  @Builder
  OpButton(label: string, icon: ToolSymbol, emphasized: boolean, action: () => void) {
    Button({
      type: ButtonType.Capsule,
      stateEffect: true
    }) {
      Row({ space: 4 }) {
        SystemSymbolIcon({
          name: icon,
          iconSize: 16,
          color: emphasized ? Color.White : $r('app.color.text_primary')
        })
        Text(label)
          .fontSize(Dt.fontBody)
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .constraintSize({ minWidth: 0, maxWidth: '100%' })
    .height(40)
    .buttonStyle(emphasized ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
    .onClick(action)
  }

  stateLabel(): string {
    switch (this.task.state) {
      case TaskState.WAITING:
        return '等待中';
      case TaskState.RUNNING:
        return this.task.progress > 0 ? `处理中 ${Math.floor(this.task.progress)}%` : '正在准备';
      case TaskState.COMPLETED:
        return '已完成';
      case TaskState.FAILED:
        return '失败';
      case TaskState.CANCELING:
        return '正在停止';
      case TaskState.CANCELED:
        return '已取消';
      default:
        return '';
    }
  }

  stateColor(): ResourceColor {
    switch (this.task.state) {
      case TaskState.RUNNING:
        return $r('app.color.accent');
      case TaskState.COMPLETED:
        return $r('app.color.lossless_green');
      case TaskState.FAILED:
        return $r('app.color.danger_red');
      default:
        return $r('app.color.text_tertiary');
    }
  }

  build() {
    Column({ space: Dt.spaceMd }) {
      Row({ space: Dt.spaceSm }) {
        Column({ space: 2 }) {
          Text(this.task.actionTitle)
            .fontSize(Dt.fontSub)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // @Prop 深拷贝 / JSON 刷新后实例方法会丢，必须用纯函数读标题
          Text(mediaTaskSubTitle(this.task))
            .fontSize(Dt.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.stateLabel())
          .fontSize(Dt.fontCaption)
          .fontColor(this.stateColor())

        // 仅终态显示删除；活动中用停止
        if (this.task.state === TaskState.COMPLETED || this.task.state === TaskState.FAILED ||
          this.task.state === TaskState.CANCELED) {
          Button() {
            SystemSymbolIcon({ name: ToolSymbol.DELETE, iconSize: 18,
              color: $r('app.color.text_secondary') })
          }
          .type(ButtonType.Circle)
          .width(Dt.touchMin)
          .height(Dt.touchMin)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.onRemove())
        }
      }
      .width('100%')

      if (this.task.state === TaskState.RUNNING || this.task.state === TaskState.COMPLETED) {
        Progress({ value: this.task.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .color(this.stateColor())
      }
      if (this.task.message.length > 0) {
        Text(this.task.message)
          .fontSize(Dt.fontCaption)
          .fontColor(this.task.state === TaskState.FAILED ?
            $r('app.color.danger_red') : $r('app.color.text_secondary'))
          .width('100%')
      }

      if (this.task.state === TaskState.FAILED || this.task.state === TaskState.CANCELED) {
        Row({ space: Dt.spaceSm }) {
          this.OpButton('重试', ToolSymbol.RETRY, true,
            () => TaskQueue.getInstance().retry(this.task.id))
        }
        .width('100%')
      }
      if (this.task.state === TaskState.WAITING) {
        Row({ space: Dt.spaceSm }) {
          this.OpButton('取消', ToolSymbol.STOP, false,
            () => TaskQueue.getInstance().cancel(this.task.id))
        }
        .width('100%')
      }
      if (this.task.state === TaskState.RUNNING) {
        Row({ space: Dt.spaceSm }) {
          this.OpButton('停止', ToolSymbol.STOP, false, () => this.stopTask())
        }
        .width('100%')
      }
      if (this.task.state === TaskState.COMPLETED && this.task.outputUri.length > 0) {
        Row({ space: Dt.spaceSm }) {
          this.OpButton('保存', ToolSymbol.SHARE, true,
            () => this.saveOutput())
          this.OpButton('分享', ToolSymbol.SHARE, false,
            () => this.shareOutput())
          this.OpButton('再次运行', ToolSymbol.RETRY, false,
            () => TaskQueue.getInstance().reuse(this.task.id))
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
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
  }
}
