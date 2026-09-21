const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
function load(file, deps, transform = s => s) {
  const exports = {};
  const source = transform(fs.readFileSync(file, 'utf8'));
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(code, { exports, require: name => deps[name], console, Observed: value => value });
  return exports;
}
const base = 'entry/src/main/ets/';
const model = load(base + 'core/model/MediaTypes.ets', {});
const taskModel = load(base + 'core/task/MediaTask.ets', {});
const panel = load(base + 'ui/components/AdjustmentPanel.ets', {
  '@kit.ImageKit': {}, '@kit.MediaKit': {}, '@kit.CoreFileKit': {},
  '../../core/model/MediaTypes': model, '../../core/task/MediaTask': taskModel,
  '../../core/engine/CapabilityRouter': {}, '../../core/engine/TextOverlay': {}, '../theme/DesignTokens': {}
}, source => (source.slice(0, source.indexOf('  @Builder')) + '\n}').replace(/@(Watch|StorageProp)\('[^']+'\)/g, '').replace(/@(Component|Prop|State)\b/g, '').replace('export struct AdjustmentPanel', 'export class AdjustmentPanel')) ;
const m = model.emptyAnalyzedMedia('input', 'photo.png');
m.mediaType = model.MediaType.IMAGE; m.imageWidth = 800; m.imageHeight = 600;
const p = new panel.AdjustmentPanel(); p.mediaInfo = m; p.action = { id: 'image_crop' };
p.widthText = '300'; p.heightText = '200'; p.xText = '50'; p.yText = '60';
assert.equal(p.params().cropX, 50); assert.equal(p.params().cropHeight, 200);
p.xText = '700'; assert.throws(() => p.params(), /超出/); p.xText = '50';
p.action = { id: 'image_rotate' }; p.degrees = 270; assert.equal(p.params().imageRotateDegrees, 270);
p.action = { id: 'image_text' }; p.textValue = 'hello'; p.fontSizeText = '48'; p.textColor = '#123456';
assert.equal(p.params().textColor, '#123456'); assert.equal(p.params().textFontSize, 48);
p.action = { id: 'video_speed' }; p.scalar = '0.75'; assert.equal(p.params().speed, .75);
p.scalar = '0'; assert.throws(() => p.params(), /倍率/);
p.action = { id: 'video_loop' }; p.scalar = '4'; assert.equal(p.params().loopCount, '3');
p.action = { id: 'subtitle_shift_advance' }; p.scalar = '250'; assert.equal(p.params().subtitleDelaySeconds, -.25);
class Builder {
  constructor() { this.args = []; }
  input(v) { this.args.push(v); return this; } filter(v) { this.args.push(v); return this; }
  hwEncode() { return this; } audioCodec() { return this; } output(v) { this.args.push(v); return this; }
  arg(...values) { this.args.push(...values); return this; }
  audioBitrate(value) { this.args.push(value); return this; }
  duration(value) { this.args.push(value); return this; }
  build() { return this.args; }
}
const { FfmpegEngine } = load(base + 'core/engine/FfmpegEngine.ets', {
  '@kit.AbilityKit': {}, '@kit.CoreFileKit': {}, '../task/MediaTask': taskModel,
  '@prq/ffmpeg-tools': { FFmpegCommandBuilder: Builder, FFmpegManager: { getInstance() {} }, FFMpegUtils: { showLog() {} } }
});
const engine = new FfmpegEngine({});
const command = (id, params) => engine.commandFor({ actionId: id, params }, 'in', 'out', ['in', 'watermark']);
assert(command('video_crop', { cropWidth: 300, cropHeight: 200, cropX: 50, cropY: 60 }).includes('crop=300:200:50:60'));
assert(command('video_speed', { speed: .75, streamKind: 'av' }).some(s => s.includes('atempo=0.75')));
assert(command('video_rotate', { imageRotateDegrees: 270 }).includes('transpose=2'));
assert(command('video_flip', { imageFlipVertical: true }).includes('vflip'));
assert(command('video_watermark', { watermarkWidth: 100, watermarkX: 12, watermarkY: 34 }).some(s => s.includes('scale=100:-1') && s.includes('overlay=12:34')));
assert(command('video_timecode', { timecode: '01:02:03:04' }).includes('01:02:03:04'));
console.log('PASS: crop bounds, rotation, text, speed, loop, subtitle offset, and exact FFmpeg parameter propagation');

assert(command('audio_normalize', { loudnessLufs: -23, truePeakDb: -2, loudnessRange: 7 }).includes('loudnorm=I=-23:TP=-2:LRA=7'));
assert(command('audio_silence_detect', { silenceThresholdDb: -42, silenceDurationSeconds: 1.25 }).some(s => s.includes('noise=-42dB:d=1.25')));
assert(command('audio_fade', { durationSeconds: '100', fadeInSeconds: 3, fadeOutSeconds: 5 }).some(s => s.includes('afade=t=in:st=0:d=3,afade=t=out:st=95:d=5')));
assert(command('extract_audio', { targetContainer: 'flac' }).includes('flac'));
console.log('PASS: configurable loudness, silence threshold, full-duration fades, extraction codec');
