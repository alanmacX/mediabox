/**
 * 任务模型。
 * Batch & Queue 是"全功能 Box"的基础:多选文件 → 统一操作 → 任务队列。
 * 底层串行执行时,UI 如实呈现队列,不伪造并发(原则见项目简报 §12)。
 */

export enum TaskState {
  WAITING = 'WAITING',
  RUNNING = 'RUNNING',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  CANCELING = 'CANCELING',
  CANCELED = 'CANCELED'
}

/** 操作参数(目标码率 / 分辨率 / 目标体积预算等,由操作配置页写入)。 */
export interface TaskParams {
  /** 多输入任务的其余源文件；主输入仍使用 MediaTask.sourceUri。 */
  additionalSourceUris?: string[];
  additionalDisplayNames?: string[];
  /** 与全部输入一一对应；视频合并据此决定能否安全合并音轨。 */
  inputHasAudio?: boolean[];
  targetVideoKbps?: number;
  targetAudioKbps?: number;
  targetSampleRateHz?: number;
  targetChannels?: number;
  volumeMultiplier?: number;
  loudnessLufs?: number;
  truePeakDb?: number;
  loudnessRange?: number;
  peakLevel?: number;
  fadeInSeconds?: number;
  fadeOutSeconds?: number;
  silenceThresholdDb?: number;
  silenceDurationSeconds?: number;
  targetWidth?: number;
  targetHeight?: number;
  targetContainer?: string;
  targetVideoCodec?: string;
  targetBytes?: number;
  imageFormat?: string;
  imageQuality?: number;
  /** JPEG 等不支持透明通道时使用的 #RRGGBB 背景。 */
  imageBackgroundColor?: string;
  /** 重新编码时不复制 EXIF 等源属性。 */
  stripMetadata?: boolean;
  imageRotateDegrees?: number;
  imageFlipHorizontal?: boolean;
  imageFlipVertical?: boolean;
  cropX?: number;
  cropY?: number;
  cropWidth?: number;
  cropHeight?: number;
  targetFps?: number;
  startTime?: string;
  durationSeconds?: string;
  totalDurationSeconds?: number;
  loopCount?: string;
  speed?: number;
  timecode?: string;
  watermarkWidth?: number;
  watermarkPosition?: string;
  watermarkX?: number;
  watermarkY?: number;
  trackIndex?: number;
  streamKind?: string;
  subtitleDelaySeconds?: number;
  textOverlay?: string;
  textX?: number;
  textY?: number;
  /** 文字落点：TL/TR/BL/BR，缺省 BL（左下）。 */
  textCorner?: string;
  textFontSize?: number;
  textColor?: string;
  textCanvasWidth?: number;
  textCanvasHeight?: number;
  paletteColors?: number;
  metadataTitle?: string;
  metadataArtist?: string;
  metadataAlbumArtist?: string;
  metadataAlbum?: string;
  metadataAuthor?: string;
  metadataComposer?: string;
  metadataGenre?: string;
  metadataCreationTime?: string;
  trackTitle?: string;
  trackLanguage?: string;
}

/** UI/@Prop/JSON 反序列化后实例方法会丢失，标题一律走这些纯函数。 */
export function mediaTaskPrimaryTitle(task: MediaTask | undefined): string {
  if (task === undefined) {
    return '';
  }
  const out = task.outputName ?? '';
  if (out.length > 0) {
    return out;
  }
  return task.displayName ?? '';
}

export function mediaTaskSubTitle(task: MediaTask | undefined): string {
  return mediaTaskPrimaryTitle(task);
}

/** 把 preferences / JSON 克隆出的纯数据补成完整任务字段。 */
export function reviveMediaTask(src: MediaTask): MediaTask {
  const task = new MediaTask(
    src.id ?? '',
    src.sourceUri ?? '',
    src.displayName ?? '',
    src.actionId ?? '',
    src.actionTitle ?? '',
    src.params ?? {},
    src.createdAt ?? Date.now()
  );
  task.outputName = src.outputName ?? '';
  task.state = src.state ?? TaskState.WAITING;
  task.progress = typeof src.progress === 'number' && Number.isFinite(src.progress) ? src.progress : 0;
  task.outputUri = src.outputUri ?? '';
  task.message = src.message ?? '';
  return task;
}

