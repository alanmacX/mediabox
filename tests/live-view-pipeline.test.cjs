// Deterministic lifecycle tests for the single-island LiveView pipeline.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function load(file, deps) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(code, {
    exports,
    require: name => deps[name],
    console,
    canIUse: () => true,
    setTimeout: callback => { Promise.resolve().then(callback); return 1; },
    clearTimeout: () => {},
    BusinessError: Error,
    Observed: value => value
  });
  return exports;
}

const missing = () => {
  const error = new Error('liveView does not exist');
  error.code = 1003500009;
  return error;
};
const tick = async () => { for (let i = 0; i < 80; i++) await Promise.resolve(); };

function harness(delayFirstStart = false) {
  const calls = [];
  let active;
  let releaseStart;
  const manager = {
    LayoutType: { LAYOUT_TYPE_PROGRESS: 1 },
    LineType: { LINE_TYPE_THICK_SOLID_LINE: 1 },
    CapsuleType: { CAPSULE_TYPE_TEXT: 1 },
    isLiveViewEnabled: async () => true,
    getActiveLiveView: async id => {
      calls.push(['get', id]);
      if (!active) throw missing();
      return active;
    },
    startLiveView: async view => {
      calls.push(['start', view.id, view.liveViewData.primary.title]);
      if (delayFirstStart) await new Promise(resolve => releaseStart = resolve);
      active = view;
      return { resultCode: 0, message: '' };
    },
    updateLiveView: async view => {
      calls.push(['update', view.id, view.liveViewData.primary.title]);
      active = view;
      return { resultCode: 0, message: '' };
    },
    stopLiveView: async view => {
      calls.push(['stop', view.id]);
      active = undefined;
      return { resultCode: 0, message: '' };
    }
  };
  const model = load('entry/src/main/ets/core/task/MediaTask.ets', {});
  const { LiveViewProgress } = load('entry/src/main/ets/core/task/LiveViewProgress.ets', {
    '@kit.LiveViewKit': { liveViewManager: manager },
    '@kit.AbilityKit': {
      wantAgent: {
        OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
        getWantAgent: async () => ({})
      }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {} } },
    './MediaTask': model
  });
  return { live: new LiveViewProgress(), MediaTask: model.MediaTask, calls,
    active: () => active, releaseStart: () => releaseStart?.() };
}

(async () => {
  const h = harness();
  const tasks = [1, 2, 3].map(i => new h.MediaTask(String(i), `in${i}`, `video${i}.mp4`,
    'compress_video', '批量智能压缩', {}, i));
  h.live.start(tasks[0], { index: 1, total: 3 });
  h.live.update(40, { index: 1, total: 3 });
  h.live.stop('video1.mp4', true, true);
  h.live.start(tasks[1], { index: 2, total: 3 });
  h.live.update(50, { index: 2, total: 3 });
  h.live.stop('video2.mp4', true, true);
  h.live.start(tasks[2], { index: 3, total: 3 });
  h.live.update(60, { index: 3, total: 3 });
  h.live.stop('video3.mp4', true, false);
  await tick();
  assert.equal(h.calls.filter(call => call[0] === 'start').length, 1,
    'one queue session must create exactly one island');
  assert.equal(h.calls.filter(call => call[0] === 'stop').length, 1,
    'only the final task may end the island');
  assert.equal(new Set(h.calls.map(call => call[1]).filter(Number.isFinite)).size, 1,
    'every system call must use the fixed live-view id');
  assert.equal(h.active(), undefined, 'final task must leave no active island');

  const shortRun = harness();
  const short = new shortRun.MediaTask('short', 'in', 'short.mp4', 'compress_video', '压缩', {}, 1);
  shortRun.live.start(short, { index: 1, total: 1 });
  shortRun.live.stop('short.mp4', true, false);
  await tick();
  assert.equal(shortRun.calls.filter(call => call[0] === 'start').length, 0,
    'a standalone task completed inside the grace period must not create an island');
  assert.equal(shortRun.calls.filter(call => call[0] === 'stop').length, 0);

  const race = harness(true);
  const queued = new race.MediaTask('queued', 'in', 'queued.mp4', 'compress_video', '压缩', {}, 1);
  race.live.start(queued, { index: 1, total: 2 });
  race.live.stop('queued.mp4', true, false);
  await tick();
  race.releaseStart();
  await tick();
  assert.equal(race.calls.filter(call => call[0] === 'start').length, 1);
  assert.equal(race.calls.filter(call => call[0] === 'stop').length, 1,
    'completion queued during start must still stop the newly-created island');
  assert.equal(race.active(), undefined, 'short-task race must not leak a live view');
  console.log('PASS: one fixed island across a batch and no short-task lifecycle leak');
})().catch(error => { console.error(error); process.exitCode = 1; });
