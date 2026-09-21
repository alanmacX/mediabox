/**
 * 调试自测套件：全媒体类型的队列任务冒烟。
 * aa start --ps selftest suite 触发；逐项入队真实 TaskQueue，
 * 通过 QueueListener 打印每个 suite 任务的终态与失败原因。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { TaskQueue, QueueStats } from '../task/TaskQueue';
import { TaskState, TaskParams } from '../task/MediaTask';
import { QueueObserver } from '../../ui/components/QueueObserver';

const DOMAIN = 0x4D42;
const TAG = 'SelfTest';

interface SuiteCase {
  name: string;
  rawNames: string[];
  displayName: string;
  actionId: string;
  actionTitle: string;
  params: TaskParams;
}

export class SelfTest {
  private context: common.UIAbilityContext;
  private queue: TaskQueue;
  private total = 0;
  private settled = 0;
  private fixtureVideoUri = '';
  private phaseBQueued = false;
  private suiteStartedMs = 0;
  private bundledVideoUri = '';
  private videoOnly = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.queue = TaskQueue.getInstance();
  }

  static run(context: common.UIAbilityContext): void {
    new SelfTest(context).start();
  }

  /** 只跑视频类用例（安静模式，便于抓 FFmpeg 错误详情）。 */
  static runVideo(context: common.UIAbilityContext): void {
    const self = new SelfTest(context);
    self.videoOnly = true;
    self.start();
  }

  private log(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  private async copyRaw(rawName: string, destName: string): Promise<string> {
    const data = await this.context.resourceManager.getRawFileContent(rawName);
    const path = `${this.context.filesDir}/suite_${destName}`;
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, data.buffer);
    fileIo.closeSync(file);
    return path;
  }

  start(): void {
    this.suiteStartedMs = Date.now();
    this.log(this.videoOnly ? 'video suite start' : 'suite start');
    if (this.videoOnly) {
      this.tryEnqueuePhaseB();
      return;
    }
    this.queue.subscribe(new QueueObserver((): void => this.onChanged()));
    this.enqueuePhaseA();
  }

  private onChanged(): void {
    const stats: QueueStats = this.queue.stats();
    let lines = `suite settled=${this.settled}/${this.total} running=${stats.running} waiting=${stats.waiting}`;
    for (const t of this.queue.list()) {
      lines += ` | ${t.actionId}=${t.state}:${Math.floor(t.progress)}%:${t.message}`;
      if (t.actionId === 'images_to_video' && t.state === TaskState.COMPLETED && t.outputUri.length > 0) {
        this.fixtureVideoUri = t.outputUri;
      }
    }
    this.log(lines);
    if (this.fixtureVideoUri.length > 0) {
      this.tryEnqueuePhaseB();
    }
    const done = stats.running === 0 && stats.waiting === 0;
    if (done && this.phaseBQueued && this.settled < this.total) {
      this.log('suite all settled');
    }
  }

  private enqueuePhaseA(): void {
    const q = this.queue;
    const cases: SuiteCase[] = [
      { name: 'audio_mp3', rawNames: ['selftest_audio.wav'], displayName: 'tone.mp3', actionId: 'audio_to_mp3',
        actionTitle: '转 MP3', params: { targetAudioKbps: 192 } },
      { name: 'audio_trim', rawNames: ['selftest_audio.wav'], displayName: 'trim.wav', actionId: 'audio_trim',
        actionTitle: '裁剪音频', params: { startTime: '00:00:00', durationSeconds: '1' } },
      { name: 'audio_fade', rawNames: ['selftest_audio.wav'], displayName: 'fade.wav', actionId: 'audio_fade',
        actionTitle: '淡入淡出', params: { fadeInSeconds: 0.5, totalDurationSeconds: 3 } },
      { name: 'audio_volume', rawNames: ['selftest_audio.wav'], displayName: 'vol.wav', actionId: 'audio_volume',
        actionTitle: '调音量', params: { volumeMultiplier: 1.5 } },
      { name: 'audio_resample', rawNames: ['selftest_audio.wav'], displayName: '22k.wav', actionId: 'audio_resample',
        actionTitle: '重采样', params: { targetSampleRateHz: 22050 } },
      { name: 'audio_silence', rawNames: ['selftest_audio.wav'], displayName: 'silence.txt',
        actionId: 'audio_silence_detect', actionTitle: '静音检测', params: { silenceThresholdDb: -35 } },
      { name: 'subtitle_srt', rawNames: ['selftest_sub.vtt'], displayName: 'out.srt', actionId: 'subtitle_to_srt',
        actionTitle: '字幕转 SRT', params: {} },
      { name: 'gif_optimize', rawNames: ['selftest_anim.gif'], displayName: 'opt.gif', actionId: 'gif_optimize',
        actionTitle: '优化 GIF', params: { paletteColors: 64 } },
      { name: 'gif_target', rawNames: ['selftest_anim.gif'], displayName: 'small.gif', actionId: 'gif_target_size',
        actionTitle: 'GIF 体积', params: { targetBytes: 200000, targetWidth: 480, targetFps: 10 } },
      { name: 'gif_speed', rawNames: ['selftest_anim.gif'], displayName: 'fast.gif', actionId: 'gif_speed',
        actionTitle: 'GIF 变速', params: { speed: 2 } },
      { name: 'image_stack', rawNames: ['selftest_small.jpg', 'selftest_small.jpg', 'selftest_small.jpg'],
        displayName: 'stack.png', actionId: 'image_stack_vertical', actionTitle: '纵向拼接', params: {} },
      { name: 'image_watermark', rawNames: ['selftest_small.jpg', 'selftest_mark.png'],
        displayName: 'marked.png', actionId: 'ff_image_watermark', actionTitle: '图片水印',
        params: { imageFormat: 'image/png', watermarkPosition: 'center' } }
    ];
    for (const c of cases) {
      this.enqueueCase(c);
    }
    // 阶段 B 的源头：先产出 fixture 视频
    this.enqueueCase({
      name: 'fixture_video', rawNames: ['selftest_small.jpg', 'selftest_small.jpg', 'selftest_small.jpg'],
      displayName: 'fixture.mp4', actionId: 'images_to_video', actionTitle: '图片转视频',
      params: { targetFps: 24, durationSeconds: '1' }
    });
    this.log(`suite phase A enqueued (${this.total} tasks)`);
  }

  private tryEnqueuePhaseB(): void {
    if (this.phaseBQueued) {
      return;
    }
    this.phaseBQueued = true;
    if (this.fixtureVideoUri.length > 0) {
      this.log(`fixture video ready: ${this.fixtureVideoUri}`);
    } else {
      this.log('images_to_video unavailable (emulator hw codec); using bundled mp4 fixture');
    }
    this.enqueuePhaseB();
  }

  private enqueuePhaseB(): void {
    this.context.resourceManager.getRawFileContent('selftest_video.mp4').then((data: Uint8Array) => {
      const path = `${this.context.filesDir}/suite_bundled_video.mp4`;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, data.buffer);
      fileIo.closeSync(file);
      const video = this.fixtureVideoUri.length > 0 ? this.fixtureVideoUri : path;
      this.bundledVideoUri = path;
      this.log(`phase B input: ${video}`);
      this.enqueuePhaseBCases(video);
    }).catch((e: Error) => {
      this.log(`phase B fixture copy failed ${e.message}`);
    });
  }

  private enqueuePhaseBCases(video: string): void {
    const cases: SuiteCase[] = [
      { name: 'video_trim', rawNames: [video], displayName: 'trim.mp4', actionId: 'video_trim',
        actionTitle: '裁剪视频', params: { startTime: '00:00:00', durationSeconds: '1' } },
      { name: 'video_remux', rawNames: [video], displayName: 'remux.mp4', actionId: 'remux_mp4',
        actionTitle: '转封装', params: {} },
      { name: 'video_webm', rawNames: [video], displayName: 'clip.webm', actionId: 'video_to_webm',
        actionTitle: '转 WebM', params: {} },
      { name: 'video_mkv', rawNames: [video], displayName: 'clip.mkv', actionId: 'video_to_mkv',
        actionTitle: '转 MKV', params: {} },
      { name: 'video_mov', rawNames: [video], displayName: 'clip.mov', actionId: 'video_to_mov',
        actionTitle: '转 MOV', params: {} },
      { name: 'video_mute', rawNames: [video], displayName: 'muted.mp4', actionId: 'video_mute',
        actionTitle: '去除音频', params: {} },
      { name: 'video_speed', rawNames: [video], displayName: 'fast.mp4', actionId: 'video_speed',
        actionTitle: '变速', params: { speed: 2 } },
      { name: 'video_loop', rawNames: [video], displayName: 'loop.mp4', actionId: 'video_loop',
        actionTitle: '循环', params: { loopCount: '2' } },
      { name: 'video_snapshot', rawNames: [video], displayName: 'frame.jpg', actionId: 'video_snapshot',
        actionTitle: '截取帧', params: {} },
      { name: 'extract_audio', rawNames: [video], displayName: 'audio.m4a', actionId: 'extract_audio',
        actionTitle: '提取音频', params: {} },
      { name: 'to_gif', rawNames: [video], displayName: 'anim.gif', actionId: 'to_gif',
        actionTitle: '转 GIF', params: { targetFps: 10, durationSeconds: '2', targetWidth: 480 } },
      { name: 'video_meta_rm', rawNames: [video], displayName: 'nometa.mp4', actionId: 'video_metadata_remove',
        actionTitle: '清除元数据', params: {} }
    ];
    for (const c of cases) {
      this.enqueueCase(c);
    }
    this.log(`suite phase B enqueued (${this.total} tasks total)`);
  }

  private enqueueCase(c: SuiteCase): void {
    const name = c.name;
    const paths: Promise<string>[] = [];
    for (let i = 0; i < c.rawNames.length; i++) {
      if (c.rawNames[i].startsWith('/')) {
        // 已是沙箱绝对路径（如阶段 A 产出的视频），直接使用
        paths.push(Promise.resolve(c.rawNames[i]));
      } else {
        paths.push(this.copyRaw(c.rawNames[i], `${name}_${i}.${c.rawNames[i].split('.').pop()}`));
      }
    }
    Promise.all(paths).then((uris: string[]) => {
      const displayNames = uris.map((_u: string, i: number) => i === 0 ? c.displayName : `in${i}.bin`);
      const id = this.queue.enqueueTaskGroup(uris, displayNames, c.actionId, c.actionTitle, c.params);
      if (id.length === 0) {
        this.log(`suite case ${name} enqueue failed`);
        return;
      }
      this.total++;
      const list = this.queue.list();
      for (const t of list) {
        if (t.id === id) {
          const raw = t;
          const watch = (): void => {
            if (t.state !== TaskState.WAITING && t.state !== TaskState.RUNNING &&
              t.state !== TaskState.CANCELING) {
              this.settled++;
              this.log(`case ${name} [${c.actionId}] -> ${t.state} ${Math.floor(t.progress)}% ${t.message}`);
              if (c.actionId === 'images_to_video') {
                // 无论成败，视频类阶段 B 都继续（模拟器无硬件编码器时用捆绑 mp4）
                setTimeout((): void => this.tryEnqueuePhaseB(), 200);
              }
            } else {
              setTimeout(() => watch(), 300);
            }
          };
          setTimeout(() => watch(), 300);
          hilog.info(DOMAIN, TAG, 'case %s enqueued id=%s', name, id);
        }
      }
    }).catch((e: Error) => {
      this.log(`suite case ${name} copy failed ${e.message}`);
    });
  }
}
