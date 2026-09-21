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
  vm.runInNewContext(code, { exports, require: name => deps[name], console, Observed: value => value });
  return exports;
}

const model = load('entry/src/main/ets/core/task/MediaTask.ets', {});
const presentation = load('entry/src/main/ets/core/task/TaskQueuePresentation.ets', {
  './MediaTask': model
});
const { MediaTask, TaskState } = model;
const { groupTasksByDay, taskDayRenderKey } = presentation;
const now = new Date(2026, 8, 20, 12, 0, 0).getTime();
const a = new MediaTask('a', 'a', 'a', 'x', 'x', {}, now);
const b = new MediaTask('b', 'b', 'b', 'x', 'x', {}, now + 1);

const one = groupTasksByDay([a], now)[0];
const oneKey = taskDayRenderKey(one);
a.progress = 50;
assert.equal(taskDayRenderKey(groupTasksByDay([a], now)[0]), oneKey,
  'field updates must keep the day subtree and its @ObjectLink alive');
const twoKey = taskDayRenderKey(groupTasksByDay([a, b], now)[0]);
assert.notEqual(twoKey, oneKey, 'adding a task must invalidate the nested day list');
assert.equal(taskDayRenderKey(groupTasksByDay([a], now)[0]), oneKey,
  'deleting a task must invalidate the nested day list');
b.state = TaskState.RUNNING;
assert.equal(groupTasksByDay([a, b], now)[0].tasks[1], b);
console.log('PASS: day grouping invalidates on add/delete but remains stable for progress updates');
