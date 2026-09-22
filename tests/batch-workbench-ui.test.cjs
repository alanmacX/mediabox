const fs = require('node:fs');
const assert = require('node:assert/strict');

const batch = fs.readFileSync('entry/src/main/ets/pages/BatchWorkbench.ets', 'utf8');
const renderer = fs.readFileSync('entry/src/main/ets/core/media/BatchResultPreview.ets', 'utf8');
const single = fs.readFileSync('entry/src/main/ets/pages/ToolConfigPage.ets', 'utf8');

const listPane = batch.slice(batch.indexOf('FileListPane()'), batch.indexOf('ResultPreviewPane()'));
assert.match(listPane, /height\(this\.fileListViewportHeight\(\)\)/,
  'batch queue must size its list to visible rows');
assert.doesNotMatch(listPane, /layoutWeight\(1\)/,
  'batch queue must not stretch its list over the remaining screen');
assert.doesNotMatch(batch, /pageScroller\.scrollEdge/,
  'choosing an operation must not force the whole page back to the top');
assert.match(batch, /@StorageProp\('preferredHand'\).*@Watch\('onPreferredHandChange'\)/,
  'wide batch controls must follow the same preferred-hand source as single-task controls');
assert.match(batch, /if \(this\.controlsOnLeft\)/,
  'wide batch layout must be able to swap controls and file preview panes');
assert.match(batch, /BatchResultPreview\.render/,
  'batch configuration must request a rendered result preview');
assert.match(renderer, /drawing\.Canvas/,
  'stitching preview must composite actual pixels');
assert.match(renderer, /packToData/,
  'compression and conversion preview must pass through the requested encoder');
assert.match(single, /showPreview: true/,
  'single-task adjustments must continue showing their parameter-rendered result preview on wide screens');

console.log('PASS: compact batch queue, stable workflow transition, hand-aware columns and rendered previews');
