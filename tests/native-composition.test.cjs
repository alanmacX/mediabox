const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const sizes = { a: { width: 400, height: 200 }, b: { width: 200, height: 400 } };
let openCount = 0, closes = 0, released = 0, draws = [], packed;
const pixels = size => ({ size, getImageInfo: async () => ({ size }), release: async () => released++ });
const image = {
  PixelMapFormat: { RGBA_8888: 1 }, AlphaType: { PREMUL: 1 },
  createImageSource: fd => ({ getImageInfo: async () => ({ size: sizes[fd] }),
    createPixelMap: async options => pixels(options.desiredSize), release: async () => released++ }),
  createPixelMap: async (_, options) => pixels(options.size),
  createImagePacker: () => ({ packToFile: async output => packed = output.size, release: async () => released++ })
};
const drawing = { Canvas: class { drawImage(p, x, y) { draws.push([p.size.width, p.size.height, x, y]); }
  drawImageRect(p, rect) { draws.push(rect); } } };
const fileIo = { open: async path => { openCount++; return { fd: path }; }, close: async () => closes++,
  accessSync: () => true, OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8 } };
function load(file) {
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(code, { exports, require: name => ({ '@kit.ImageKit': { image }, '@kit.ArkGraphics2D': { drawing }, '@kit.CoreFileKit': { fileIo } })[name] });
  return exports;
}
(async () => {
  const { ImageComposition } = load('entry/src/main/ets/core/engine/ImageComposition.ets');
  const task = { id: 'test', actionId: 'image_stack_horizontal', sourceUri: 'a', params: { additionalSourceUris: ['b'], targetWidth: 1920 } };
  await ImageComposition.stack({ filesDir: '/tmp' }, task, () => {});
  assert.equal(packed.width, 500); assert.equal(packed.height, 200);
  assert.deepEqual(draws, [[400, 200, 0, 0], [100, 200, 400, 0]]);
  assert.equal(openCount, closes);
  draws = []; task.actionId = 'image_stack_vertical';
  await ImageComposition.stack({ filesDir: '/tmp' }, task, () => {});
  assert.equal(packed.width, 200); assert.equal(packed.height, 500);
  assert.deepEqual(draws, [[200, 100, 0, 0], [200, 400, 0, 100]]);
  const { WatermarkRenderer } = load('entry/src/main/ets/core/engine/WatermarkRenderer.ets');
  draws = [];
  await WatermarkRenderer.draw(pixels({ width: 400, height: 300 }), 'b', { watermarkWidth: 100, watermarkX: 20, watermarkY: 40 }, .5, .5);
  assert.equal(draws[0].left, 10); assert.equal(draws[0].top, 20);
  assert.equal(draws[0].right, 60); assert.equal(draws[0].bottom, 120);
  await assert.rejects(() => WatermarkRenderer.draw(pixels({ width: 20, height: 20 }), 'b', { watermarkX: 40 }), /画面内/);
  assert.equal(openCount, closes);
  console.log('PASS: native horizontal/vertical geometry, watermark preview scaling, bounds and descriptor cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
