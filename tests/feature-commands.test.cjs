/**
 * 全流程命令审计：每个 CapabilityRouter 动作都应能生成非空 FFmpeg/原生命令，
 * 且探测相关编码器键与命令中的编码器名一致。
 */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function load(file, deps, globals = {}) {
  const exports = {};
  const source = fs.readFileSync(file, 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, {
    exports, require: (n) => deps[n], console, setTimeout, clearTimeout, Observed: value => value, ...globals
  });
  return exports;
}

function emptyMedia(types, uri, name, mediaType) {
  return types.emptyAnalyzedMedia(uri, name);
}

(async () => {
  const mediaTypes = load('entry/src/main/ets/core/model/MediaTypes.ets', {});
  const ds = load('entry/src/main/ets/core/capability/DeviceSupport.ets', {
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg', 'image/png', 'image/webp', 'image/heif'] } },
    '@kit.MediaLibraryKit': {
      photoAccessHelper: {
        PhotoViewMIMETypes: { MOVING_PHOTO_IMAGE_TYPE: 'image/movingPhoto' },
        MediaAssetManager: { requestMovingPhoto() {} },
        PhotoSubtype: { MOVING_PHOTO: 1 },
        MediaAssetChangeRequest: { createAssetRequest() {} }
      }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } }
  }, { canIUse: () => true });
  ds.DeviceSupport.clearCache();

  const router = load('entry/src/main/ets/core/engine/CapabilityRouter.ets', {
    '../model/MediaTypes': mediaTypes,
    '@kit.ImageKit': { image: { getImagePackerSupportedFormats: () => ['image/jpeg', 'image/png', 'image/webp', 'image/heif'] } },
    '../capability/DeviceSupport': ds
  }, { canIUse: () => true });

  // Encoder capability path: webpAnim true
  const gif = emptyMedia(mediaTypes, 'file://g.gif', 'a.gif', mediaTypes.MediaType.GIF);
  gif.mediaType = mediaTypes.MediaType.GIF;
  gif.durationMs = 2000;
  gif.imageFrameCount = 20;
  const caps = { mp3: true, vp8: true, webpAnim: true };
  const gifActions = router.CapabilityRouter.recommend(gif, caps);
  const webp = gifActions.find((a) => a.id === 'gif_to_webp');
  assert.ok(webp, 'gif_to_webp exists when probe ok');
  assert.equal(webp.available, true, 'gif_to_webp available when probe ok');
  assert.equal(webp.statusLabel, undefined);

  const capsOff = { mp3: false, vp8: false, webpAnim: false };
  const gifOff = router.CapabilityRouter.recommend(gif, capsOff).find((a) => a.id === 'gif_to_webp');
  // 不可用编码器对应的推荐项不进入列表（功能验收）
  assert.ok(!gifOff || gifOff.available === false, 'gif_to_webp hidden or unavailable when probe fail');

  // Video / audio / image have at least one available action
  const video = emptyMedia(mediaTypes, 'file://v.mp4', 'v.mp4', mediaTypes.MediaType.VIDEO);
  video.mediaType = mediaTypes.MediaType.VIDEO;
  video.container = 'MOV';
  video.video = { codec: 'H.264', width: 1280, height: 720, fps: 30, bitrateKbps: 2000, hdr: false, rotation: 0 };
  video.durationMs = 3000;
  video.sizeBytes = 1000000;
  const vActions = router.CapabilityRouter.recommend(video, caps);
  assert.ok(vActions.filter((a) => a.available).length > 5, 'video has many available actions');
  assert.ok(vActions.every((a) => a.available === true), 'recommend only returns available actions');

  const audio = emptyMedia(mediaTypes, 'file://a.m4a', 'a.m4a', mediaTypes.MediaType.AUDIO);
  audio.mediaType = mediaTypes.MediaType.AUDIO;
  audio.audio = { codec: 'AAC', bitrateKbps: 128, sampleRateHz: 44100, channels: 2, sampleDepthBits: 16, channelLayout: 'stereo' };
  audio.durationMs = 3000;
  const aActions = router.CapabilityRouter.recommend(audio, caps);
  const mp3 = aActions.find((a) => a.id === 'audio_to_mp3');
  assert.ok(mp3 && mp3.available === true, 'mp3 available when probe ok');

  // CapabilityRouter gif/video/audio ids unique
  const ids = vActions.map((a) => a.id);
  assert.equal(new Set(ids).size, ids.length, 'video action ids unique');

  // FfmpegEngine command generation for key actions
  const executed = [];
  const deps = {
    '@kit.AbilityKit': { common: {} },
    '@kit.CoreFileKit': {
      fileIo: {
        OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
        openSync() { return { fd: 3 }; },
        closeSync() {},
        accessSync(p) { return typeof p === 'string' && !p.includes('ffmpeg_inputs'); },
        mkdirSync() {},
        statSync() { return { size: 100 }; },
        unlinkSync() {},
        copyFileSync() {},
        copyFile() { return Promise.resolve(); }
      }
    },
    '@prq/ffmpeg-tools': {
      FFmpegManager: {
        getInstance() {
          return {
            execute(cmd, _d, cb) {
              executed.push(cmd.slice());
              setTimeout(() => cb.onSuccess(), 0);
              return 't1';
            },
            cancel() { return true; }
          };
        }
      },
      FFMpegUtils: { showLog() {} },
      FFmpegFactory: {
        remux(input, output, fmt) { return ['ffmpeg', '-i', input, '-c', 'copy', '-f', fmt || 'mp4', '-y', output]; },
        videoSnapshot(input, output, time) { return ['ffmpeg', '-ss', time, '-i', input, '-frames:v', '1', '-y', output]; }
      },
      FFmpegCommandBuilder: class {
        constructor() { this.args = ['ffmpeg']; }
        input(p) { this.args.push('-i', p); return this; }
        filter(f) { this.args.push('-vf', f); return this; }
        arg(k, v) { this.args.push(k, v); return this; }
        hwEncode() { this.args.push('-c:v', 'h264_ohosavcodec'); return this; }
        output(p) { this.args.push('-y', p); return this; }
        build() { return this.args.slice(); }
      },
      ContainerFormat: {}
    },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } }
  };
  const engine = load('entry/src/main/ets/core/engine/FfmpegEngine.ets', deps, {
    ArrayBuffer, Uint8Array, TextDecoder: require('util').TextDecoder
  });
  const FfmpegEngine = engine.FfmpegEngine;

  // build commands via public execute path with stubbed context
  const context = {
    filesDir: '/tmp/mb',
    cacheDir: '/tmp/mb_cache'
  };
  // We only need command construction; call private via execute with action ids that hit build
  // Use reflection through a tiny harness: FfmpegEngine.execute
  const MediaTaskCtor = load('entry/src/main/ets/core/task/MediaTask.ets', {}).MediaTask;
  const eng = new FfmpegEngine(context);

  async function runAction(actionId, source, params, name) {
    executed.length = 0;
    const task = new MediaTaskCtor('id1', source, name || 'f', actionId, actionId, params || {}, Date.now());
    await eng.execute(task, () => {});
    assert.ok(executed.length >= 1, `${actionId} produced a command`);
    const flat = executed[0].join(' ');
    assert.ok(flat.includes('-i') || flat.includes('lavfi'), `${actionId} has input`);
    return executed[0];
  }

  const mp3Cmd = await runAction('audio_to_mp3', 'file://in.m4a', { targetAudioKbps: 192, targetSampleRateHz: 44100, targetChannels: 2 });
  assert.ok(mp3Cmd.includes('libmp3lame'), 'audio_to_mp3 uses libmp3lame');
  const cachedCmd = await runAction('audio_to_mp3', '/tmp/mb_cache/bench/input.wav', {});
  assert.ok(cachedCmd.includes('/tmp/mb_cache/bench/input.wav'), 'app-private cache input should bypass staging copy');

  const webpCmd = await runAction('gif_to_webp', 'file://in.gif', { imageQuality: 75 });
  assert.ok(webpCmd.includes('libwebp_anim'), 'gif_to_webp uses libwebp_anim');

  const webm = await runAction('video_to_webm', 'file://in.mp4', { targetVideoKbps: 1000, targetWidth: 1280, targetHeight: 720 });
  assert.ok(webm.join(' ').includes('libvpx') || webm.join(' ').includes('vp8'), 'webm uses libvpx');

  const remux = await runAction('remux_mp4', 'file://in.mov', {});
  assert.ok(remux.includes('-c') || remux.includes('copy') || remux.join(' ').includes('mp4'), 'remux has output');

  console.log('PASS: capability gates + probe-driven availability + key ffmpeg commands');
  console.log('  mp3:', mp3Cmd.join(' '));
  console.log('  webp:', webpCmd.join(' '));
  console.log('  webm:', webm.join(' '));
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
