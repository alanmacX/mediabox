/**
 * 会话与草稿：文件选择、工具参数、最近提交任务。
 */
import { image } from '@kit.ImageKit';
import { AnalysisResult, PickedFile } from '../../core/analyze/MediaAnalyzer';
import { ToolAction } from '../../core/model/MediaTypes';
import { TaskParams } from '../../core/task/MediaTask';

export class WorkbenchSession {
  static picked?: PickedFile;
  static pickedFiles: PickedFile[] = [];
  static batchIntent: string = '';
  static result?: AnalysisResult;
  /** 当前会话预览缩略图（工作台 / 配置页共用）。 */
  static thumbnail?: image.PixelMap;
  /** 预览图沙箱 URI：@Prop 传 PixelMap 在部分设备渲染异常，统一走文件 URI。 */
  static previewUri?: string;
  static sharedPending: boolean = false;
  static pendingAction?: ToolAction;
  static pendingTargetSizeActionId: string = '';
  /** 最近一次提交的 taskId，任务页据此高亮。 */
  static lastTaskIds: string[] = [];
  /** 工具参数草稿：mediaUri|actionId → params */
  private static drafts: Map<string, TaskParams> = new Map();

  static draftKey(mediaUri: string, actionId: string): string {
    return `${mediaUri}|${actionId}`;
  }

  static saveDraft(mediaUri: string, actionId: string, params: TaskParams): void {
    WorkbenchSession.drafts.set(WorkbenchSession.draftKey(mediaUri, actionId), params);
  }

  static loadDraft(mediaUri: string, actionId: string): TaskParams | undefined {
    return WorkbenchSession.drafts.get(WorkbenchSession.draftKey(mediaUri, actionId));
  }

  static clearDraftsForMedia(mediaUri: string): void {
    const prefix = `${mediaUri}|`;
    const keys: string[] = [];
    for (const k of WorkbenchSession.drafts.keys()) {
      if (k.startsWith(prefix)) {
        keys.push(k);
      }
    }
    for (const k of keys) {
      WorkbenchSession.drafts.delete(k);
    }
  }

  static clear(): void {
    WorkbenchSession.picked = undefined;
    WorkbenchSession.pickedFiles = [];
    WorkbenchSession.batchIntent = '';
    WorkbenchSession.result = undefined;
    WorkbenchSession.thumbnail = undefined;
    WorkbenchSession.previewUri = undefined;
    WorkbenchSession.sharedPending = false;
    WorkbenchSession.pendingAction = undefined;
    WorkbenchSession.pendingTargetSizeActionId = '';
    WorkbenchSession.lastTaskIds = [];
  }
}

export class RouteNames {
  static readonly WORKBENCH: string = 'Workbench';
  static readonly BATCH: string = 'BatchWorkbench';
  static readonly MEDIA_INFO: string = 'MediaInfo';
  static readonly TASK_PROGRESS: string = 'TaskProgress';
  static readonly TOOL_CONFIG: string = 'ToolConfig';
  static readonly BENCH_HISTORY: string = 'BenchHistory';
  static readonly BENCH_DETAIL: string = 'BenchDetail';
  static readonly BENCH_INFO: string = 'BenchInfo';
}
