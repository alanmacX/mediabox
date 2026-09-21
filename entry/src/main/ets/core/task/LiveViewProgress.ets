/**
 * 长任务实况窗进度桥接。
 * 官方接口要求限制更新频率；这里按至少一秒一次合并进度，设备未开放实况窗权益时自动降级。
 *
 * 核心约定：
 * - 全应用只有一个实况窗（FIXED_LIVE_VIEW_ID）。每个任务复用它：首个任务 startLiveView，
 *   后续任务（含应用重启后系统残留的旧窗）改用 updateLiveView 接管，杜绝多窗堆积。
 * - 队列串行：任务完成时若仍有排队任务则不 stop（下一个 start 会换 stage 接管），
 *   队列空闲才真正 stopLiveView。
 * - 显示规则：单任务胶囊「45% · 转码中」；多任务排队胶囊「2/5 · 转码 45%」，
 *   卡片副文本统一「队列 i/N · 已处理 x%」（单任务省略队列段）。
 *
 * 素材依赖（entry/src/main/resources/rawfile）：node1/2/3.png。
 * node1 同时用作胶囊徽标（须 ≤30KB，当前为 168px 应用前景图）。
 * LAYOUT_TYPE_PROGRESS 与胶囊的 icon/nodeIcons 均为必填，缺省会 401 拒绝。
 */
import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaTask } from './MediaTask';

const DOMAIN = 0x4D42;
const TAG = 'LiveViewProgress';
/** 全应用唯一的实况窗 id：固定值保证重启后能接管系统残留的旧窗，不会堆积多窗。 */
const FIXED_LIVE_VIEW_ID = 0x4D42;
/** 单个任务先观察一段时间，短于此阈值不打扰用户；队列任务立即展示。 */
const SINGLE_TASK_LIVE_VIEW_DELAY_MS = 3000;

/** 队列位置：第 index 个 / 共 total 个（仅统计排队与运行中的任务）。 */
export interface QueuePosition {
  index: number;
  total: number;
}

interface StageCopy {
  /** 卡片标题动词，如「正在转码」。 */
  verb: string;
  /** 多任务胶囊副文本动词，≤4 字，如「转码」。 */
  short: string;
  /** 单任务胶囊副文本，≤6 个中文字符。 */
  capsule: string;
}

interface StageRule {
  prefix: string;
  verb: string;
  short: string;
  capsule: string;
}

/** 按 actionId 前缀把全部操作归类到各自的 stage 文案（顺序敏感，先专后泛）。 */
const STAGE_BY_PREFIX: StageRule[] = [
  { prefix: 'to_gif', verb: '正在生成 GIF', short: '生成 GIF', capsule: '生成 GIF' },
  { prefix: 'gif_', verb: '正在生成 GIF', short: '生成 GIF', capsule: '生成 GIF' },
  { prefix: 'moving_photo_gif', verb: '正在生成 GIF', short: '生成 GIF', capsule: '生成 GIF' },
  { prefix: 'video_remux', verb: '正在转封装', short: '转封装', capsule: '转封装中' },
  { prefix: 'remux_', verb: '正在转封装', short: '转封装', capsule: '转封装中' },
  { prefix: 'extract_audio', verb: '正在提取音频', short: '提取音频', capsule: '提取音频' },
  { prefix: 'moving_photo_', verb: '正在导出', short: '导出', capsule: '导出中' },
  { prefix: 'video_snapshot', verb: '正在截图', short: '截图', capsule: '截图中' },
  { prefix: 'media_info', verb: '正在分析', short: '分析', capsule: '分析中' },
  { prefix: 'image_metadata', verb: '正在分析', short: '分析', capsule: '分析中' },
  { prefix: 'silence_', verb: '正在分析', short: '分析', capsule: '分析中' },
  { prefix: 'subtitle_', verb: '正在处理字幕', short: '处理字幕', capsule: '处理字幕' },
  { prefix: 'audio_', verb: '正在处理音频', short: '处理音频', capsule: '处理音频' },
  { prefix: 'image_', verb: '正在处理图片', short: '处理图片', capsule: '处理图片' },
  { prefix: 'video_', verb: '正在转码', short: '转码', capsule: '转码中' },
  { prefix: 'preset_', verb: '正在转码', short: '转码', capsule: '转码中' },
  { prefix: 'compress_', verb: '正在转码', short: '转码', capsule: '转码中' },
  { prefix: 'convert_', verb: '正在转码', short: '转码', capsule: '转码中' }
];

