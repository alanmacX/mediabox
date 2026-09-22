// Contract test for the official Motion API subscription and foreground wiring.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

const source = fs.readFileSync('entry/src/main/ets/core/capability/MotionHandService.ets', 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const callbacks = new Map();
const removed = [];
const motion = {
  HoldingHandStatus: { NOT_HELD: 0, LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2,
    BOTH_HANDS_HELD: 3, UNKNOWN_STATUS: 16 },
  OperatingHandStatus: { UNKNOWN_STATUS: 0, LEFT_HAND_OPERATED: 1, RIGHT_HAND_OPERATED: 2 },
  on: (type, callback) => callbacks.set(type, callback),
  off: (type, callback) => {
    removed.push([type, callback]);
    callbacks.delete(type);
  },
  getRecentOperatingHandStatus: () => 2
};
const storage = new Map();
const moduleExports = {};
vm.runInNewContext(code, {
  exports: moduleExports,
  require: name => ({
    '@kit.MultimodalAwarenessKit': { motion },
    '@kit.BasicServicesKit': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    '@kit.ArkData': { preferences: {} },
    '@kit.AbilityKit': {}
  })[name],
  canIUse: () => true,
  AppStorage: {
    get: key => storage.get(key),
    setOrCreate: (key, value) => storage.set(key, value)
  }
});

const { MotionHandService, HandPrefs } = moduleExports;
const service = new MotionHandService();
const hands = [];
assert.equal(service.start(hand => { hands.push(hand); HandPrefs.onDetected(hand); }), true);
assert.equal(callbacks.size, 2);
assert.deepEqual(hands, ['right'], 'recent operating status supplies initial value');
callbacks.get('holdingHandChanged')(motion.HoldingHandStatus.LEFT_HAND_HELD);
callbacks.get('operatingHandChanged')(motion.OperatingHandStatus.RIGHT_HAND_OPERATED);
assert.deepEqual(hands, ['right', 'left'], 'a resolved holding hand wins over the operating hand');
assert.equal(HandPrefs.effectiveHand(), 'left');
callbacks.get('holdingHandChanged')(motion.HoldingHandStatus.NOT_HELD);
callbacks.get('operatingHandChanged')(motion.OperatingHandStatus.RIGHT_HAND_OPERATED);
assert.equal(HandPrefs.effectiveHand(), 'right', 'operating status takes over when holding is unknown');
const staleHoldingCallback = callbacks.get('holdingHandChanged');
service.stop();
assert.equal(callbacks.size, 0);
assert.equal(removed.length, 2);
staleHoldingCallback(motion.HoldingHandStatus.LEFT_HAND_HELD);
assert.equal(HandPrefs.effectiveHand(), 'right', 'a queued callback after background must be ignored');
assert.equal(service.start(hand => hands.push(hand)), true, 'foreground re-entry may resubscribe');
service.stop();

const moduleSource = fs.readFileSync('entry/src/main/module.json5', 'utf8');
const abilitySource = fs.readFileSync('entry/src/main/ets/entryability/EntryAbility.ets', 'utf8');
assert.match(moduleSource, /ohos\.permission\.DETECT_GESTURE/);
assert.match(abilitySource, /onForeground\(\)[\s\S]*?motionHand\.start/);
assert.match(abilitySource, /onBackground\(\)[\s\S]*?motionHand\.stop/);
console.log('PASS: motion permission, foreground lifecycle, initial value, source priority and unsubscribe');
