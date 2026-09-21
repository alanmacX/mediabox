// Executes production queue logic with SDK boundaries replaced by deterministic fakes.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
function load(file, deps) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(code, { exports, require: name => deps[name], console, Observed: value => value });
  return exports;
}
const base = 'entry/src/main/ets/core/task/';
const model = load(base + 'MediaTask.ets', {});
const tick = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
function harness(history = [], delayed = false) {
  let raw = JSON.stringify(history), releasePrefs;
  const liveEvents = [];
  const store = { getSync: () => raw, putSync: (_, value) => raw = value, flush: async () => {} };
  const prefs = delayed ? new Promise(resolve => releasePrefs = () => resolve(store)) : Promise.resolve(store);
  const { TaskQueue } = load(base + 'TaskQueue.ets', {
    '@kit.AbilityKit': { wantAgent: {} }, '@kit.BackgroundTasksKit': { backgroundTaskManager: {} },
    '@kit.ArkData': { preferences: { getPreferences: () => prefs } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } },
    './MediaTask': model, './LiveViewProgress': { LiveViewProgress: class {
      setApp() {}
      start(task, pos) { liveEvents.push(['start', task.id, pos.index, pos.total]); }
      update() {}
      stop(message, successful, hasMore) { liveEvents.push(['stop', successful, hasMore]); }
    } }
  });
  return { queue: new TaskQueue(), saved: () => JSON.parse(raw), releasePrefs, liveEvents };
}
(async () => {
  const { TaskState: S, MediaTask, reconcileMediaTaskSnapshots } = model;
  // ArkUI ForEach keeps children with the same key. The reconciler must update
  // the object already linked by TaskCard instead of replacing it.
  const queueTask = new MediaTask('stable', 'in', 'in', 'convert', 'convert', {}, 1);
  const firstSnapshots = reconcileMediaTaskSnapshots([], [queueTask]);
  const linkedSnapshot = firstSnapshots[0];
  queueTask.state = S.RUNNING;
  queueTask.progress = 47;
  const secondSnapshots = reconcileMediaTaskSnapshots(firstSnapshots, [queueTask]);
  assert.equal(secondSnapshots[0], linkedSnapshot, 'same id must preserve the @ObjectLink target');
  assert.equal(linkedSnapshot.state, S.RUNNING);
  assert.equal(linkedSnapshot.progress, 47);
  const h = harness([], true), q = h.queue;
  let finish, progress, calls = 0;
  q.init(undefined, { execute: (task, cb) => { calls++; progress = cb; return new Promise(resolve => finish = resolve); }, cancel: () => true });
  const params = { additionalSourceUris: ['second'] };
  q.enqueue(['first'], ['first'], 'convert', 'convert', params);
  assert.equal(calls, 0, 'wait for history before scheduling');
  h.releasePrefs(); await tick();
  assert.equal(calls, 1);
  params.additionalSourceUris[0] = 'changed';
  assert.equal(q.list()[0].params.additionalSourceUris[0], 'second');
  progress(300); assert.equal(q.list()[0].progress, 99);
  progress(NaN); assert.equal(q.list()[0].progress, 99);
  q.cancel(q.list()[0].id); assert.equal(q.list()[0].state, S.CANCELING);
  q.retry(q.list()[0].id); assert.equal(q.list()[0].state, S.CANCELING);
  q.clearFinished(); assert.equal(q.list().length, 1);
  finish('/output'); await tick();
  assert.equal(q.list()[0].state, S.CANCELED);
  assert.equal(q.stats().failed, 0); assert.equal(q.stats().canceled, 1);
  q.pause(); q.retry(q.list()[0].id); assert.equal(q.list()[0].state, S.WAITING);
  q.resume(); await tick(); assert.equal(calls, 2);
  finish('/output'); await tick(); assert.equal(q.list()[0].state, S.COMPLETED);

  const batch = harness(); batch.queue.init(undefined, { execute: async () => '/ok' }); await tick(); batch.queue.pause();
  batch.queue.enqueue(Array(75).fill('file'), [], 'convert', 'convert', {});
  assert.equal(batch.saved().length, 75, 'never truncate active tasks');
  assert.equal(new Set(batch.saved().map(t => t.id)).size, 75);

  const old = new MediaTask('old', 'file', 'old', 'convert', 'convert', {}, 1); old.state = S.RUNNING;
  const recovery = harness([old]); recovery.queue.init(undefined, { execute: async () => '/ok' }); await tick();
  assert.equal(recovery.queue.list()[0].state, S.FAILED);
  const failure = harness(); let attempts = 0;
  failure.queue.init(undefined, { execute: () => { if (++attempts === 1) throw new Error('sync failure'); return Promise.resolve('/ok'); } }); await tick();
  failure.queue.enqueue(['a', 'b'], [], 'convert', 'convert', {}); await tick();
  assert.equal(failure.queue.list()[0].state, S.FAILED); assert.equal(failure.queue.list()[1].state, S.COMPLETED);

  // A batch is one live-view session: later items must advance 1/3 -> 2/3 -> 3/3,
  // not shrink back to 1/2 and 1/1 as completed tasks leave the active set.
  const ordinal = harness(); const ordinalResolvers = [];
  ordinal.queue.init(undefined, { execute: () => new Promise(resolve => ordinalResolvers.push(resolve)) });
  await tick();
  ordinal.queue.enqueue(['a', 'b', 'c'], ['a', 'b', 'c'], 'compress_video', '批量智能压缩', {});
  await tick();
  assert.deepEqual(ordinal.liveEvents.filter(e => e[0] === 'start').map(e => e.slice(2)), [[1, 3]]);
  ordinalResolvers[0]('/a'); await tick();
  assert.deepEqual(ordinal.liveEvents.filter(e => e[0] === 'start').map(e => e.slice(2)), [[1, 3], [2, 3]]);
  ordinalResolvers[1]('/b'); await tick();
  assert.deepEqual(ordinal.liveEvents.filter(e => e[0] === 'start').map(e => e.slice(2)),
    [[1, 3], [2, 3], [3, 3]]);
  ordinalResolvers[2]('/c'); await tick();
  assert.equal(ordinal.liveEvents.filter(e => e[0] === 'stop' && e[2] === false).length, 1,
    'only the final batch item ends the live-view session');

  // UX-01: RUNNING 任务不得被直接删除
  const rm = harness(); let rmFinish;
  rm.queue.init(undefined, {
    execute: () => new Promise(resolve => rmFinish = resolve),
    cancel: () => true
  }); await tick();
  rm.queue.enqueue(['x'], ['x'], 'convert', 'convert', {});
  await tick();
  assert.equal(rm.queue.list()[0].state, S.RUNNING);
  assert.equal(rm.queue.removeTask(rm.queue.list()[0].id), 'busy');
  assert.equal(rm.queue.list().length, 1, 'running task must remain');
  rm.queue.cancel(rm.queue.list()[0].id);
  assert.equal(rm.queue.list()[0].state, S.CANCELING);
  assert.equal(rm.queue.removeTask(rm.queue.list()[0].id), 'busy', 'canceling not deletable');
  rmFinish('/out'); await tick();
  assert.equal(rm.queue.list()[0].state, S.CANCELED);
  assert.equal(rm.queue.removeTask(rm.queue.list()[0].id), 'ok');
  assert.equal(rm.queue.list().length, 0);
  assert.equal(rm.queue.removeTask('missing'), 'not_found');
  const waitingDelete = harness();
  waitingDelete.queue.init(undefined, { execute: async () => '/unused' }); await tick();
  waitingDelete.queue.pause();
  waitingDelete.queue.enqueue(['queued'], ['queued'], 'convert', 'convert', {});
  const revisionBeforeDelete = waitingDelete.queue.currentRevision();
  assert.equal(waitingDelete.queue.removeTask(waitingDelete.queue.list()[0].id), 'ok');
  assert.equal(waitingDelete.queue.list().length, 0);
  assert.equal(waitingDelete.queue.currentRevision(), revisionBeforeDelete + 1,
    'waiting delete must publish one atomic collection update');
  console.log('PASS: stable UI snapshots, initialization, isolated parameters, progress, cancellation, retry, pause/resume, 75-task persistence, recovery, synchronous failure, removeTask busy guard');
})().catch(error => { console.error(error); process.exitCode = 1; });