function stageFor(task: MediaTask): StageCopy {
  const id = task.actionId ?? '';
  for (const rule of STAGE_BY_PREFIX) {
    if (id.startsWith(rule.prefix)) {
      return { verb: rule.verb, short: rule.short, capsule: rule.capsule };
    }
  }
  const title = task.actionTitle ?? '';
  if (title.length > 0) {
    return { verb: `正在${title}`, short: title, capsule: `${title}中` };
  }
  return { verb: '正在处理', short: '处理', capsule: '处理中' };
}

const FALLBACK_STAGE: StageCopy = { verb: '正在处理', short: '处理', capsule: '处理中' };

export class LiveViewProgress {
  private view?: liveViewManager.LiveView;
  private stage: StageCopy = FALLBACK_STAGE;
  private enabled = false;
  private lastUpdateMs = 0;
  private lastProgress = -1;
  private desiredProgress = 0;
  private desiredVersion = 0;
  private appliedVersion = 0;
  private updateQueued = false;
  /** 当前队列会话是否已在系统中建立过固定 id；用户删除后本会话不再强行重建。 */
  private sessionEstablished = false;
  private startGeneration = 0;
  private pendingStarts = 0;
  private singleTaskTimer: number | undefined = undefined;
  private currentTask?: MediaTask;
  private pos: QueuePosition = { index: 1, total: 1 };
  /** 与系统中固定 id 的实况窗序列同步，所有 update/stop 都严格递增。 */
  private sequence = 0;
  private bundleName = 'com.mediabox.app';
  private abilityName = 'EntryAbility';
  private agent?: WantAgent;
  /** 操作串行链：start/update/stop 全部排队执行，避免异步交叠产生多窗或乱序。 */
  private opChain: Promise<void> = Promise.resolve();

  /** 由 TaskQueue 注入真实应用信息，避免 WantAgent 指向错误的 Ability。 */
  setApp(bundleName: string, abilityName: string): void {
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }

  /** 任务开始：重置 stage 与进度，并在串行链上接管实况窗。 */
  start(task: MediaTask, pos?: QueuePosition): void {
    if (!canIUse('SystemCapability.LiveView.LiveViewService')) {
      return;
    }
    const nextPos = pos ?? { index: 1, total: 1 };
    const nextStage = stageFor(task);
    this.currentTask = task;
    this.pos = { index: nextPos.index, total: nextPos.total };
    this.stage = nextStage;
    this.lastProgress = -1;
    this.desiredProgress = 0;
    const version = ++this.desiredVersion;
    const generation = ++this.startGeneration;
    // 把任务、阶段和位置做成不可变快照。后续任务即使在系统 API await 期间启动，
    // 也不能篡改当前 create/update 命令的数据。
    const begin = (): void => {
      if (generation !== this.startGeneration) {
        return;
      }
      this.singleTaskTimer = undefined;
      this.pendingStarts++;
      this.enqueue(async (): Promise<void> => {
        try {
          await this.takeOver(task, nextStage, nextPos, version, generation);
        } finally {
          this.pendingStarts = Math.max(0, this.pendingStarts - 1);
        }
      });
    };
    if (nextPos.total > 1) {
      begin();
    } else {
      this.singleTaskTimer = setTimeout(begin, SINGLE_TASK_LIVE_VIEW_DELAY_MS);
    }
  }

  update(progress: number, pos?: QueuePosition): void {
    if (!Number.isFinite(progress)) {
      return;
    }
    const posChanged = pos !== undefined && (pos.index !== this.pos.index || pos.total !== this.pos.total);
    if (pos !== undefined) {
      this.pos = { index: pos.index, total: pos.total };
    }
    const progressChanged = progress > this.lastProgress;
    if (!progressChanged && !posChanged) {
      return;
    }
    if (progressChanged) {
      // 进度 100% 会让系统自动结束进度型实况窗；100 只在 stop() 里下发
      this.desiredProgress = Math.min(99, Math.max(this.desiredProgress, Math.round(progress)));
    }
    this.desiredVersion++;
    // 即使 startLiveView 尚未返回也保留最新进度；命令会排在 create 之后执行，
    // 消除“短任务已完成、实况窗才刚创建”的竞态。
    this.scheduleFlush();
  }

