/**
 * TaskQueue — 串行任务队列,配 Background Tasks Kit 长时任务保活。
 *
 * - 大文件转码开始后用户可以离开应用:运行期间申请媒体处理特殊场景长时任务,
 *   防止进程被挂起;队列空闲时立即释放。
 * - 持久化:preferences 存最近任务列表(JSON),重启后"最近任务"可见。
 * - Live View(实况窗)以一秒节流更新任务进度，不可用时自动降级。
 */
import { common } from '@kit.AbilityKit';
import { wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  MediaTask, TaskState, TaskParams, TaskQueueListener, TaskExecutor, outputNameFromUri,
  mediaTaskPrimaryTitle, reviveMediaTask
} from './MediaTask';
import { LiveViewProgress, QueuePosition } from './LiveViewProgress';

const TAG = 'TaskQueue';
const DOMAIN = 0x4D42;
const PREF_NAME = 'mediabox_tasks';
const PREF_KEY_HISTORY = 'history_v1';
const HISTORY_LIMIT = 50;
const PROGRESS_UI_INTERVAL_MS = 200;

export interface QueueStats {
  running: number;
  waiting: number;
  completed: number;
  failed: number;
  canceled: number;
}

export class TaskQueue {
  private static instance: TaskQueue | undefined;

  static getInstance(): TaskQueue {
    if (TaskQueue.instance === undefined) {
      TaskQueue.instance = new TaskQueue();
    }
    return TaskQueue.instance;
  }

  private tasks: MediaTask[] = [];
  private listeners: TaskQueueListener[] = [];
  private executor: TaskExecutor | undefined;
  private context: common.UIAbilityContext | undefined;
  private running = false;
  private ready = false;
  private queuePaused = false;
  private continuousTaskActive = false;
  private continuousTaskRequested = false;
  private store: preferences.Preferences | undefined = undefined;
  private liveView = new LiveViewProgress();
  /** 当前连续执行会话中的任务顺序；已完成项仍保留，保证胶囊稳定显示 1/N、2/N、3/N。 */
  private liveSessionTaskIds: string[] = [];
  private idSequence = 0;
  private lastProgressUiUpdateMs = 0;
  /**
   * 队列数据版本。引擎回调来自异步链路，页面不能只依赖一次 listener 通知；
   * 版本号让已显示的任务页可低成本确认自己是否落后于权威队列。
   */
  private revision = 0;

