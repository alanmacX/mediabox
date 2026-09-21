/** 固定素材、逐项验证输出的媒体处理性能测试。 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemDateTime, thermal } from '@kit.BasicServicesKit';
import { NativeEngineExecutor } from '../engine/NativeEngine';
import { FfmpegEngine } from '../engine/FfmpegEngine';
import { FFmpegCapability } from '../engine/FFmpegCapability';
import { DeviceSupport } from '../capability/DeviceSupport';
import { MediaTask, TaskParams } from '../task/MediaTask';
import { MediaAnalyzer, PickedFile } from '../analyze/MediaAnalyzer';
import { BenchItemResult, BenchItemSpec, BenchReport, BenchScoring, BenchSpecs } from './BenchScoring';
import { emptyAnalyzedMedia, MediaType } from '../model/MediaTypes';

const TAG = 'MediaBenchmark';
const DOMAIN = 0x4D42;

interface VideoMeasure {
  w: number;
  h: number;
  sec: number;
}

interface SafeEncodeSize {
  w: number;
  h: number;
  ok: boolean;
}

interface BenchTiming {
  medianMs: number;
  variationPct: number;
  samplesMs: number[];
  iterations: number;
}

interface BenchEnv {
  hasJpeg: boolean;
  hasWav: boolean;
  hasVideo: boolean;
  hasGif: boolean;
  jpegPath: string;
  wavPath: string;
  videoPath: string;
  remuxPath: string;
  gifPath: string;
  jpegW: number;
  jpegH: number;
  videoW: number;
  videoH: number;
  videoSec: number;
  wavSec: number;
  gifSec: number;
  nativeImg: boolean;
}

export class MediaBenchmark {
  private context: common.UIAbilityContext;
  private nativeExec: NativeEngineExecutor;
  private ffmpeg: FfmpegEngine;
  private cacheDir: string;
  /** FFmpeg 单项超时后置位：后续 FFmpeg 子项直接跳过，避免队列阻塞连环超时。 */
  private ffmpegBlocked: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.nativeExec = new NativeEngineExecutor(context);
    this.ffmpeg = new FfmpegEngine(context);
    this.cacheDir = `${context.cacheDir}/mb_bench`;
  }

  private ensureDir(path: string): void {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path);
    }
  }

  private async writeBytes(path: string, buf: ArrayBuffer): Promise<void> {
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
      fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(f.fd, buf);
    } finally {
      fileIo.closeSync(f);
    }
  }

  /** 5 秒 440Hz 正弦，16-bit mono 48kHz（够 loudnorm，又不至于太慢）。 */
  private async makeSineWav(path: string): Promise<number> {
    const sampleRate = 48000;
    const seconds = 5;
    const samples = sampleRate * seconds;
    const pcmBytes = samples * 2;
    const buf = new ArrayBuffer(44 + pcmBytes);
    const dv = new DataView(buf);
    const writeStr = (off: number, s: string): void => {
      for (let i = 0; i < s.length; i++) {
        dv.setUint8(off + i, s.charCodeAt(i));
      }
    };
    writeStr(0, 'RIFF');
    dv.setUint32(4, 36 + pcmBytes, true);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    dv.setUint32(16, 16, true);
    dv.setUint16(20, 1, true);
    dv.setUint16(22, 1, true);
    dv.setUint32(24, sampleRate, true);
    dv.setUint32(28, sampleRate * 2, true);
    dv.setUint16(32, 2, true);
    dv.setUint16(34, 16, true);
    writeStr(36, 'data');
    dv.setUint32(40, pcmBytes, true);
    // 一个正弦周期循环写入，避免 samples 次 sin
    const period = Math.max(8, Math.floor(sampleRate / 440));
    const cycle = new Int16Array(period);
    for (let i = 0; i < period; i++) {
      cycle[i] = Math.round(Math.sin(2 * Math.PI * i / period) * 12000);
    }
    for (let i = 0; i < samples; i++) {
      dv.setInt16(44 + i * 2, cycle[i % period], true);
    }
    await this.writeBytes(path, buf);
    return seconds;
  }

  private async copyRawFixture(rawName: string, destPath: string): Promise<boolean> {
    try {
      const bytes = await this.context.resourceManager.getRawFileContent(`fixtures/${rawName}`);
      await this.writeBytes(destPath, bytes.slice().buffer as ArrayBuffer);
      return fileIo.accessSync(destPath) && fileIo.statSync(destPath).size > 64;
    } catch (e) {
      return false;
    }
  }

  private async prepareVideoFixture(mp4Path: string): Promise<boolean> {
    this.ensureDir(this.cacheDir);
    const sizeOf = (path: string): number =>
      fileIo.accessSync(path) ? fileIo.statSync(path).size : 0;
    // 固定 H.264/AAC 720p 样例由构建时生成，准备阶段不占 FFmpeg 单线程队列。
    const ok = await this.copyRawFixture('benchmark_h264_aac_720p.mp4', mp4Path);
    if (!ok || sizeOf(mp4Path) < 100000) {
      hilog.error(DOMAIN, TAG, 'bundled video fixture unavailable');
      return false;
    }
    return true;
  }

  private async measureVideo(path: string): Promise<VideoMeasure> {
    try {
      const name = path.substring(path.lastIndexOf('/') + 1);
      const picked: PickedFile = {
        uri: path,
        displayName: name,
        mediaTypeHint: undefined,
        isMovingPhoto: false
      };
      const r = await MediaAnalyzer.analyze(picked, false);
      const w = r.media.video !== undefined ? r.media.video.width : (r.media.imageWidth || 0);
      const h = r.media.video !== undefined ? r.media.video.height : (r.media.imageHeight || 0);
      return { w: w, h: h, sec: Math.max(0, r.media.durationMs / 1000) };
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'measure video %{public}s', (e as Error).message);
      return { w: 0, h: 0, sec: 0 };
    }
  }

  /** AVTranscoder 禁止放大，保持长宽比并限制在 720p。 */
  static safeEncodeSize(srcW: number, srcH: number): SafeEncodeSize {
    if (!(srcW >= 240) || !(srcH >= 240)) {
      return { w: 0, h: 0, ok: false };
    }
    const even = (v: number): number => Math.floor(v / 2) * 2;
    const scale = Math.min(1, 1280 / srcW, 720 / srcH);
    const capW = even(srcW * scale);
    const capH = even(srcH * scale);
    return {
      w: capW,
      h: capH,
      ok: capW >= 240 && capH >= 240
    };
  }


  private async prepareEnv(onPhase?: (label: string, ratio: number) => void): Promise<BenchEnv> {
    this.ensureDir(this.cacheDir);
    const phase = (label: string, ratio: number): void => {
      if (onPhase !== undefined) {
        onPhase(label, ratio);
      }
    };
    // 准备阶段进度必须停在子项起点（0.12）之前，避免 UI 进度回落
    phase('检查固定样例…', 0.02);
    phase('检查样例缓存…', 0.05);
    const jpegPath = `${this.cacheDir}/src_benchmark_2048.jpg`;
    const wavPath = `${this.cacheDir}/src_sine5.wav`;
    const videoPath = `${this.cacheDir}/src_benchmark_h264_aac_720p.mp4`;
    const remuxPath = videoPath;
    const gifPath = `${this.cacheDir}/src_anim.gif`;
    const jpegW = 2048;
    const jpegH = 1152;
    phase('复制图片样例…', 0.06);
    const hasJpeg = await this.copyRawFixture('benchmark_image_2048.jpg', jpegPath) &&
      fileIo.statSync(jpegPath).size > 100000;
    let wavSec = 0;
    let hasWav = false;
    if (fileIo.accessSync(wavPath) && fileIo.statSync(wavPath).size > 64) {
      hasWav = true;
      wavSec = 5;
    } else {
      phase('生成音频样例…', 0.07);
      try {
        wavSec = await this.makeSineWav(wavPath);
        hasWav = fileIo.accessSync(wavPath);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'wav fixture %{public}s', (e as Error).message);
      }
    }
    phase('准备视频基准…', 0.08);
    const videoReady = await this.prepareVideoFixture(videoPath);
    phase('测量样例…', 0.09);
    let video: VideoMeasure = { w: 0, h: 0, sec: 0 };
    if (videoReady) {
      video = await this.measureVideo(videoPath);
    }
    if (!fileIo.accessSync(gifPath) || fileIo.statSync(gifPath).size < 64) {
      await this.copyRawFixture('sample.gif', gifPath);
    }
    const hasGif = fileIo.accessSync(gifPath);
    // sample.gif：320x180 / 16 帧，按 10fps 估 1.6s
    const gifSec = 1.6;
    phase('开始测试…', 0.11);
    return {
      hasJpeg: hasJpeg,
      hasWav: hasWav,
      hasVideo: videoReady && video.w === 1280 && video.h === 720 && video.sec >= 3.9,
      hasGif: hasGif,
      jpegPath: jpegPath,
      wavPath: wavPath,
      videoPath: videoPath,
      remuxPath: remuxPath,
      gifPath: gifPath,
      jpegW: jpegW,
      jpegH: jpegH,
      videoW: video.w,
      videoH: video.h,
      videoSec: video.sec,
      wavSec: wavSec,
      gifSec: gifSec,
      nativeImg: DeviceSupport.imageCodecAvailable()
    };
  }

  private task(id: string, source: string, name: string, actionId: string, params: TaskParams): MediaTask {
    return new MediaTask(id, source, name, actionId, actionId, params, Date.now());
  }

  /**
   * 带超时的单次执行：超时后 cancel，bench 继续下一项，绝不整页卡死。
   * 引擎 native 挂死时 cancel 可能无效，但至少 Promise 会返回，后续 FFmpeg 项若仍阻塞会再次超时跳过。
   */
  private async runOnce(kind: 'native' | 'ffmpeg', task: MediaTask, timeoutMs: number): Promise<void> {
    const engine = kind === 'native' ? this.nativeExec : this.ffmpeg;
    let timerId = -1;
    try {
      await new Promise<void>((resolve, reject) => {
        let settled = false;
        timerId = setTimeout((): void => {
          if (settled) {
            return;
          }
          settled = true;
          if (kind === 'ffmpeg') {
            this.ffmpegBlocked = true;
          }
          try {
            engine.cancel(task.id);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'cancel %{public}s', (e as Error).message);
          }
          reject(new Error(`单项超时 ${Math.round(timeoutMs / 1000)}s，已跳过`));
        }, timeoutMs);
        engine.execute(task, (): void => {}).then((output: string): void => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timerId);
          try {
            if (!fileIo.accessSync(output) || fileIo.statSync(output).size < 1024) {
              reject(new Error('引擎返回成功，但输出文件缺失或过小'));
              return;
            }
            resolve();
          } catch (e) {
            reject(e as Error);
          }
        }).catch((e: Error): void => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timerId);
          reject(e);
        });
      });
    } finally {
      if (timerId >= 0) {
        clearTimeout(timerId);
      }
    }
  }

  private monotonicMs(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
  }

  /** 同一个产品 pipeline 预热一次，再以固定批量摊薄短任务的启动开销。 */
  private async measureBatches(times: number, iterations: number, run: () => Promise<void>,
    onAttempt?: (done: number, total: number, lastMs: number) => void): Promise<BenchTiming> {
    const samples: number[] = [];
    await run();
    for (let i = 0; i < times; i++) {
      const start = this.monotonicMs();
      for (let j = 0; j < iterations; j++) {
        await run();
      }
      const perOperationMs = (this.monotonicMs() - start) / iterations;
      samples.push(perOperationMs);
      if (onAttempt !== undefined) {
        onAttempt(i + 1, times, perOperationMs);
      }
    }
    return {
      medianMs: BenchScoring.median(samples),
      variationPct: BenchScoring.coefficientOfVariation(samples),
      samplesMs: samples,
      iterations: iterations
    };
  }

  /** 固定次数保证每次跑分工作量一致；大多数批次累计约 1 秒，摊薄短任务抖动。 */
  static batchIterations(id: string): number {
    switch (id) {
      case 'image_resize': return 6;
      case 'image_stack': return 3;
      case 'video_native_720p': return 2;
      case 'audio_aac':
      case 'audio_mp3': return 12;
      case 'audio_normalize': return 4;
      case 'video_remux': return 24;
      case 'gif_optimize': return 16;
      default: return 1;
    }
  }

  private thermalLevel(): number {
    try {
      return canIUse('SystemCapability.PowerManager.ThermalManager') ? thermal.getLevel() : -1;
    } catch (e) {
      return -1;
    }
  }

  private result(spec: BenchItemSpec, ok: boolean, metric: number, elapsedMs: number,
    detail: string, timing?: BenchTiming): BenchItemResult {
    return {
      id: spec.id,
      title: spec.title,
      ok: ok,
      metric: metric,
      metricLabel: spec.metricLabel,
      score: ok ? BenchScoring.scoreFromMetric(spec.referenceMetric, metric) : 0,
      weight: spec.weight,
      note: spec.note,
      detail: detail,
      elapsedMs: elapsedMs,
      variationPct: timing === undefined ? 0 : timing.variationPct,
      samplesMs: timing === undefined ? [] : timing.samplesMs,
      iterations: timing === undefined ? 0 : timing.iterations,
      referenceMetric: spec.referenceMetric
    };
  }

  async run(times: number = 3,
    onItem?: (result: BenchItemResult, index: number, total: number) => void,
    onPhase?: (label: string, ratio: number) => void): Promise<BenchReport> {
    this.ffmpegBlocked = false;
    const thermalStart = this.thermalLevel();
    const env = await this.prepareEnv(onPhase);
    const specs = BenchSpecs.items();
    const results: BenchItemResult[] = [];
    const total = specs.length;
    // 子项进度槽：0.12–0.98
    const slotStart = 0.12;
    const slotSpan = 0.86;
    for (let i = 0; i < total; i++) {
      const spec = specs[i];
      const base = slotStart + (i / total) * slotSpan;
      const width = slotSpan / total;
      const report = (label: string, sub: number): void => {
        if (onPhase === undefined) {
          return;
        }
        const r = base + Math.max(0, Math.min(1, sub)) * width;
        onPhase(label, r);
      };
      report(`${i + 1}/${total} ${spec.title}…`, 0.05);
      const item = await this.runOne(spec, times, env, report);
      results.push(item);
      report(`${i + 1}/${total} ${item.title} ${item.ok ? '完成' : '跳过'}`, 0.95);
      hilog.error(DOMAIN, TAG, 'BENCH %{public}s ok=%{public}s index=%{public}d detail=%{public}s',
        item.id, item.ok ? '1' : '0', item.score, item.detail);
      if (onItem !== undefined) {
        onItem(item, i + 1, total);
      }
    }
    // 诊断自定义 FFmpeg H.264 硬件编码器，置于计分任务之后，不干扰其计时。
    await FFmpegCapability.probe('h264');
    const h264 = FFmpegCapability.cached('h264');
    const h264Text = h264 === undefined ? 'unknown' : `${h264}`;
    const thermalEnd = this.thermalLevel();
    const deviceNote = `api24 · native=${DeviceSupport.avTranscoderAvailable()} · ffh264=${h264Text} · img=${env.nativeImg} · src=${env.videoW}x${env.videoH} · thermal=${thermalStart}→${thermalEnd}`;
    return BenchScoring.buildReport(results, deviceNote);
  }

  private pickBenchMedia(paths: string[], minBytes: number): string {
    let best = '';
    let bestSize = 0;
    for (const path of paths) {
      if (!fileIo.accessSync(path)) {
        continue;
      }
      const size = fileIo.statSync(path).size;
      if (size > bestSize) {
        bestSize = size;
        best = path;
      }
    }
    return bestSize >= minBytes ? best : '';
  }

  private async runOne(spec: BenchItemSpec, times: number, env: BenchEnv,
    report?: (label: string, ratio: number) => void): Promise<BenchItemResult> {
    const skip = (detail: string): BenchItemResult => this.result(spec, false, 0, 0, detail);
    const note = (label: string, sub: number): void => {
      if (report !== undefined) {
        report(label, sub);
      }
    };
    const needsFfmpeg = spec.id === 'audio_aac' || spec.id === 'audio_mp3' ||
      spec.id === 'audio_normalize' || spec.id === 'video_remux' || spec.id === 'gif_optimize';
    if (needsFfmpeg && this.ffmpegBlocked) {
      return skip('前序 FFmpeg 单项超时，队列可能阻塞，本项跳过');
    }
    try {
      switch (spec.id) {
        case 'image_resize': {
          if (!env.hasJpeg || !env.nativeImg) {
            return skip('缺少图片样例或 Image Kit');
          }
          const t = this.task('bench_img_resize', env.jpegPath, 'bench.jpg', 'image_resize',
            { targetWidth: 1280, targetHeight: 720, imageFormat: 'image/jpeg', imageQuality: 85 });
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('native', t, 20000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`${spec.title} ${done}/${n} · ${Math.round(lastMs)}ms`, done / n * 0.8);
          });
          const ms = timing.medianMs;
          const mp = BenchScoring.megapixelsPerSec(env.jpegW, env.jpegH, ms);
          return this.result(spec, ms > 0 && mp > 0, mp, ms,
            `${env.jpegW}x${env.jpegH} → 1280x720 · ${Math.round(mp)} MP/s`, timing);
        }
        case 'image_stack': {
          if (!env.hasJpeg || !env.nativeImg) {
            return skip('缺少图片样例');
          }
          const t = this.task('bench_stack', env.jpegPath, 'bench.jpg', 'image_stack_horizontal',
            { additionalSourceUris: [env.jpegPath], targetWidth: 2560 });
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('native', t, 25000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`${spec.title} ${done}/${n} · ${Math.round(lastMs)}ms`, done / n * 0.8);
          });
          const ms = timing.medianMs;
          // ImageComposition 的横拼接以原图高度为 cross：2 × 2048 × 1152。
          const mp = BenchScoring.megapixelsPerSec(env.jpegW * 2, env.jpegH, ms);
          return this.result(spec, ms > 0 && mp > 0, mp, ms, `拼接输出吞吐 ${Math.round(mp)} MP/s`, timing);
        }
        case 'audio_aac':
        case 'audio_mp3':
        case 'audio_normalize': {
          if (!env.hasWav) {
            return skip('缺少音频样例');
          }
          const actionId = spec.id === 'audio_aac' ? 'audio_convert' :
            (spec.id === 'audio_mp3' ? 'audio_to_mp3' : 'audio_normalize');
          const params: TaskParams = spec.id === 'audio_normalize' ?
            { loudnessLufs: -16, truePeakDb: -1, loudnessRange: 7 } :
            {
              targetAudioKbps: 128,
              targetSampleRateHz: 44100,
              targetChannels: 1,
              targetContainer: spec.id === 'audio_mp3' ? 'mp3' : 'm4a'
            };
          const t = this.task(`bench_${spec.id}`, env.wavPath, 'bench.wav', actionId, params);
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('ffmpeg', t, 20000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`${spec.title} ${done}/${n} · ${Math.round(lastMs)}ms`, done / n * 0.8);
          });
          const ms = timing.medianMs;
          const rt = BenchScoring.realtimeFactor(env.wavSec, ms);
          return this.result(spec, ms > 0 && rt > 0, rt, ms,
            `${env.wavSec}s 音频 · ${rt.toFixed(1)}x 实时`, timing);
        }
        case 'video_native_720p': {
          if (!env.hasVideo) {
            return skip('固定 H.264/AAC 视频样例不可用或媒体信息读取失败');
          }
          if (!DeviceSupport.avTranscoderAvailable()) {
            return skip('设备不支持 AVTranscoder');
          }
          const size = MediaBenchmark.safeEncodeSize(env.videoW, env.videoH);
          if (!size.ok) {
            return skip(`源 ${env.videoW}x${env.videoH} 低于 AVTranscoder 最小分辨率 240，无法硬件转码`);
          }
          const media = emptyAnalyzedMedia(env.videoPath, 'bench.mp4');
          media.mediaType = MediaType.VIDEO;
          media.container = 'MP4';
          media.durationMs = Math.max(500, env.videoSec * 1000);
          media.video = {
            codec: 'H.264',
            width: env.videoW,
            height: env.videoH,
            fps: 30,
            bitrateKbps: 1500,
            hdr: false,
            rotation: 0
          };
          const t = this.task('bench_video_native', env.videoPath, 'bench.mp4', 'compress_smart',
            { targetWidth: size.w, targetHeight: size.h, targetVideoKbps: 1200, targetAudioKbps: 96 });
          note(`硬件转码 ${env.videoW}x${env.videoH} → ${size.w}x${size.h}…`, 0.15);
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('native', t, 45000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`硬件转码 ${done}/${n} · ${Math.round(lastMs)}ms`, 0.2 + done / n * 0.7);
          });
          const ms = timing.medianMs;
          const rt = BenchScoring.realtimeFactor(env.videoSec, ms);
          return this.result(spec, ms > 0 && rt > 0, rt, ms,
            `源 ${env.videoW}x${env.videoH} → ${size.w}x${size.h} · ${rt.toFixed(2)}x 实时`, timing);
        }
        case 'video_remux': {
          if (!env.hasVideo) {
            return skip('固定 H.264/AAC 视频样例不可用');
          }
          const path = this.pickBenchMedia([env.remuxPath, env.videoPath], 20000);
          if (path.length === 0) {
            return skip('无足够大的封装基准文件（视频样例生成失败）');
          }
          const size = fileIo.statSync(path).size;
          const t = this.task('bench_remux', path, 'bench_remux_out.mp4', 'remux_mp4', {});
          note(`Remux ${(size / 1024 / 1024).toFixed(2)} MB…`, 0.15);
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('ffmpeg', t, 15000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`Remux ${done}/${n} · ${Math.round(lastMs)}ms`, 0.2 + done / n * 0.7);
          });
          const ms = timing.medianMs;
          const mbs = BenchScoring.megabytesPerSec(size, ms);
          return this.result(spec, ms > 0 && mbs > 0, mbs, ms,
            `${(size / 1024 / 1024).toFixed(2)} MB · ${mbs.toFixed(1)} MB/s`, timing);
        }
        case 'gif_optimize': {
          const gifPath = this.pickBenchMedia([env.gifPath], 64);
          if (gifPath.length === 0) {
            return skip('包内缺少 GIF 样例');
          }
          const t = this.task('bench_gif', gifPath, 'bench.gif', 'gif_optimize',
            { targetWidth: 320, targetFps: 8, paletteColors: 64, loopCount: '0' });
          note('GIF 重编码…', 0.1);
          const timing = await this.measureBatches(times, MediaBenchmark.batchIterations(spec.id), async (): Promise<void> => {
            await this.runOnce('ffmpeg', t, 15000);
          }, (done: number, n: number, lastMs: number): void => {
            note(`GIF 优化 ${done}/${n} · ${Math.round(lastMs)}ms`, 0.2 + done / n * 0.7);
          });
          const ms = timing.medianMs;
          const rt = BenchScoring.realtimeFactor(Math.max(env.gifSec, 0.5), ms);
          return this.result(spec, ms > 0 && rt > 0, rt, ms,
            `GIF 重编码 · ${rt.toFixed(2)}x 实时 · ${Math.round(ms)}ms`, timing);
        }
        default:
          return skip('未实现的子项');
      }
    } catch (e) {
      return skip((e as Error).message);
    }
  }
}