  /**
   * 任务终态。hasMore=true 表示队列还有排队任务：不 stop，实况窗由下一个任务的
   * start() 换 stage 接管；hasMore=false 且队列空闲才真正 stopLiveView。
   */
  stop(message: string, successful: boolean, hasMore: boolean = false): void {
    if (hasMore) {
      // 同一队列的下一项继续复用固定 id；绝不 stop/start 产生第二个 island。
      return;
    }
    if (this.singleTaskTimer !== undefined) {
      ++this.startGeneration;
      clearTimeout(this.singleTaskTimer);
      this.singleTaskTimer = undefined;
    }
    ++this.desiredVersion;
    // 单个短任务在延迟窗口内完成：从未向系统创建实况窗，也无需查询/结束。
    if (!this.sessionEstablished && this.pendingStarts === 0 && !this.enabled && this.view === undefined) {
      this.resetLocalState();
      return;
    }
    this.enqueue(async (): Promise<void> => {
      let view = this.view;
      if (view === undefined) {
        try {
          view = await liveViewManager.getActiveLiveView(FIXED_LIVE_VIEW_ID);
        } catch (e) {
          // start 失败或系统中本来就没有该 id，结束操作已天然完成。
          this.resetLocalState();
          return;
        }
      }
      this.adoptSequence(view.sequence);
      view.sequence = this.nextSequence();
      view.liveViewData.primary.title = successful ? '处理完成' : '处理已结束';
      view.liveViewData.primary.content = [{ text: message }];
      view.liveViewData.capsule = {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
        status: 1,
        icon: 'node1.png',
        title: successful ? '完成' : '结束',
        content: successful ? '已保存' : '',
        backgroundColor: '#FF0A0A0A'
      };
      // keepTime 归零立即释放 id；>0 会让同 id 在保留期内 start 报 already exists、update 报 has ended
      view.liveViewData.primary.keepTime = 0;
      if (successful) {
        (view.liveViewData.primary.layoutData as liveViewManager.ProgressLayout).progress = 100;
      }
      await this.waitForUpdateSlot();
      try {
        await liveViewManager.stopLiveView(view);
      } catch (e) {
        if (this.errorCode(e) === 1003500008) {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 1200));
          view.sequence = this.nextSequence();
          await liveViewManager.stopLiveView(view);
        } else {
          throw new Error((e as Error).message);
        }
      }
      this.resetLocalState();
    });
  }

  private nextSequence(): number {
    return ++this.sequence;
  }

  /** 固定 id 先查询再决定 update/start，是“最多一个 island”的系统级保证。 */
  private async takeOver(task: MediaTask, stage: StageCopy, pos: QueuePosition, version: number,
    generation: number): Promise<void> {
    try {
      if (!await liveViewManager.isLiveViewEnabled()) {
        return;
      }
      if (generation !== this.startGeneration) {
        return;
      }
      if (this.agent === undefined) {
        this.agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: this.bundleName, abilityName: this.abilityName }],
          operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
      }
      if (generation !== this.startGeneration) {
        return;
      }
      const view = this.buildView(task, stage, pos, 0);
      view.liveViewData.primary.clickAction = this.agent;
      try {
        const active = await liveViewManager.getActiveLiveView(FIXED_LIVE_VIEW_ID);
        this.adoptSequence(active.sequence);
        view.sequence = this.nextSequence();
        await this.waitForUpdateSlot();
        await liveViewManager.updateLiveView(view);
        hilog.info(DOMAIN, TAG, 'live view reused id=%{public}d', FIXED_LIVE_VIEW_ID);
      } catch (e) {
        if (this.errorCode(e) !== 1003500009) {
          throw new Error((e as Error).message);
        }
        if (this.sessionEstablished) {
          // 官方规定用户删除实况窗后，后续更新不应再次展示。本会话静默降级，
          // 等下一个全新队列会话才允许重新 start。
          this.enabled = false;
          this.view = undefined;
          return;
        }
        view.sequence = this.nextSequence();
        try {
          await liveViewManager.startLiveView(view);
          this.sessionEstablished = true;
          hilog.info(DOMAIN, TAG, 'live view started id=%{public}d', FIXED_LIVE_VIEW_ID);
        } catch (startError) {
          // get 与 start 之间如果被另一调用创建，重新查询并接管固定 id。
          if (this.errorCode(startError) !== 1003500006) {
            throw new Error((startError as Error).message);
          }
          const active = await liveViewManager.getActiveLiveView(FIXED_LIVE_VIEW_ID);
          this.adoptSequence(active.sequence);
          view.sequence = this.nextSequence();
          await this.waitForUpdateSlot();
          await liveViewManager.updateLiveView(view);
          this.sessionEstablished = true;
        }
      }
      this.sessionEstablished = true;
      this.view = view;
      this.enabled = true;
      this.lastProgress = 0;
      this.lastUpdateMs = Date.now();
      this.appliedVersion = Math.max(this.appliedVersion, version);
      if (this.desiredVersion > this.appliedVersion) {
        this.scheduleFlush();
      }
    } catch (e) {
      // 权益未开通(1003500005)/参数/能力缺失时只降级应用内进度，不影响任务执行。
      hilog.info(DOMAIN, TAG, 'live view unavailable code=%{public}d %{public}s',
        this.errorCode(e), (e as Error).message ?? '');
      this.enabled = false;
      this.view = undefined;
    }
  }

  private scheduleFlush(): void {
    if (this.updateQueued) {
      return;
    }
    this.updateQueued = true;
    this.enqueue(async (): Promise<void> => {
      try {
        await this.waitForUpdateSlot();
        await this.applyDesired();
      } finally {
        this.updateQueued = false;
        if (this.enabled && this.desiredVersion > this.appliedVersion) {
          this.scheduleFlush();
        }
      }
    });
  }

  private async applyDesired(): Promise<void> {
    if (!this.enabled || this.view === undefined || this.currentTask === undefined ||
      this.desiredVersion <= this.appliedVersion) {
      return;
    }
    const version = this.desiredVersion;
    const progress = this.desiredProgress;
    const view = this.buildView(this.currentTask, this.stage, this.pos, progress);
    view.liveViewData.primary.clickAction = this.agent;
    view.sequence = this.nextSequence();
    try {
      await liveViewManager.updateLiveView(view);
    } catch (e) {
      if (this.errorCode(e) === 1003500011) {
        const active = await liveViewManager.getActiveLiveView(FIXED_LIVE_VIEW_ID);
        this.adoptSequence(active.sequence);
        view.sequence = this.nextSequence();
        await liveViewManager.updateLiveView(view);
      } else {
        throw new Error((e as Error).message);
      }
    }
    this.view = view;
    this.lastProgress = progress;
    this.lastUpdateMs = Date.now();
    this.appliedVersion = version;
  }

  private enqueue(operation: () => Promise<void>): void {
    const op = this.opChain.then(operation);
    this.opChain = op.catch((e: Error): void => {
      hilog.info(DOMAIN, TAG, 'operation skipped code=%{public}d %{public}s',
        this.errorCode(e), e.message ?? '');
    });
  }

  private async waitForUpdateSlot(): Promise<void> {
    const waitMs = 1050 - (Date.now() - this.lastUpdateMs);
    if (waitMs > 0) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, waitMs));
    }
  }

  private adoptSequence(value?: number): void {
    if (value !== undefined && value >= 0 && value < 4294967295) {
      this.sequence = Math.max(this.sequence, value);
    }
  }

  private errorCode(error: Object): number {
    const businessError = error as BusinessError;
    return Number.isFinite(businessError.code) ? businessError.code : 0;
  }

  private resetLocalState(): void {
    this.view = undefined;
    this.enabled = false;
    this.currentTask = undefined;
    this.sessionEstablished = false;
    this.pendingStarts = 0;
    if (this.singleTaskTimer !== undefined) {
      clearTimeout(this.singleTaskTimer);
      this.singleTaskTimer = undefined;
    }
    this.lastProgress = -1;
    this.desiredProgress = 0;
    this.lastUpdateMs = 0;
    this.appliedVersion = this.desiredVersion;
  }

  private buildView(task: MediaTask, stage: StageCopy, pos: QueuePosition,
    progress: number): liveViewManager.LiveView {
    return {
      id: FIXED_LIVE_VIEW_ID,
      event: 'PROGRESS',
      sequence: 0,
      isMute: true,
      liveViewData: {
        primary: {
          title: `${stage.verb} ${task.primaryTitle()}`,
          content: [{ text: this.cardSub(progress, pos) }],
          keepTime: 0,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: progress,
            color: '#FF317AF7',
            backgroundColor: '#33317AF7',
            lineType: liveViewManager.LineType.LINE_TYPE_THICK_SOLID_LINE,
            nodeIcons: ['node1.png', 'node2.png', 'node3.png']
          }
        },
        capsule: this.buildCapsule(progress, stage, pos)
      }
    };
  }

  private buildCapsule(progress: number, stage: StageCopy = this.stage,
    pos: QueuePosition = this.pos): liveViewManager.TextCapsule {
    // 单任务：主文本百分比；多任务排队：主文本队列序号、副文本带百分比
    const main = pos.total > 1 ? `${pos.index}/${pos.total}` : `${progress}%`;
    const sub = pos.total > 1 ? `${stage.short} ${progress}%` : stage.capsule;
    return {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
      status: 1,
      icon: 'node1.png',
      title: main,
      content: sub,
      backgroundColor: '#FF0A0A0A'
    };
  }

  private cardSub(progress: number, pos: QueuePosition = this.pos): string {
    if (pos.total > 1) {
      return `队列 ${pos.index}/${pos.total} · 已处理 ${progress}%`;
    }
    return progress > 0 ? `已处理 ${progress}%` : '正在准备';
  }
}