  /** EntryAbility onCreate 时调用。 */
  init(context: common.UIAbilityContext, executor: TaskExecutor): void {
    this.context = context;
    this.executor = executor;
    this.liveView.setApp(context?.abilityInfo?.bundleName ?? 'com.mediabox.app',
      context?.abilityInfo?.name ?? 'EntryAbility');
    preferences.getPreferences(context, PREF_NAME).then((store: preferences.Preferences) => {
      this.store = store;
      this.loadHistory(store);
      this.ready = true;
      this.notify();
      this.persist();
      this.scheduleNext();
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'load prefs failed %{public}s', err.message);
      this.ready = true;
      this.scheduleNext();
    });
  }

  private loadHistory(store: preferences.Preferences): void {
    const raw = store.getSync(PREF_KEY_HISTORY, '[]') as string;
    try {
      const arr = JSON.parse(raw) as MediaTask[];
      for (const rawTask of arr.reverse()) {
        // 反序列化是纯数据：revive 回 MediaTask，补齐字段并避免 UI 调实例方法崩溃
        const t = reviveMediaTask(rawTask);
        if (t.state === TaskState.RUNNING || t.state === TaskState.CANCELING) {
          t.state = TaskState.FAILED;
          t.message = '应用退出导致中断';
        }
        if (!this.tasks.some((existing: MediaTask) => existing.id === t.id)) {
          this.tasks.unshift(t);
        }
      }
      this.tasks.sort((a: MediaTask, b: MediaTask) => a.createdAt - b.createdAt);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'history parse failed');
    }
  }

  subscribe(listener: TaskQueueListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unsubscribe(listener: TaskQueueListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notify(): void {
    this.revision++;
    // 回调可能触发页面生命周期并退订；遍历快照避免跳过后续监听者。
    const listeners = this.listeners.slice();
    for (const l of listeners) {
      l.onQueueChanged();
    }
  }

  /** 只读快照版本，供页面补偿导航期间遗漏的观察者回调。 */
  currentRevision(): number {
    return this.revision;
  }

  list(): MediaTask[] {
    return this.tasks;
  }

  /** 队列统计:处理中 / 等待 / 完成 / 失败。 */
  stats(): QueueStats {
    let running = 0;
    let waiting = 0;
    let completed = 0;
    let failed = 0;
    let canceled = 0;
    for (const t of this.tasks) {
      if (t.state === TaskState.RUNNING || t.state === TaskState.CANCELING) {
        running++;
      } else if (t.state === TaskState.WAITING) {
        waiting++;
      } else if (t.state === TaskState.COMPLETED) {
        completed++;
      } else if (t.state === TaskState.FAILED) {
        failed++;
      } else if (t.state === TaskState.CANCELED) {
        canceled++;
      }
    }
    return { running: running, waiting: waiting, completed: completed, failed: failed, canceled: canceled };
  }

  /** 入队一批文件(同一操作),返回本批 taskId，随后自动开始调度。 */
  enqueue(sourceUris: string[], displayNames: string[], actionId: string, actionTitle: string,
    params: TaskParams): string[] {
    const now = Date.now();
    const ids: string[] = [];
    for (let i = 0; i < sourceUris.length; i++) {
      const id = `${now}_${this.idSequence++}_${i}`;
      ids.push(id);
      this.tasks.push(new MediaTask(id, sourceUris[i],
        i < displayNames.length ? displayNames[i] : sourceUris[i],
        actionId, actionTitle, this.cloneParams(params), now));
    }
    this.extendLiveSession(ids);
    this.notify();
    this.persist();
    this.scheduleNext();
    return ids;
  }

  private cloneParams(params: TaskParams): TaskParams {
    return JSON.parse(JSON.stringify(params)) as TaskParams;
  }

  /** 多输入组合任务：一个任务携带全部输入（sourceUri=首个，其余进 additionalSourceUris）。 */
  enqueueTaskGroup(sourceUris: string[], displayNames: string[], actionId: string, actionTitle: string,
    params: TaskParams): string {
    if (sourceUris.length === 0) {
      return '';
    }
    const now = Date.now();
    const id = `${now}_${this.idSequence++}_g0`;
    const task = new MediaTask(id, sourceUris[0],
      displayNames.length > 0 ? displayNames[0] : sourceUris[0], actionId, actionTitle,
      this.cloneParams(params), now);
    if (sourceUris.length > 1) {
      task.params.additionalSourceUris = sourceUris.slice(1);
      task.params.additionalDisplayNames = displayNames.slice(1);
    }
    this.tasks.push(task);
    this.extendLiveSession([id]);
    this.notify();
    this.persist();
    this.scheduleNext();
    return id;
  }

  cancel(taskId: string): boolean {
    const t = this.find(taskId);
    if (t !== undefined && t.state === TaskState.WAITING) {
      t.state = TaskState.CANCELED;
      t.message = '已取消';
      this.removeFromLiveSession(taskId);
      this.notify();
      this.persist();
      return true;
    } else if (t !== undefined && t.state === TaskState.RUNNING && this.executor?.cancel !== undefined &&
      this.executor.cancel(taskId)) {
      t.state = TaskState.CANCELING;
      t.message = '正在停止，等待引擎释放资源';
      this.notify();
      this.persist();
      return true;
    }
    return false;
  }

  retry(taskId: string): void {
    const t = this.find(taskId);
    if (t !== undefined && (t.state === TaskState.FAILED || t.state === TaskState.CANCELED)) {
      t.state = TaskState.WAITING;
      t.progress = 0;
      t.message = '';
      t.outputUri = '';
      t.outputName = '';
      this.extendLiveSession([t.id]);
      this.notify();
      this.persist();
      this.scheduleNext();
    }
  }

  /** 使用相同来源和参数创建新任务，不修改历史记录。 */
  reuse(taskId: string): void {
    const source = this.find(taskId);
    if (source === undefined) {
      return;
    }
    const now = Date.now();
    this.tasks.push(new MediaTask(`${now}_${this.idSequence++}_reuse`, source.sourceUri, source.displayName,
      source.actionId, source.actionTitle, this.cloneParams(source.params), now));
    this.extendLiveSession([this.tasks[this.tasks.length - 1].id]);
    this.notify();
    this.persist();
    this.scheduleNext();
  }

  clearFinished(): void {
    this.tasks = this.tasks.filter((t: MediaTask) => t.state === TaskState.WAITING ||
      t.state === TaskState.RUNNING || t.state === TaskState.CANCELING);
    this.notify();
    this.persist();
  }

  /**
   * 删除记录。WAITING 尚未进入执行器，可原子移除；
   * RUNNING/CANCELING 必须等执行器落到终态。
   * @returns 'ok' | 'not_found' | 'busy'
   */
  removeTask(taskId: string): string {
    const task = this.find(taskId);
    if (task === undefined) {
      return 'not_found';
    }
    if (task.state === TaskState.RUNNING || task.state === TaskState.CANCELING) {
      return 'busy';
    }
    // WAITING 尚未交给执行器，可以直接从队列移除。不要先 cancel 再 delete
    // 连续发出两个中间态通知，否则 UI 会短暂复活已经删除的卡片。
    this.tasks = this.tasks.filter((t: MediaTask) => t.id !== taskId);
    this.removeFromLiveSession(taskId);
    this.notify();
    this.persist();
    return 'ok';
  }

  pause(): void {
    this.queuePaused = true;
    this.notify();
  }

  resume(): void {
    if (!this.queuePaused) {
      return;
    }
    this.queuePaused = false;
    this.notify();
    this.scheduleNext();
  }

  isPaused(): boolean {
    return this.queuePaused;
  }

  /** Ability 真正销毁时结束系统外显，避免进程退出后留下“处理中”的孤儿实况窗。 */
  onAbilityDestroy(): void {
    this.liveSessionTaskIds = [];
    this.liveView.stop('应用已关闭，处理已中断', false, false);
    this.releaseContinuousTask();
  }

  private find(id: string): MediaTask | undefined {
    for (const t of this.tasks) {
      if (t.id === id) {
        return t;
      }
    }
    return undefined;
  }

  /** 实况窗用的队列位置：按创建顺序统计排队 + 运行中的任务。 */
  private queuePosition(task: MediaTask): QueuePosition {
    const found = this.liveSessionTaskIds.indexOf(task.id);
    return {
      index: found >= 0 ? found + 1 : 1,
      total: Math.max(this.liveSessionTaskIds.length, 1)
    };
  }

  private ensureLiveSession(): void {
    if (this.liveSessionTaskIds.length > 0) {
      return;
    }
    this.liveSessionTaskIds = this.tasks
      .filter((t: MediaTask) => t.state === TaskState.WAITING || t.state === TaskState.RUNNING ||
        t.state === TaskState.CANCELING)
      .sort((a: MediaTask, b: MediaTask) => a.createdAt - b.createdAt)
      .map((t: MediaTask) => t.id);
  }

  /** 执行期间追加的新任务归入同一 island，并只会扩大该会话的总数。 */
  private extendLiveSession(ids: string[]): void {
    if (this.liveSessionTaskIds.length === 0 || !this.running) {
      return;
    }
    for (const id of ids) {
      if (this.liveSessionTaskIds.indexOf(id) < 0) {
        this.liveSessionTaskIds.push(id);
      }
    }
  }

  private removeFromLiveSession(id: string): void {
    const index = this.liveSessionTaskIds.indexOf(id);
    if (index >= 0) {
      this.liveSessionTaskIds.splice(index, 1);
    }
  }

  /** 串行调度。 */
  private scheduleNext(): void {
    if (!this.ready || this.running || this.queuePaused) {
      if (!this.running) {
        this.releaseContinuousTask();
      }
      return;
    }
    let next: MediaTask | undefined = undefined;
    for (const t of this.tasks) {
      if (t.state === TaskState.WAITING) {
        next = t;
        break;
      }
    }
    if (next === undefined) {
      this.releaseContinuousTask();
      return;
    }
    const task: MediaTask = next;
    this.running = true;
    this.lastProgressUiUpdateMs = 0;
    task.state = TaskState.RUNNING;
    task.progress = 0;
    task.message = '正在准备媒体文件';
    this.ensureLiveSession();
    this.notify();
    this.persist();
    this.acquireContinuousTask();
    this.liveView.start(task, this.queuePosition(task));

    const executor = this.executor;
    if (executor === undefined) {
      task.state = TaskState.FAILED;
      task.message = '引擎未初始化';
      this.running = false;
      this.notify();
      this.persist();
      const hasMore = !this.queuePaused && this.tasks.some((t: MediaTask) => t.state === TaskState.WAITING);
      this.liveView.stop(task.message, false, hasMore);
      if (!hasMore) {
        this.liveSessionTaskIds = [];
      }
      this.scheduleNext();
      return;
    }
    Promise.resolve().then(() => executor.execute(task, (pct: number) => {
      if (task.state !== TaskState.RUNNING || !Number.isFinite(pct)) {
        return;
      }
      task.progress = Math.max(task.progress, Math.min(99, Math.max(0, pct)));
      // 0~11% 保留为准备阶段（选择器文件暂存或系统编解码器资源申请），
      // 12% 起才代表已经进入实际读写/编码。
      if (task.progress >= 12) {
        task.message = '';
      }
      this.liveView.update(pct, this.queuePosition(task));
      // FFmpeg 可能一秒回调数百次。每次都触发任务页 JSON 深拷贝和整页重组会反过来
      // 占满 ArkUI JS 线程，造成“前台卡住、切到后台又完成”的假死现象。
      const now = Date.now();
      if (pct >= 99 || now - this.lastProgressUiUpdateMs >= PROGRESS_UI_INTERVAL_MS) {
        this.lastProgressUiUpdateMs = now;
        this.notify();
      }
    })).then((outputUri: string) => {
      // 取消/超时后，底层回调可能晚到；不能把失败任务重新标为完成。
      if (task.state === TaskState.RUNNING) {
        task.state = TaskState.COMPLETED;
        task.progress = 100;
        task.outputUri = outputUri;
        task.outputName = outputNameFromUri(outputUri);
        task.message = '';
      }
    }).catch((e: Error) => {
      if (task.state === TaskState.CANCELING) {
        task.message = '已取消';
      } else {
        task.state = TaskState.FAILED;
        task.message = e.message;
      }
    }).then(() => {
      if (task.state === TaskState.CANCELING) {
        task.state = TaskState.CANCELED;
        task.message = '已取消';
      }
      const liveTitle = task.state === TaskState.COMPLETED ? mediaTaskPrimaryTitle(task) : task.message;
      // 队列还有排队任务时实况窗不销毁，由下一个任务的 start() 换 stage 接管
      const hasMore = !this.queuePaused && this.tasks.some((t: MediaTask) => t.state === TaskState.WAITING);
      this.liveView.stop(liveTitle, task.state === TaskState.COMPLETED, hasMore);
      if (!hasMore) {
        this.liveSessionTaskIds = [];
      }
      this.running = false;
      this.notify();
      this.persist();
      this.scheduleNext();
    });
  }

  /** API 24 媒体处理专用长时任务：特殊场景模式 + 媒体处理通知子模式。 */
  private acquireContinuousTask(): void {
    if (this.continuousTaskActive || this.continuousTaskRequested || this.context === undefined) {
      return;
    }
    this.continuousTaskRequested = true;
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent: object) => {
      if (this.context === undefined) {
        this.continuousTaskRequested = false;
        return;
      }
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_SPECIAL_SCENARIO_PROCESSING];
      request.backgroundTaskSubmodes = [
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_MEDIA_PROCESS_NORMAL_NOTIFICATION
      ];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      request.continuousTaskId = -1;
      request.checkSpecialScenarioAuth(this.context).then((result: backgroundTaskManager.UserAuthResult) => {
        if (result === backgroundTaskManager.UserAuthResult.GRANTED_ALWAYS ||
          result === backgroundTaskManager.UserAuthResult.GRANTED_ONCE) {
          this.startContinuousRequest(request);
        } else if (result === backgroundTaskManager.UserAuthResult.NOT_DETERMINED && this.context !== undefined) {
          request.requestAuthFromUser(this.context, (authResult: backgroundTaskManager.UserAuthResult) => {
            if (authResult === backgroundTaskManager.UserAuthResult.GRANTED_ALWAYS ||
              authResult === backgroundTaskManager.UserAuthResult.GRANTED_ONCE) {
              this.startContinuousRequest(request);
            } else {
              this.continuousTaskRequested = false;
            }
          });
        } else {
          this.continuousTaskRequested = false;
        }
      }).catch((err: Error) => {
        this.continuousTaskRequested = false;
        hilog.warn(DOMAIN, TAG, 'background authorization failed %{public}s', err.message);
      });
    }).catch((err: Error) => {
      this.continuousTaskRequested = false;
      hilog.warn(DOMAIN, TAG, 'wantAgent failed %{public}s', err.message);
    });
  }

  private startContinuousRequest(request: backgroundTaskManager.ContinuousTaskRequest): void {
    if (this.context === undefined) {
      this.continuousTaskRequested = false;
      return;
    }
    backgroundTaskManager.startBackgroundRunning(this.context, request).then(() => {
      this.continuousTaskRequested = false;
      this.continuousTaskActive = true;
      hilog.info(DOMAIN, TAG, 'media processing continuous task started');
      if (!this.running) {
        this.releaseContinuousTask();
      }
    }).catch((err: Error) => {
      this.continuousTaskRequested = false;
      hilog.warn(DOMAIN, TAG, 'continuous task refused %{public}s', err.message);
    });
  }

  private releaseContinuousTask(): void {
    this.continuousTaskRequested = false;
    if (!this.continuousTaskActive || this.context === undefined) {
      return;
    }
    this.continuousTaskActive = false;
    backgroundTaskManager.stopBackgroundRunning(this.context).then(() => {
      hilog.info(DOMAIN, TAG, 'continuous task stopped');
    }).catch((err: Error) => {
      this.continuousTaskActive = true;
      hilog.warn(DOMAIN, TAG, 'stop continuous task failed %{public}s', err.message);
    });
  }

  private persist(): void {
    if (this.store === undefined) {
      return;
    }
    const active = this.tasks.filter((t: MediaTask) => t.state === TaskState.WAITING ||
      t.state === TaskState.RUNNING || t.state === TaskState.CANCELING);
    const finished = this.tasks.filter((t: MediaTask) => t.state === TaskState.COMPLETED ||
      t.state === TaskState.FAILED || t.state === TaskState.CANCELED).slice(-HISTORY_LIMIT);
    const keep = active.concat(finished);
    try {
      this.store.putSync(PREF_KEY_HISTORY, JSON.stringify(keep));
      this.store.flush().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'flush failed %{public}s', err.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persist failed');
    }
  }
}