/**
 * Merge queue data into the object already owned by ArkUI.
 *
 * ForEach reuses a child when its key is unchanged. Replacing an array item with
 * a freshly deserialized object therefore does not retarget an existing
 * TaskCard's @ObjectLink. Keep the view object's identity stable and mutate its
 * observed fields instead.
 */
export function updateMediaTaskSnapshot(target: MediaTask, src: MediaTask): void {
  target.sourceUri = src.sourceUri ?? '';
  target.displayName = src.displayName ?? '';
  target.outputName = src.outputName ?? '';
  target.actionId = src.actionId ?? '';
  target.actionTitle = src.actionTitle ?? '';
  target.state = src.state ?? TaskState.WAITING;
  target.progress = typeof src.progress === 'number' && Number.isFinite(src.progress) ? src.progress : 0;
  target.outputUri = src.outputUri ?? '';
  target.message = src.message ?? '';
  target.createdAt = src.createdAt ?? target.createdAt;
  target.params = src.params ?? {};
}

/** Reconcile by id while preserving every existing snapshot object's identity. */
export function reconcileMediaTaskSnapshots(current: MediaTask[], source: MediaTask[]): MediaTask[] {
  const existing = new Map<string, MediaTask>();
  for (const task of current) {
    existing.set(task.id, task);
  }
  const next: MediaTask[] = [];
  for (const task of source) {
    let snapshot = existing.get(task.id);
    if (snapshot === undefined) {
      snapshot = reviveMediaTask(task);
    } else {
      updateMediaTaskSnapshot(snapshot, task);
    }
    next.push(snapshot);
  }
  return next;
}

/**
 * 任务卡以 @ObjectLink 绑定数组项；必须由 ArkUI 观察该 class 的字段变化，
 * 否则 ForEach 按 id 复用卡片时，进度和终态只会在重建页面后才显示。
 */
@Observed
export class MediaTask {
  id: string;
  sourceUri: string;
  displayName: string;
  /** 产出文件名（完成后从 outputUri 推导）；列表优先展示这个 */
  outputName: string;
  actionId: string;
  actionTitle: string;
  state: TaskState;
  /** 0-100 */
  progress: number;
  outputUri: string;
  message: string;
  createdAt: number;
  params: TaskParams;

  constructor(id: string, sourceUri: string, displayName: string, actionId: string, actionTitle: string,
    params: TaskParams, createdAt: number) {
    this.id = id;
    this.sourceUri = sourceUri;
    this.displayName = displayName;
    this.outputName = '';
    this.actionId = actionId;
    this.actionTitle = actionTitle;
    this.state = TaskState.WAITING;
    this.progress = 0;
    this.outputUri = '';
    this.message = '';
    this.createdAt = createdAt;
    this.params = params ?? {};
  }

  /** 旧包历史任务可能没有 outputName，统一安全读取。 */
  safeOutputName(): string {
    return this.outputName ?? '';
  }

  /** 任务列表主标题：有产出用产出名，否则用源文件名。 */
  primaryTitle(): string {
    return mediaTaskPrimaryTitle(this);
  }

  /** 任务列表副标题：产出名或源文件名（防 undefined）。 */
  subTitle(): string {
    return mediaTaskSubTitle(this);
  }
}

/** 从沙箱路径 / URI 取产出文件名。 */
export function outputNameFromUri(uri: string): string {
  if (uri.length === 0) {
    return '';
  }
  const cut = uri.lastIndexOf('/');
  const last = cut >= 0 ? uri.substring(cut + 1) : uri;
  try {
    const decoded = decodeURIComponent(last);
    return decoded.length > 0 ? decoded : uri;
  } catch (e) {
    // 非法百分号编码的 URI：保留原始段，不让单个坏 URI 打断任务收尾
    return last.length > 0 ? last : uri;
  }
}

export interface TaskQueueListener {
  onQueueChanged(): void;
}

/** 每个可执行操作对应一个执行器实现。 */
export interface TaskExecutor {
  /** 返回输出文件 URI。 */
  execute(task: MediaTask, onProgress: (pct: number) => void): Promise<string>;
  /** 取消正在执行的任务；返回是否已向底层引擎提交取消请求。 */
  cancel?(taskId: string): boolean;
}
