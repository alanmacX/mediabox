/** FFmpegCapability：探测缓存、失败降级与按媒体类型联动。 */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function load(file, deps) {
  const exports = {};
  const source = fs.readFileSync(file, 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(code, { exports, require: name => deps[name], console, setTimeout, clearTimeout });
  return exports;
}

let executed = [];
let respond;
const deps = {
  '@prq/ffmpeg-tools': {
    FFmpegManager: {
      getInstance() {
        return {
          execute(command, _prio, callback) {
            executed.push(command);
            setTimeout(() => {
              const encoder = command[command.indexOf('-c:v') + 1] ?? command[command.indexOf('-c:a') + 1];
              respond(encoder, callback);
            }, 0);
            return 'task1';
          },
          cancel() { return true; }
        };
      }
    }
  },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
  '../model/MediaTypes': load('entry/src/main/ets/core/model/MediaTypes.ets', {})
};

const { FFmpegCapability } = load('entry/src/main/ets/core/engine/FFmpegCapability.ets', deps);
const MediaType = deps['../model/MediaTypes'].MediaType;

(async () => {
  // 默认：编码器缺失 → 探测失败 → 功能保持禁用
  respond = (_encoder, callback) => callback.onError(new Error('Encoder not found'));
  assert.equal(await FFmpegCapability.probe('mp3'), false);
  assert.equal(FFmpegCapability.available('mp3'), false);

  // 探测成功 → available 点亮，且结果被缓存（不再重复执行）
  respond = (_encoder, callback) => callback.onSuccess();
  assert.equal(await FFmpegCapability.probe('vp8'), true);
  const before = executed.length;
  assert.equal(await FFmpegCapability.probe('vp8'), true);
  assert.equal(executed.length, before, '缓存命中不应重复探测');

  // 同 key 并发探测复用同一 Promise
  FFmpegCapability.clearCache();
  let settle;
  respond = (_encoder, callback) => { settle = callback; };
  const p1 = FFmpegCapability.probe('webp_anim');
  const p2 = FFmpegCapability.probe('webp_anim');
  for (let i = 0; i < 10 && settle === undefined; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
  assert.ok(settle, '串行探测应最终进入 FFmpegManager');
  settle.onSuccess();
  assert.equal(await p1, true);
  assert.equal(await p2, true);
  assert.equal(executed.length, before + 1, '并发探测只执行一次底层命令');

  // 按媒体类型联动：音频探测 mp3，字幕无需探测
  FFmpegCapability.clearCache();
  respond = (_encoder, callback) => callback.onSuccess();
  assert.equal(await FFmpegCapability.probeForMedia(MediaType.AUDIO), true);
  assert.ok(executed.some(cmd => cmd.join(' ').includes('libmp3lame')));
  assert.equal(await FFmpegCapability.probeForMedia(MediaType.SUBTITLE), false, '字幕无需探测');

  // 探测命令使用 lavfi 微型输入与 null 封装，不落盘
  const probeCmd = executed[executed.length - 1];
  assert.ok(probeCmd.includes('lavfi') && probeCmd.includes('null'));
  console.log('PASS: encoder probe cache, failure fallback, concurrency dedupe, media-type mapping');
})().catch(e => { console.error(e); process.exit(1); });
