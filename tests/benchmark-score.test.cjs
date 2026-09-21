/**
 * Benchmark 指数单测：固定参考值、无上限几何平均、旧任务字段兼容。
 */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function load(file) {
  const exports = {};
  const source = fs.readFileSync(file, 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, { exports, require: () => ({}), console, Observed: value => value });
  return exports;
}

const { BenchScoring, BenchSpecs } = load('entry/src/main/ets/core/bench/BenchScoring.ets');

assert.equal(BenchScoring.median([3, 1, 2]), 2);
assert.ok(Math.abs(BenchScoring.coefficientOfVariation([100, 100, 100])) < 0.001);
assert.ok(BenchScoring.coefficientOfVariation([100, 150, 200]) > 20);
assert.equal(BenchScoring.scoreFromMetric(2, 0), 0);
assert.equal(BenchScoring.scoreFromMetric(0, 2), 0);
assert.equal(BenchScoring.scoreFromMetric(2, 2), 100);
assert.equal(BenchScoring.scoreFromMetric(2, 1), 50);
assert.equal(BenchScoring.scoreFromMetric(2, 4), 200);
assert.equal(BenchScoring.realtimeFactor(8, 2000), 4);
assert.equal(BenchScoring.megapixelsPerSec(2560, 1440, 1000), 2560 * 1440 / 1e6);

const specs = BenchSpecs.items();
assert.equal(specs.length, 8);
assert.equal(BenchScoring.VERSION, 'media-v2');
assert.equal(BenchScoring.BASELINE_SCORE, 500);
const ids = specs.map((s) => s.id);
assert.ok(ids.includes('gif_optimize'));
assert.ok(ids.includes('video_remux'));
assert.equal(ids[ids.length - 1], 'gif_optimize', 'GIF 必须排最后，避免堵 FFmpeg 队列');
assert.ok(ids.indexOf('audio_aac') < ids.indexOf('gif_optimize'));
assert.ok(ids.indexOf('video_native_720p') < ids.indexOf('gif_optimize'));
for (const s of specs) {
  assert.ok(s.referenceMetric > 0, s.id);
}
assert.deepEqual(Array.from(specs, (s) => [s.id, s.referenceMetric]), [
  ['image_resize', 47], ['image_stack', 23.5], ['video_native_720p', 1.8],
  ['audio_aac', 61.5], ['audio_mp3', 41], ['audio_normalize', 12.75],
  ['video_remux', 41], ['gif_optimize', 6.2]
], '参考向量变化时需要同步升级版本与文档');

const item = (metric, ok, referenceMetric = 1, weight = 1) => ({
  id: 'x', title: 'x', ok: ok, metric: metric, metricLabel: '', score: 50,
  referenceMetric, weight, note: '', detail: '', elapsedMs: 1,
  variationPct: 0, samplesMs: [1, 1, 1], iterations: 1
});
// 固定参考吞吐量对应 500；指数严格随原始吞吐比增长，没有满分。
assert.equal(BenchScoring.overallScore([item(1, true), item(1, true), item(0, false)]), 500);
assert.equal(BenchScoring.overallScore([item(0.8, true), item(0.8, true)]), 400);
assert.equal(BenchScoring.overallScore([item(1, true), item(2, true)]), 707);
assert.equal(BenchScoring.overallScore([item(2, true), item(4, true)]), 1414);
assert.equal(BenchScoring.overallScore([item(2, true), item(2, true)]), 1000);
assert.equal(BenchScoring.overallScore([item(4, true), item(4, true)]), 2000);
assert.equal(BenchScoring.overallScore([]), 0);
assert.equal(BenchScoring.buildReport([item(1, true), item(0, false)], '').score, 0);
assert.equal(BenchScoring.buildReport([item(1, true), item(1, true)], '').maxVariationPct, 0);
assert.equal(BenchScoring.buildReport([item(1, true)], '').version, 'media-v2');

// 旧任务 JSON 无 outputName
const taskMod = load('entry/src/main/ets/core/task/MediaTask.ets');
const MediaTask = taskMod.MediaTask;
const legacy = new MediaTask('1', 'file://a', 'a.jpg', 'image_resize', '尺寸调整', {}, 1);
legacy.outputName = undefined;
assert.equal(legacy.safeOutputName(), '');
assert.equal(legacy.primaryTitle(), 'a.jpg');
assert.equal(legacy.subTitle(), 'a.jpg');
legacy.outputName = 'a_1.jpg';
assert.equal(legacy.primaryTitle(), 'a_1.jpg');

// AVTranscoder 目标尺寸：禁止放大
const mb = load('entry/src/main/ets/core/bench/MediaBenchmark.ets');
const safe = mb.MediaBenchmark.safeEncodeSize;
assert.equal(safe(100, 100).ok, false);
assert.equal(safe(640, 360).w, 640);
assert.equal(safe(640, 360).h, 360);
assert.equal(safe(1920, 1080).w, 1280);
assert.equal(safe(1920, 1080).h, 720);
assert.equal(safe(1280, 720).w, 1280);
assert.equal(safe(1280, 720).h, 720);
assert.equal(safe(1920, 480).h, 320);
assert.equal(safe(500, 300).w, 500);
assert.equal(safe(500, 300).h, 300);
assert.equal(mb.MediaBenchmark.batchIterations('image_resize'), 6);
assert.equal(mb.MediaBenchmark.batchIterations('image_stack'), 3);
assert.equal(mb.MediaBenchmark.batchIterations('video_native_720p'), 2);
assert.equal(mb.MediaBenchmark.batchIterations('audio_aac'), 12);
assert.equal(mb.MediaBenchmark.batchIterations('audio_mp3'), 12);
assert.equal(mb.MediaBenchmark.batchIterations('audio_normalize'), 4);
assert.equal(mb.MediaBenchmark.batchIterations('video_remux'), 24);
assert.equal(mb.MediaBenchmark.batchIterations('gif_optimize'), 16);

console.log('PASS: bench throughput scoring + legacy task fields + safe encode size');
