/**
 * FFmpegCapability — 运行时探测随包 FFmpeg 二进制里的编码器。
 *
 * 修复点：
 * 1. onFailure 必须立刻 resolve(false)，否则只能等 6s 超时。
 * 2. 探测命令更稳：加 -y、限制帧数、用短 lavfi 源。
 * 3. 打开任意工作台时并行探测 mp3 / vp8 / webp_anim，避免只探一种。
 */
import { FFmpegManager, TaskCallback } from '@prq/ffmpeg-tools';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaType } from '../model/MediaTypes';

const TAG = 'FFmpegCapability';
const DOMAIN = 0x4D42;
const PROBE_TIMEOUT_MS = 8000;

const ENCODERS: Map<string, string> = new Map([
  ['h264', 'h264_ohosavcodec'],
  ['mp3', 'libmp3lame'],
  ['vp8', 'libvpx'],
  ['webp_anim', 'libwebp_anim'],
  ['avif', 'libaom-av1']
]);

class ProbeCallback implements TaskCallback {
  private settled = false;
  private resolve: (ok: boolean) => void;

  constructor(resolve: (ok: boolean) => void) {
    this.resolve = resolve;
  }

  onStart(): void {
  }

  onProgress(_progress: number): void {
  }

  onSuccess(): void {
    this.finish(true);
  }

  onFailure(): void {
    this.finish(false);
  }

  onCancelled(): void {
    this.finish(false);
  }

  onTimeout(): void {
    this.finish(false);
  }

  onError(_error: Error): void {
    this.finish(false);
  }

  private finish(ok: boolean): void {
    if (!this.settled) {
      this.settled = true;
      this.resolve(ok);
    }
  }
}

export class FFmpegCapability {
  private static results: Map<string, boolean> = new Map();
  private static pending: Map<string, Promise<boolean>> = new Map();
  private static timedOut: Set<string> = new Set();
  // 上游 FFmpegManager 只有一个执行线程；探测必须串行，避免排队时间被误算为编码器故障。
  private static probeTail: Promise<void> = Promise.resolve();

  static cached(key: string): boolean | undefined {
    return FFmpegCapability.results.get(key);
  }

  static available(key: string): boolean {
    return FFmpegCapability.results.get(key) === true;
  }

  static clearCache(): void {
    FFmpegCapability.results.clear();
    FFmpegCapability.pending.clear();
    FFmpegCapability.timedOut.clear();
  }

  static probe(key: string): Promise<boolean> {
    const pending = FFmpegCapability.pending.get(key);
    if (pending !== undefined) {
      return pending;
    }
    const cached = FFmpegCapability.results.get(key);
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    const encoder = ENCODERS.get(key);
    if (encoder === undefined) {
      return Promise.resolve(false);
    }
    const task = FFmpegCapability.probeTail.then((): Promise<boolean> =>
      FFmpegCapability.runProbe(key, encoder));
    FFmpegCapability.probeTail = task.then((): void => {}, (): void => {});
    FFmpegCapability.pending.set(key, task);
    task.then((ok: boolean) => {
      // 排队/执行超时无法证明编码器不存在；下一次允许重新探测。
      if (!FFmpegCapability.timedOut.has(key)) {
        FFmpegCapability.results.set(key, ok);
      }
      FFmpegCapability.timedOut.delete(key);
      FFmpegCapability.pending.delete(key);
      hilog.info(DOMAIN, TAG, 'probe %{public}s -> %{public}s', encoder, ok ? 'ok' : 'fail');
    }).catch(() => {
      FFmpegCapability.results.set(key, false);
      FFmpegCapability.pending.delete(key);
    });
    return task;
  }

  /** 串行探测全部关键编码器，避免单线程队列中的排队超时。 */
  static async probeAll(): Promise<boolean> {
    const keys: string[] = [];
    for (const key of ENCODERS.keys()) {
      keys.push(key);
    }
    const befores: Array<boolean | undefined> = keys.map((k: string) => FFmpegCapability.results.get(k));
    const afters: boolean[] = [];
    for (const key of keys) {
      afters.push(await FFmpegCapability.probe(key));
    }
    let changed = false;
    for (let i = 0; i < keys.length; i++) {
      if (befores[i] !== afters[i]) {
        changed = true;
      }
    }
    return changed;
  }

  /** 按媒体类型优先探测（仍会保证关键编码器都探过）。 */
  static async probeForMedia(mediaType: MediaType): Promise<boolean> {
    if (mediaType === MediaType.SUBTITLE || mediaType === MediaType.UNKNOWN) {
      return false;
    }
    // 优先探测与当前类型最相关的，但并行把其余也探完，避免其它入口一直灰。
    if (mediaType === MediaType.AUDIO) {
      await FFmpegCapability.probe('mp3');
    } else if (mediaType === MediaType.VIDEO) {
      await FFmpegCapability.probe('vp8');
    } else if (mediaType === MediaType.GIF) {
      await FFmpegCapability.probe('webp_anim');
    } else if (mediaType === MediaType.IMAGE) {
      await FFmpegCapability.probe('avif');
    }
    return FFmpegCapability.probeAll();
  }

  private static runProbe(key: string, encoder: string): Promise<boolean> {
    // 短 lavfi 源 + 限帧 + null 落地，只验证编码器是否真的存在且可初始化。
    let command: string[];
    if (key === 'mp3') {
      command = ['ffmpeg', '-y', '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=mono', '-t', '0.1',
        '-c:a', encoder, '-f', 'null', '-'];
    } else if (key === 'h264') {
      // 系统硬件编码器通常拒绝 64×64，使用 AVTranscoder 同一有效尺寸范围。
      command = ['ffmpeg', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=320x240:r=10',
        '-frames:v', '2', '-pix_fmt', 'yuv420p', '-c:v', encoder, '-f', 'null', '-'];
    } else {
      command = ['ffmpeg', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=10', '-frames:v', '1',
        '-c:v', encoder, '-f', 'null', '-'];
    }
    hilog.info(DOMAIN, TAG, 'probe cmd %{public}s', command.join(' '));
    return new Promise<boolean>((resolve) => {
      let done = false;
      const finish = (ok: boolean): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(ok);
        }
      };
      let nativeTaskId = '';
      const timer = setTimeout((): void => {
        FFmpegCapability.timedOut.add(key);
        if (nativeTaskId.length > 0) {
          try {
            FFmpegManager.getInstance().cancel(nativeTaskId);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'cancel probe %{public}s', encoder);
          }
        }
        finish(false);
      }, PROBE_TIMEOUT_MS);
      const callback = new ProbeCallback(finish);
      try {
        nativeTaskId = FFmpegManager.getInstance().execute(command, 1, callback);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'probe threw %{public}s', (e as Error).message);
        finish(false);
      }
    });
  }
}
