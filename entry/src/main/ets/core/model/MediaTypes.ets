/**
 * 媒体类型与分析结果模型。
 * File First:一切功能的入口是"用户选中的文件",本文件定义 Analyzer 的输出契约。
 */

export enum MediaType {
  IMAGE = 'IMAGE',
  GIF = 'GIF',
  VIDEO = 'VIDEO',
  AUDIO = 'AUDIO',
  SUBTITLE = 'SUBTITLE',
  UNKNOWN = 'UNKNOWN'
}

/** 处理引擎归属:CapabilityRouter 依据它决定路由到原生管线还是 FFmpeg。 */
export enum EngineKind {
  /** HarmonyOS 原生能力(Image Kit / AVTranscoder / AVCodec),硬件加速优先 */
  NATIVE = 'NATIVE',
  /** FFmpeg(冷门格式 / Remux / GIF / 高级滤镜) */
  FFMPEG = 'FFMPEG',
  /** 原生不可行时回落 FFmpeg */
  FFMPEG_FALLBACK = 'FFMPEG_FALLBACK'
}

/** UI 使用的系统 Symbol 语义名。实际资源统一由 SystemSymbolIcon 映射。 */
export enum ToolSymbol {
  HOME = 'HOME',
  TASKS = 'TASKS',
  VIDEO = 'VIDEO',
  AUDIO = 'AUDIO',
  GIF = 'GIF',
  IMAGE = 'IMAGE',
  FILE = 'FILE',
  CONVERT = 'CONVERT',
  COMPRESS = 'COMPRESS',
  TARGET = 'TARGET',
  EDIT = 'EDIT',
  RESIZE = 'RESIZE',
  INFO = 'INFO',
  NORMALIZE = 'NORMALIZE',
  MOVING_PHOTO = 'MOVING_PHOTO',
  WAITING = 'WAITING',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  EMPTY = 'EMPTY',
  SHARE = 'SHARE',
  DELETE = 'DELETE',
  STOP = 'STOP',
  RETRY = 'RETRY',
  PAUSE = 'PAUSE',
  PLAY = 'PLAY',
  CHEVRON = 'CHEVRON'
}

export interface VideoInfo {
  codec: string;
  width: number;
  height: number;
  fps: number;
  bitrateKbps: number;
  /** 是否 HDR(由像素格式 / 传输特性推断) */
  hdr: boolean;
  hdrKnown?: boolean;
  rotation: number;
}

export interface AudioInfo {
  codec: string;
  bitrateKbps: number;
  sampleRateHz: number;
  channels: number;
  sampleDepthBits: number;
  channelLayout: string;
}

export enum MediaStreamKind {
  VIDEO = 'VIDEO',
  AUDIO = 'AUDIO',
  SUBTITLE = 'SUBTITLE',
  ATTACHMENT = 'ATTACHMENT',
  UNKNOWN = 'UNKNOWN'
}

export interface MediaStreamInfo {
  index: number;
  kind: MediaStreamKind;
  codec: string;
  language: string;
  name: string;
  bitrateKbps: number;
  rawDetails?: string;
  width?: number;
  height?: number;
  fps?: number;
  sampleRateHz?: number;
  channels?: number;
  sampleDepthBits?: number;
}

export interface AnalyzedMedia {
  uri: string;
  displayName: string;
  mediaType: MediaType;
  /** 容器/封装格式,如 MP4 / MOV / MKV / PNG */
  container: string;
  sizeBytes: number;
  durationMs: number;
  video?: VideoInfo;
  audio?: AudioInfo;
  /** 图片专属:像素尺寸 */
  imageWidth: number;
  imageHeight: number;
  imageBitsPerSample: string;
  imageOrientation: string;
  imageDateTaken: string;
  imageExposure: string;
  imageIso: string;
  imageFNumber: string;
  imageGps: string;
  imageFrameCount: number;
  imageHdr: boolean;
  /** 视频缩略图(PixelMap),由 Analyzer 可选拉取 */
  hasThumbnail: boolean;
  title: string;
  artist: string;
  albumArtist: string;
  album: string;
  author: string;
  composer: string;
  genre: string;
  creationTime: string;
  /** 容器内所有已识别轨道，用于 Stream / Subtitle 工具箱。 */
  streams: MediaStreamInfo[];
  /** PhotoPicker 已确认该资源为动态照片。 */
  isMovingPhoto: boolean;
  mimeType?: string;
  rawMetadata?: string;
  imageDetails?: string;
  analysisNote?: string;
}

export function emptyAnalyzedMedia(uri: string, name: string): AnalyzedMedia {
  return {
    uri: uri,
    displayName: name,
    mediaType: MediaType.UNKNOWN,
    container: '',
    sizeBytes: 0,
    durationMs: 0,
    imageWidth: 0,
    imageHeight: 0,
    imageBitsPerSample: '',
    imageOrientation: '',
    imageDateTaken: '',
    imageExposure: '',
    imageIso: '',
    imageFNumber: '',
    imageGps: '',
    imageFrameCount: 0,
    imageHdr: false,
    hasThumbnail: false,
    title: '',
    artist: '',
    albumArtist: '',
    album: '',
    author: '',
    composer: '',
    genre: '',
    creationTime: '',
    streams: [],
    isMovingPhoto: false
  };
}

/** 一条能力推荐(Workbench 上的卡片)。 */
export interface ToolAction {
  id: string;
  title: string;
  /** 一句话说明,如"无需重新编码" */
  subtitle: string;
  /** 是否无损操作(Remux / Stream Copy 类,P0 原则) */
  lossless: boolean;
  engine: EngineKind;
  /** 引擎就绪后才能真正执行;FFmpeg 接入前 false 的项在 UI 上置灰 */
  available: boolean;
  /** 不可用时展示的短原因；缺省为“引擎待接入”。 */
  statusLabel?: string;
  /** 预计节省比例,0-100;仅压缩类有值 */
  estimatedSavingPct?: number;
  /** 系统 Symbol 的语义名，不保存字符图标。 */
  icon: ToolSymbol;
}

export class Fmt {
  static bytes(b: number): string {
    if (b <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let v = b;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    const digits = v >= 100 || i === 0 ? 0 : 1;
    return `${v.toFixed(digits)} ${units[i]}`;
  }

  static duration(ms: number): string {
    if (ms <= 0) {
      return '--:--';
    }
    const totalSec = Math.round(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const mm = h > 0 ? String(m).padStart(2, '0') : String(m);
    const ss = String(s).padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  static kbps(k: number): string {
    if (k >= 1000) {
      return `${(k / 1000).toFixed(1)} Mbps`;
    }
    return `${Math.round(k)} kbps`;
  }
}
